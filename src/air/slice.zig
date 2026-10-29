//! Cuts a pack down to the functions of a project and the library functions they can reach, and compacts every
//! table to what those use. `ZV_AIR_STD=1` exports all of std (about 10 MB for a test file); the ownership checker
//! reads the bodies of the container methods and allocator helpers a project calls, which are a small part of it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const schema = @import("schema.zig");

const Range = schema.Range;

/// Modules whose functions are kept only when something kept calls them.
pub const library = [_][]const u8{ "std", "ubsan_rt", "compiler_rt" };

/// Callees that are not followed: panics (noreturn, never read) and the parts of std that talk to the system.
const skipped = [_][]const u8{
    "debug.FullPanic", "debug.panic",  "debug.defaultPanic", "debug.dumpStack", "debug.print", "debug.lockStdErr", "debug.unlockStdErr",
    "debug.SelfInfo",  "debug.Dwarf",  "Io.",                "fmt.",            "os.",          "posix.",           "fs.",
    "Progress.",       "process.",     "testing.",           "Thread.",         "log.",         "lang.",            "builtin.",
    "start.",          "c.",           "crypto.",            "tty.",            "Target.",      "zig.",             "compress.",
};

const Slicer = struct {
    arena: Allocator,
    p: schema.Pack,
    keep: []bool,
    str_used: []bool,
    file_used: []bool,
    type_used: []bool,
    const_used: []bool,
    callee_used: []bool,
    loc_used: []bool,

    fn markStr(s: *Slicer, id: schema.StrId) void {
        s.str_used[@backingInt(id)] = true;
    }

    fn markFile(s: *Slicer, id: schema.FileId) void {
        if (s.file_used[@backingInt(id)]) return;
        s.file_used[@backingInt(id)] = true;
        const rec = s.p.t.files[@backingInt(id)];
        s.markStr(rec.module);
        s.markStr(rec.path);
    }

    fn markLoc(s: *Slicer, id: schema.LocId) void {
        if (id == .none or s.loc_used[@backingInt(id)]) return;
        s.loc_used[@backingInt(id)] = true;
        s.markFile(s.p.t.locs[@backingInt(id)].file);
    }

    fn markCallee(s: *Slicer, id: schema.CalleeId) void {
        if (s.callee_used[@backingInt(id)]) return;
        s.callee_used[@backingInt(id)] = true;
        s.markStr(s.p.t.callees[@backingInt(id)]);
    }

    fn markType(s: *Slicer, id: schema.TypeId) void {
        if (id == .none or s.type_used[@backingInt(id)]) return;
        s.type_used[@backingInt(id)] = true;
        const rec = s.p.t.types[@backingInt(id)];
        s.markStr(rec.name);
        s.markType(rec.child);
        for (s.p.t.fields) |f| if (f.owner == id) {
            s.markStr(f.name);
            s.markType(f.ty);
        };
    }

    fn markConst(s: *Slicer, id: u32) void {
        if (s.const_used[id]) return;
        s.const_used[id] = true;
        const rec = s.p.t.consts[id];
        s.markType(rec.ty);
        switch (rec.kind) {
            .enum_literal, .enum_tag, .@"error", .text => s.markStr(@enumFromInt(rec.a)),
            .func => s.markCallee(@enumFromInt(rec.a)),
            .type => s.markType(@enumFromInt(rec.a)),
            else => {},
        }
    }

    fn markInsts(s: *Slicer, range: Range) void {
        for (s.p.instsOf(range)) |inst| {
            s.markType(inst.ty);
            s.markLoc(inst.loc);
            for (s.p.operandsOf(inst)) |o| if (o.kind == .constant) s.markConst(o.value);
            for (s.p.attrsOf(inst)) |a| switch (a.key.kind()) {
                .str => s.markStr(@enumFromInt(a.value)),
                .callee => s.markCallee(@enumFromInt(a.value)),
                else => {},
            };
            for (s.p.bodiesOf(inst)) |b| {
                for (s.p.t.operands[b.items.off..][0..b.items.len]) |o| if (o.kind == .constant) s.markConst(o.value);
                for (s.p.t.operands[b.ranges.off..][0 .. b.ranges.len * 2]) |o| if (o.kind == .constant) s.markConst(o.value);
                s.markInsts(b.insts);
            }
        }
    }

    /// Adds the functions that the instructions call, by name: every instance of a name is kept.
    fn collectCallees(s: *Slicer, range: Range, by_name: *const std.StringHashMapUnmanaged(std.ArrayList(u32)), queue: *std.ArrayList(u32)) Allocator.Error!void {
        for (s.p.instsOf(range)) |inst| {
            for (s.p.attrsOf(inst)) |a| if (a.key == .callee) try s.enqueue(s.p.calleeName(@enumFromInt(a.value)), by_name, queue);
            for (s.p.operandsOf(inst)) |o| if (o.kind == .constant) {
                const c = s.p.t.consts[o.value];
                if (c.kind == .func) try s.enqueue(s.p.calleeName(@enumFromInt(c.a)), by_name, queue);
            };
            for (s.p.bodiesOf(inst)) |b| try s.collectCallees(b.insts, by_name, queue);
        }
    }

    fn enqueue(s: *Slicer, name: []const u8, by_name: *const std.StringHashMapUnmanaged(std.ArrayList(u32)), queue: *std.ArrayList(u32)) Allocator.Error!void {
        for (skipped) |prefix| if (std.mem.startsWith(u8, name, prefix)) return;
        const list = by_name.get(name) orelse return;
        for (list.items) |idx| if (!s.keep[idx]) {
            s.keep[idx] = true;
            try queue.append(s.arena, idx);
        };
    }
};

