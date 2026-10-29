//! Raw AIR dump (reflect.zig) -> schema v1 (docs/phase1.md).
//! usage: norm RULES.zon RAW_DIR OUT_DIR
//! All version-specific knowledge is in RULES.zon, which is read at run time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Json = std.json.Value;
const Stringify = std.json.Stringify;

const Rule = struct {
    /// A tag name, or "<data field>" or "<data field>/<payload type>" for every tag with that shape.
    key: []const u8,
    ops: []const []const u8 = &.{},
    attrs: []const AttrRule = &.{},
    bodies: []const BodyRule = &.{},
    special: enum { none, dbg_stmt, inline_block, switch_br } = .none,
    /// Raw fields that are known and deliberately unused; --strict rejects any other unconsumed field.
    ignore: []const []const u8 = &.{},
};

const AttrRule = struct {
    key: []const u8,
    kind: enum { int, str, flag, inst, call_target, inline_target },
    path: []const u8 = "",
    /// Only for tags starting with this prefix; the value is the rest of the tag name.
    from_tag: []const u8 = "",
};

const BodyRule = struct {
    /// "$tag" labels the body with the instruction's tag.
    label: []const u8,
    path: []const u8,
};

const Rules = struct {
    /// Where an `arg` instruction keeps its type (0.16 stores a Ref to a type constant).
    param_ty_path: []const u8 = "data.ty",
    unsupported: []const []const u8,
    rules: []const Rule,
};

const Operand = union(enum) {
    none,
    inst: i64,
    constant: struct { ty: u32, val: []const u8 },
};

const AttrOut = struct {
    key: []const u8,
    value: union(enum) { int: i64, str: []const u8, flag: bool, inst: i64 },
};

const Loc = struct { file: u32, line: i64, col: i64 };

const Body = struct {
    label: []const u8,
    items: []const Operand = &.{},
    ranges: []const [2]Operand = &.{},
    insts: []const Inst,
};

const Inst = struct {
    id: i64,
    tag: []const u8,
    supported: bool = true,
    ty: ?u32 = null,
    operands: []const Operand = &.{},
    attrs: []const AttrOut = &.{},
    loc: ?Loc = null,
    bodies: []const Body = &.{},
};

const Error = error{ OutOfMemory, BadRaw, NoRule };

fn fail(comptime fmt: []const u8, args: anytype) error{ BadRaw, NoRule } {
    std.debug.print("norm: " ++ fmt ++ "\n", args);
    return error.BadRaw;
}

fn get(v: Json, path: []const u8) ?Json {
    var cur = v;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |part| {
        if (cur != .object) return null;
        cur = cur.object.get(part) orelse return null;
    }
    return cur;
}

fn need(v: Json, path: []const u8) Error!Json {
    return get(v, path) orelse fail("missing {s}", .{path});
}

fn int(v: Json) Error!i64 {
    return if (v == .integer) v.integer else fail("expected integer", .{});
}

fn str(v: Json) Error![]const u8 {
    return if (v == .string) v.string else fail("expected string", .{});
}