/// The exporter's own root and the test runner: not part of any project.
fn isHarness(p: schema.Pack, f: schema.Func) bool {
    const file = p.t.files[@backingInt(f.file)];
    const path = p.str(file.path);
    return std.mem.eql(u8, p.str(file.module), "root") and (std.mem.startsWith(u8, path, "air_") or std.mem.indexOf(u8, path, "test_runner") != null);
}

fn isLibrary(p: schema.Pack, f: schema.Func) bool {
    const module = p.str(p.t.files[@backingInt(f.file)].module);
    for (library) |name| if (std.mem.eql(u8, module, name)) return true;
    return false;
}

fn remap(comptime T: type, used: []const bool, arena: Allocator) Allocator.Error![]T {
    const out = try arena.alloc(T, used.len);
    var next: u32 = 0;
    for (used, out) |u, *slot| {
        slot.* = @enumFromInt(next);
        if (u) next += 1;
    }
    return out;
}

/// The pack with only the functions of the project and what they reach in the library.
pub fn slice(gpa: Allocator, p: schema.Pack) Allocator.Error![]align(8) u8 {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const t = p.t;

    var s: Slicer = .{
        .arena = arena,
        .p = p,
        .keep = try arena.alloc(bool, t.funcs.len),
        .str_used = try arena.alloc(bool, t.str_index.len),
        .file_used = try arena.alloc(bool, t.files.len),
        .type_used = try arena.alloc(bool, t.types.len),
        .const_used = try arena.alloc(bool, t.consts.len),
        .callee_used = try arena.alloc(bool, t.callees.len),
        .loc_used = try arena.alloc(bool, t.locs.len),
    };
    inline for (.{ "keep", "str_used", "file_used", "type_used", "const_used", "callee_used", "loc_used" }) |name| @memset(@field(s, name), false);

    var by_name: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    for (t.funcs, 0..) |f, i| {
        const gop = try by_name.getOrPut(arena, p.str(f.fqn));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, @intCast(i));
    }
    var queue: std.ArrayList(u32) = .empty;
    for (t.funcs, 0..) |f, i| if (!isLibrary(p, f) and !isHarness(p, f)) {
        s.keep[i] = true;
        try queue.append(arena, @intCast(i));
    };
    while (queue.pop()) |i| try s.collectCallees(t.funcs[i].insts, &by_name, &queue);

    s.markStr(p.meta.zig_version);
    s.markStr(p.meta.target);
    s.markStr(p.meta.root);
    for (t.funcs, 0..) |f, i| if (s.keep[i]) {
        s.markStr(f.fqn);
        s.markFile(f.file);
        s.markType(f.ret);
        for (p.paramsOf(f)) |q| s.markType(q.ty);
        for (p.calleeRefsOf(f)) |ref| s.markCallee(@enumFromInt(ref.callee));
        s.markInsts(f.insts);
    };

    const str_map = try remap(schema.StrId, s.str_used, arena);
    const file_map = try remap(schema.FileId, s.file_used, arena);
    const type_map = try remap(schema.TypeId, s.type_used, arena);
    const callee_map = try remap(schema.CalleeId, s.callee_used, arena);
    const loc_map = try remap(schema.LocId, s.loc_used, arena);
    const const_map = try remap(schema.ConstId, s.const_used, arena);

    var out: schema.Tables = .{};
    var blob: std.ArrayList(u8) = .empty;
    var str_index: std.ArrayList(schema.StrEntry) = .empty;
    for (s.str_used, 0..) |u, i| if (u) {
        const text = p.str(@enumFromInt(i));
        try str_index.append(arena, .{ .off = @intCast(blob.items.len), .len = @intCast(text.len) });
        try blob.appendSlice(arena, text);
    };
    out.strings = blob.items;
    out.str_index = str_index.items;
    out.files = try collect(schema.FileRec, arena, s.file_used, t.files, struct {
        str: []const schema.StrId,
        fn f(c: @This(), rec: schema.FileRec) schema.FileRec {
            return .{ .module = c.str[@backingInt(rec.module)], .path = c.str[@backingInt(rec.path)] };
        }
    }{ .str = str_map });
    out.types = try collect(schema.TypeRec, arena, s.type_used, t.types, struct {
        str: []const schema.StrId,
        ty: []const schema.TypeId,
        fn f(c: @This(), rec: schema.TypeRec) schema.TypeRec {
            var copy = rec;
            copy.name = c.str[@backingInt(rec.name)];
            if (rec.child != .none) copy.child = c.ty[@backingInt(rec.child)];
            return copy;
        }
    }{ .str = str_map, .ty = type_map });
    out.consts = try collect(schema.ConstRec, arena, s.const_used, t.consts, struct {
        str: []const schema.StrId,
        ty: []const schema.TypeId,
        callee: []const schema.CalleeId,
        fn f(c: @This(), rec: schema.ConstRec) schema.ConstRec {
            var copy = rec;
            if (rec.ty != .none) copy.ty = c.ty[@backingInt(rec.ty)];
            copy.a = switch (rec.kind) {
                .enum_literal, .enum_tag, .@"error", .text => @backingInt(c.str[@intCast(rec.a)]),
                .func => @backingInt(c.callee[@intCast(rec.a)]),
                .type => @backingInt(c.ty[@intCast(rec.a)]),
                else => rec.a,
            };
            return copy;
        }
    }{ .str = str_map, .ty = type_map, .callee = callee_map });
    out.callees = try collect(schema.StrId, arena, s.callee_used, t.callees, struct {
        str: []const schema.StrId,
        fn f(c: @This(), rec: schema.StrId) schema.StrId {
            return c.str[@backingInt(rec)];
        }
    }{ .str = str_map });
    out.locs = try collect(schema.LocRec, arena, s.loc_used, t.locs, struct {
        file: []const schema.FileId,
        fn f(c: @This(), rec: schema.LocRec) schema.LocRec {
            return .{ .file = c.file[@backingInt(rec.file)], .line = rec.line, .col = rec.col };
        }
    }{ .file = file_map });
    var fields: std.ArrayList(schema.FieldRec) = .empty;
    for (t.fields) |f| if (s.type_used[@backingInt(f.owner)]) try fields.append(arena, .{
        .owner = type_map[@backingInt(f.owner)],
        .index = f.index,
        .name = str_map[@backingInt(f.name)],
        .ty = if (f.ty == .none) .none else type_map[@backingInt(f.ty)],
    });
    out.fields = fields.items;

    var c: Copier = .{ .arena = arena, .p = p, .str = str_map, .ty = type_map, .callee = callee_map, .loc = loc_map, .const_ = const_map };
    var funcs: std.ArrayList(schema.Func) = .empty;
    for (t.funcs, 0..) |f, i| if (s.keep[i]) {
        var copy = f;
        copy.fqn = str_map[@backingInt(f.fqn)];
        copy.file = file_map[@backingInt(f.file)];
        copy.ret = type_map[@backingInt(f.ret)];
        copy.params = .{ .off = @intCast(c.params.items.len), .len = f.params.len };
        for (p.paramsOf(f)) |q| try c.params.append(arena, .{ .ty = type_map[@backingInt(q.ty)], .zir_index = q.zir_index });
        copy.callees = .{ .off = @intCast(c.callee_refs.items.len), .len = f.callees.len };
        for (p.calleeRefsOf(f)) |ref| try c.callee_refs.append(arena, .{ .inlined = ref.inlined, .callee = @intCast(@backingInt(callee_map[ref.callee])) });
        copy.insts = try c.insts(f.insts);
        try funcs.append(arena, copy);
    };
    out.funcs = funcs.items;
    out.params = c.params.items;
    out.callee_refs = c.callee_refs.items;
    out.insts = c.all_insts.items;
    out.operands = c.operands.items;
    out.attrs = c.attrs.items;
    out.bodies = c.bodies.items;

    const meta: schema.Meta = .{
        .zig_version = str_map[@backingInt(p.meta.zig_version)],
        .target = str_map[@backingInt(p.meta.target)],
        .root = str_map[@backingInt(p.meta.root)],
        .optimize = p.meta.optimize,
    };
    return schema.serialize(gpa, .{ .meta = meta, .t = out });
}