const Ctx = struct {
    arena: Allocator,
    rules: *const Lookup,
    strict: bool = false,
    types: std.ArrayList(struct { name: []const u8, kind: []const u8 }) = .empty,
    type_ids: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    files: std.ArrayList(struct { module: []const u8, path: []const u8 }) = .empty,
    callees: std.ArrayList(struct { fqn: []const u8, inlined: bool }) = .empty,
    unsupported: u32 = 0,
    file: u32 = 0,
    base_line: i64 = 0,
    loc: ?Loc = null,

    fn typeId(c: *Ctx, t: Json) Error!u32 {
        const gop = try c.type_ids.getOrPut(c.arena, try int(try need(t, "i")));
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(c.types.items.len);
            try c.types.append(c.arena, .{ .name = try str(try need(t, "name")), .kind = try str(try need(t, "kind")) });
        }
        return gop.value_ptr.*;
    }

    fn fileId(c: *Ctx, module: []const u8, path: []const u8) Error!u32 {
        for (c.files.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.module, module) and std.mem.eql(u8, f.path, path)) return @intCast(i);
        }
        try c.files.append(c.arena, .{ .module = module, .path = path });
        return @intCast(c.files.items.len - 1);
    }

    fn operand(c: *Ctx, v: Json) Error!Operand {
        if (v == .null) return .none;
        if (get(v, "inst")) |i| return .{ .inst = try int(i) };
        return .{ .constant = .{ .ty = try c.typeId(try need(v, "ty")), .val = try str(try need(v, "val")) } };
    }

    fn operands(c: *Ctx, out: *std.ArrayList(Operand), v: Json) Error!void {
        if (v == .array) {
            for (v.array.items) |item| try out.append(c.arena, try c.operand(item));
        } else try out.append(c.arena, try c.operand(v));
    }

    fn body(c: *Ctx, v: Json) Error![]const Inst {
        if (v != .array) return fail("body is not an array", .{});
        const out = try c.arena.alloc(Inst, v.array.items.len);
        for (v.array.items, out) |item, *slot| slot.* = try c.inst(item);
        return out;
    }

    fn inst(c: *Ctx, j: Json) Error!Inst {
        const tag = try str(try need(j, "tag"));
        const id = try int(try need(j, "id"));
        const loc = c.loc;
        if (c.rules.isUnsupported(tag)) {
            c.unsupported += 1;
            return .{ .id = id, .tag = tag, .supported = false };
        }
        const rule = try c.rules.find(j, tag);
        if (c.strict) try strictCheck(rule.*, j, tag);
        var ops: std.ArrayList(Operand) = .empty;
        var attrs: std.ArrayList(AttrOut) = .empty;
        var bodies: std.ArrayList(Body) = .empty;

        switch (rule.special) {
            .dbg_stmt => {
                const d = try need(j, "data");
                const line = c.base_line + try int(try need(d, "line")) + 1;
                const col = try int(try need(d, "column")) + 1;
                c.loc = .{ .file = c.file, .line = line, .col = col };
                try attrs.append(c.arena, .{ .key = "line", .value = .{ .int = line } });
                try attrs.append(c.arena, .{ .key = "col", .value = .{ .int = col } });
            },
            else => {
                for (rule.ops) |path| try c.operands(&ops, try need(j, path));
                if (rule.special == .switch_br) try c.cases(j, &bodies);
                for (rule.attrs) |a| try c.attr(&attrs, j, tag, a);
                if (rule.special == .inline_block) {
                    const callee = try need(j, "payload.value.func.fn");
                    const saved = .{ c.base_line, c.file, c.loc };
                    c.base_line = try int(try need(callee, "line0"));
                    c.file = try c.fileId(try str(try need(callee, "module")), try str(try need(callee, "path")));
                    for (rule.bodies) |b| try bodies.append(c.arena, .{ .label = label(b, tag), .insts = try c.body(try need(j, b.path)) });
                    c.base_line, c.file, c.loc = saved;
                } else for (rule.bodies) |b| {
                    try bodies.append(c.arena, .{ .label = label(b, tag), .insts = try c.body(try need(j, b.path)) });
                }
                if (rule.special == .switch_br) try bodies.append(c.arena, .{ .label = "else", .insts = try c.body(try need(j, "payload.value.else_body")) });
            },
        }

        return .{
            .id = id,
            .tag = tag,
            .ty = try c.typeId(try need(j, "ty")),
            .operands = ops.items,
            .attrs = attrs.items,
            .loc = if (rule.special == .dbg_stmt) c.loc else loc,
            .bodies = bodies.items,
        };
    }

    fn accounted(rule: Rule, full: []const u8) bool {
        for (rule.ignore) |p| if (covers(p, full)) return true;
        for (rule.ops) |p| if (covers(p, full)) return true;
        for (rule.attrs) |a| if (covers(a.path, full)) return true;
        for (rule.bodies) |b| if (covers(b.path, full)) return true;
        return false;
    }

    fn covers(path: []const u8, full: []const u8) bool {
        if (path.len == 0) return false;
        if (std.mem.eql(u8, path, full)) return true;
        if (std.mem.startsWith(u8, full, path) and full[path.len] == '.') return true;
        return std.mem.startsWith(u8, path, full) and path[full.len] == '.';
    }

    fn strictCheck(rule: Rule, j: Json, tag: []const u8) Error!void {
        if (rule.special == .dbg_stmt) return;
        inline for (.{ "data", "payload.value" }) |prefix| {
            if (get(j, prefix)) |obj| if (obj == .object) {
                var it = obj.object.iterator();
                while (it.next()) |kv| {
                    var buf: [128]u8 = undefined;
                    const full = std.fmt.bufPrint(&buf, prefix ++ ".{s}", .{kv.key_ptr.*}) catch return error.BadRaw;
                    if (!accounted(rule, full) and !(rule.special == .switch_br and std.mem.startsWith(u8, full, "payload.value."))) {
                        return fail("{s}: raw field {s} is not covered by rule {s}", .{ tag, full, rule.key });
                    }
                }
            };
        }
    }

    fn label(b: BodyRule, tag: []const u8) []const u8 {
        return if (std.mem.eql(u8, b.label, "$tag")) tag else b.label;
    }

    fn cases(c: *Ctx, j: Json, bodies: *std.ArrayList(Body)) Error!void {
        for ((try need(j, "payload.value.cases")).array.items) |case| {
            const ranges = try c.arena.alloc([2]Operand, (try need(case, "ranges")).array.items.len);
            for ((try need(case, "ranges")).array.items, ranges) |r, *out| {
                out.* = .{ try c.operand(r.array.items[0]), try c.operand(r.array.items[1]) };
            }
            var items: std.ArrayList(Operand) = .empty;
            try c.operands(&items, try need(case, "items"));
            try bodies.append(c.arena, .{
                .label = "case",
                .items = items.items,
                .ranges = ranges,
                .insts = try c.body(try need(case, "body")),
            });
        }
    }

    fn attr(c: *Ctx, out: *std.ArrayList(AttrOut), j: Json, tag: []const u8, a: AttrRule) Error!void {
        if (a.from_tag.len != 0) {
            if (!std.mem.startsWith(u8, tag, a.from_tag)) return;
            return out.append(c.arena, .{ .key = a.key, .value = .{ .str = tag[a.from_tag.len..] } });
        }
        const v = try need(j, a.path);
        switch (a.kind) {
            .int => try out.append(c.arena, .{ .key = a.key, .value = .{ .int = try int(v) } }),
            .str => try out.append(c.arena, .{ .key = a.key, .value = .{ .str = try str(v) } }),
            .flag => try out.append(c.arena, .{ .key = a.key, .value = .{ .flag = v == .bool and v.bool } }),
            .inst => try out.append(c.arena, .{ .key = a.key, .value = .{ .inst = try int(try need(v, "inst")) } }),
            .inline_target => {
                try out.append(c.arena, .{ .key = a.key, .value = .{ .str = try str(v) } });
                try c.callees.append(c.arena, .{ .fqn = try str(v), .inlined = true });
            },
            .call_target => {
                const name = if (get(v, "fn.fqn")) |f| try str(f) else if (get(v, "extern")) |e| try str(e) else return;
                try out.append(c.arena, .{ .key = a.key, .value = .{ .str = name } });
                try c.callees.append(c.arena, .{ .fqn = name, .inlined = false });
            },
        }
    }
};