fn collect(comptime T: type, arena: Allocator, used: []const bool, old: []const T, ctx: anytype) Allocator.Error![]const T {
    var out: std.ArrayList(T) = .empty;
    for (used, old) |u, rec| if (u) try out.append(arena, ctx.f(rec));
    return out.items;
}

const Copier = struct {
    arena: Allocator,
    p: schema.Pack,
    str: []const schema.StrId,
    ty: []const schema.TypeId,
    callee: []const schema.CalleeId,
    loc: []const schema.LocId,
    const_: []const schema.ConstId,
    params: std.ArrayList(schema.Param) = .empty,
    callee_refs: std.ArrayList(schema.CalleeRef) = .empty,
    all_insts: std.ArrayList(schema.Inst) = .empty,
    operands: std.ArrayList(schema.Operand) = .empty,
    attrs: std.ArrayList(schema.Attr) = .empty,
    bodies: std.ArrayList(schema.Body) = .empty,

    fn copyOperands(c: *Copier, list: []const schema.Operand) Allocator.Error!u32 {
        const at: u32 = @intCast(c.operands.items.len);
        for (list) |o| try c.operands.append(c.arena, switch (o.kind) {
            .constant => .constant(c.const_[o.value]),
            else => o,
        });
        return at;
    }

    /// One level of instructions, contiguous, then the bodies of each of them.
    fn insts(c: *Copier, range: Range) Allocator.Error!Range {
        const src = c.p.instsOf(range);
        const start: u32 = @intCast(c.all_insts.items.len);
        for (src) |inst| {
            var copy = inst;
            if (inst.ty != .none) copy.ty = c.ty[@backingInt(inst.ty)];
            if (inst.loc != .none) copy.loc = c.loc[@backingInt(inst.loc)];
            copy.ops = try c.copyOperands(c.p.operandsOf(inst));
            copy.attrs = @intCast(c.attrs.items.len);
            for (c.p.attrsOf(inst)) |a| {
                var attr = a;
                attr.value = switch (a.key.kind()) {
                    .str => @backingInt(c.str[a.value]),
                    .callee => @backingInt(c.callee[a.value]),
                    else => a.value,
                };
                try c.attrs.append(c.arena, attr);
            }
            try c.all_insts.append(c.arena, copy);
        }
        for (src, 0..) |inst, i| {
            const bodies = c.p.bodiesOf(inst);
            const first: u32 = @intCast(c.bodies.items.len);
            c.all_insts.items[start + i].bodies = first;
            try c.bodies.appendNTimes(c.arena, undefined, bodies.len);
            for (bodies, 0..) |b, j| {
                const items = try c.copyOperands(c.p.t.operands[b.items.off..][0..b.items.len]);
                const ranges = try c.copyOperands(c.p.t.operands[b.ranges.off..][0 .. b.ranges.len * 2]);
                const inner = try c.insts(b.insts);
                c.bodies.items[first + j] = .{ .label = b.label, .items = .{ .off = items, .len = b.items.len }, .ranges = .{ .off = ranges, .len = b.ranges.len }, .insts = inner };
            }
        }
        return .{ .off = start, .len = range.len };
    }
};