/// Rule lookup by tag name or shape key.
const Lookup = struct {
    rules: Rules,
    map: std.StringHashMapUnmanaged(*const Rule) = .empty,
    unsupported: std.StringHashMapUnmanaged(void) = .empty,

    fn init(arena: Allocator, rules: Rules) Allocator.Error!Lookup {
        var l: Lookup = .{ .rules = rules };
        for (rules.rules) |*r| try l.map.put(arena, r.key, r);
        for (rules.unsupported) |u| try l.unsupported.put(arena, u, {});
        return l;
    }

    fn isUnsupported(l: *const Lookup, tag: []const u8) bool {
        return l.unsupported.contains(tag);
    }

    fn find(l: *const Lookup, j: Json, tag: []const u8) Error!*const Rule {
        if (l.map.get(tag)) |r| return r;
        const shape = switch (j.object.get("shape") orelse return fail("{s}: no shape", .{tag})) {
            .string => |s| s,
            else => return fail("{s}: the dump has no shape for this tag and the rules have no entry for it", .{tag}),
        };
        var buf: [128]u8 = undefined;
        const key = if (get(j, "payload.type")) |t|
            std.fmt.bufPrint(&buf, "{s}/{s}", .{ shape, try str(t) }) catch return error.BadRaw
        else if (j.object.get("payload_str") != null)
            std.fmt.bufPrint(&buf, "{s}/str", .{shape}) catch return error.BadRaw
        else if (j.object.get("payload")) |p| (if (p == .array)
            std.fmt.bufPrint(&buf, "{s}/elements", .{shape}) catch return error.BadRaw
        else
            shape)
        else
            shape;
        return l.map.get(key) orelse fail("{s}: no rule for shape {s}", .{ tag, key });
    }
};

fn fileName(arena: Allocator, fqn: []const u8, content: []const u8) Allocator.Error![]const u8 {
    const stem = try arena.dupe(u8, fqn[0..@min(fqn.len, 80)]);
    for (stem) |*byte| switch (byte.*) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '-' => {},
        else => byte.* = '_',
    };
    return std.fmt.allocPrint(arena, "{s}.{x:0>16}.json", .{ stem, std.hash.Wyhash.hash(0, content) });
}

fn field(s: *Stringify, name: []const u8, value: anytype) Stringify.Error!void {
    try s.objectField(name);
    try s.write(value);
}

fn writeOperands(s: *Stringify, operands: []const Operand) Stringify.Error!void {
    try s.beginArray();
    for (operands) |operand| switch (operand) {
        .none => try s.write(null),
        .inst => |id| try s.write(.{ .inst = id }),
        .constant => |k| try s.write(.{ .ty = k.ty, .val = k.val }),
    };
    try s.endArray();
}

fn writeInsts(s: *Stringify, insts: []const Inst) Stringify.Error!void {
    try s.beginArray();
    for (insts) |inst| try writeInst(s, inst);
    try s.endArray();
}

fn writeInst(s: *Stringify, inst: Inst) Stringify.Error!void {
    try s.beginObject();
    try field(s, "id", inst.id);
    try field(s, "tag", inst.tag);
    if (!inst.supported) {
        try field(s, "unsupported", true);
        return s.endObject();
    }
    try field(s, "ty", inst.ty);
    if (inst.operands.len != 0) {
        try s.objectField("operands");
        try writeOperands(s, inst.operands);
    }
    if (inst.attrs.len != 0) {
        try s.objectField("attrs");
        try s.beginObject();
        for (inst.attrs) |attr| switch (attr.value) {
            inline .int, .str, .flag => |v| try field(s, attr.key, v),
            .inst => |id| try field(s, attr.key, id),
        };
        try s.endObject();
    }
    if (inst.loc) |loc| try field(s, "loc", .{ loc.file, loc.line, loc.col });
    if (inst.bodies.len != 0) {
        try s.objectField("bodies");
        try s.beginArray();
        for (inst.bodies) |body| {
            try s.beginObject();
            try field(s, "label", body.label);
            if (body.items.len != 0) {
                try s.objectField("items");
                try writeOperands(s, body.items);
            }
            if (body.ranges.len != 0) {
                try s.objectField("ranges");
                try s.beginArray();
                for (body.ranges) |range| try writeOperands(s, &range);
                try s.endArray();
            }
            try s.objectField("insts");
            try writeInsts(s, body.insts);
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
}

fn convert(arena: Allocator, lookup: *const Lookup, strict: bool, raw: Json, w: *std.Io.Writer) !struct { fqn: []const u8 } {
    var c: Ctx = .{ .arena = arena, .rules = lookup, .strict = strict };
    const f = try need(raw, "fn");
    const fqn = try str(try need(f, "fqn"));
    c.file = try c.fileId(try str(try need(f, "module")), try str(try need(f, "path")));
    c.base_line = try int(try need(f, "line0"));

    const top = (try need(raw, "main")).array.items;
    const Param = struct { ty: u32, zir_index: i64 };
    var params: std.ArrayList(Param) = .empty;
    for (top) |inst| {
        if (!std.mem.eql(u8, try str(try need(inst, "tag")), "arg")) break;
        const d = try need(inst, "data");
        try params.append(arena, .{ .ty = try c.typeId(try need(inst, lookup.rules.param_ty_path)), .zir_index = try int(try need(d, "zir_param_index")) });
    }
    const ret = try c.typeId(try need(raw, "ret"));
    const insts = try c.body(try need(raw, "main"));

    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "schema", 1);
    try field(&s, "zig_version", try str(try need(raw, "zig_version")));
    try field(&s, "fqn", fqn);
    try field(&s, "file", 0);
    try field(&s, "line", try int(try need(f, "line0")) + 1);
    try field(&s, "generic_instance", (try need(raw, "generic_instance")).bool);
    try field(&s, "params", params.items);
    try field(&s, "ret", ret);
    try field(&s, "unsupported", c.unsupported);
    try field(&s, "files", c.files.items);
    try field(&s, "types", c.types.items);
    try field(&s, "callees", c.callees.items);
    try s.objectField("insts");
    try writeInsts(&s, insts);
    try s.endObject();
    return .{ .fqn = fqn };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const strict = args.len == 5 and std.mem.eql(u8, args[4], "--strict");
    if (args.len != 4 and !strict) {
        std.debug.print("usage: norm RULES.zon RAW_DIR OUT_DIR [--strict]\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();

    var rule_arena: std.heap.ArenaAllocator = .init(gpa);
    defer rule_arena.deinit();
    const source = try cwd.readFileAllocOptions(io, args[1], rule_arena.allocator(), .limited(1 << 20), .of(u8), 0);
    var diag: std.zon.parse.Diagnostics = undefined;
    const rules = std.zon.parse.fromSlice(Rules, .{
        .gpa = gpa,
        .arena = rule_arena.allocator(),
        .source = source,
        .diagnostics = &diag,
    }) catch |err| {
        diag.log(args[1]);
        std.debug.print("{t}\n", .{err});
        std.process.exit(1);
    };
    const lookup = try Lookup.init(rule_arena.allocator(), rules);

    var in_dir = try cwd.openDir(io, args[2], .{ .iterate = true });
    defer in_dir.close(io);
    try cwd.createDirPath(io, args[3]);
    var out_dir = try cwd.openDir(io, args[3], .{});
    defer out_dir.close(io);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var count: usize = 0;
    var failed: usize = 0;
    var it = in_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const bytes = try in_dir.readFileAlloc(io, entry.name, arena, .limited(1 << 30));
        const raw = try std.json.parseFromSliceLeaky(Json, arena, bytes, .{});
        var aw: std.Io.Writer.Allocating = .init(arena);
        const result = convert(arena, &lookup, strict, raw, &aw.writer) catch |err| {
            std.debug.print("{s}: {t}\n", .{ entry.name, err });
            failed += 1;
            continue;
        };
        try out_dir.writeFile(io, .{ .sub_path = try fileName(arena, result.fqn, aw.written()), .data = aw.written() });
        count += 1;
    }
    std.debug.print("norm: {d} functions, {d} failed\n", .{ count, failed });
    if (failed != 0) std.process.exit(1);
}
