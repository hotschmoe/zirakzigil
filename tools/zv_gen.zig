//! Generates compiler/src/zv_air/shapes.zig from the compiler's own sources.
//! usage: zv_gen ZIG_TREE VERSION OUT.zig [--check]
//!
//! Liveness.zig's `analyzeInst` is exhaustive and compiler-enforced, so it supplies each tag's operands.
//! `Air.typeOfIndex` and the `addXxx` / `.tag = .x, .data = .{ ... }` sites in Sema.zig are only used to
//! cross-check the data union field. Prongs the generator cannot translate become `Manual` kinds.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

/// Operand order that schema v1 fixed and Liveness (the compiler's own order) does not share.
const v1_order = [_]struct { tag: []const u8, perm: []const usize }{
    .{ .tag = "mul_add", .perm = &.{ 2, 0, 1 } },
};

/// Disagreements between sources that were reviewed and are harmless.
const known_conflicts = [_][]const u8{};

const reject = [_][]const u8{ "a", "inst", "ip", "pass", "zcu", "inst_datas", "inst_tags" };

const Source = struct {
    rel: []const u8,
    text: [:0]const u8,
    tree: Ast,

    fn load(arena: Allocator, io: std.Io, root: []const u8, rel: []const u8) !Source {
        const path = try std.fs.path.join(arena, &.{ root, "src", rel });
        const text = try std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(16 << 20), .of(u8), 0);
        const tree = try Ast.parse(arena, text, if (@hasDecl(Ast, "ParseOptions")) .{} else .zig);
        if (tree.errors.len != 0) return error.ParseFailed;
        return .{ .rel = rel, .text = text, .tree = tree };
    }

    fn count(s: Source) usize {
        return s.tree.nodes.len;
    }

    fn at(s: Source, i: usize) Node.Index {
        _ = s;
        return std.enums.fromInt(Node.Index, i).?;
    }

    fn src(s: Source, n: Node.Index) []const u8 {
        return s.tree.getNodeSource(n);
    }

    fn line(s: Source, token: Ast.TokenIndex) usize {
        const start = s.tree.tokenStart(token);
        return 1 + std.mem.count(u8, s.text[0..start], "\n");
    }

    fn inside(s: Source, n: Node.Index, outer: Node.Index) bool {
        return s.tree.firstToken(n) >= s.tree.firstToken(outer) and s.tree.lastToken(n) <= s.tree.lastToken(outer);
    }

    fn fnDecl(s: Source, name: []const u8) !Node.Index {
        for (0..s.count()) |i| {
            const n = s.at(i);
            if (s.tree.nodeTag(n) != .fn_decl) continue;
            if (std.mem.eql(u8, s.fnName(n) orelse continue, name)) return n;
        }
        return error.FunctionNotFound;
    }

    fn fnName(s: Source, decl: Node.Index) ?[]const u8 {
        var buf: [1]Node.Index = undefined;
        const proto = s.tree.fullFnProto(&buf, s.tree.nodeData(decl).node_and_node[0]) orelse return null;
        return s.tree.tokenSlice(proto.name_token orelse return null);
    }

    fn fnBody(s: Source, decl: Node.Index) Node.Index {
        return s.tree.nodeData(decl).node_and_node[1];
    }

    fn switchIn(s: Source, outer: Node.Index, condition: []const u8) !Ast.full.Switch {
        for (0..s.count()) |i| {
            const n = s.at(i);
            const sw = s.tree.fullSwitch(n) orelse continue;
            if (!s.inside(n, outer)) continue;
            if (std.mem.indexOf(u8, s.src(sw.ast.condition), condition) != null) return sw;
        }
        return error.SwitchNotFound;
    }

    fn enumLiteral(s: Source, n: Node.Index) ?[]const u8 {
        if (s.tree.nodeTag(n) != .enum_literal) return null;
        return s.tree.tokenSlice(s.tree.nodeMainToken(n));
    }

    fn caseTags(s: Source, arena: Allocator, case: Ast.full.SwitchCase) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (case.ast.values) |v| try out.append(arena, s.enumLiteral(v) orelse return error.UnexpectedCaseValue);
        return out.items;
    }
};

const Decl = struct { name: []const u8, text: []const u8 };

const Simple = struct {
    decls: []const Decl,
    ops: []const []const u8,
    field: ?[]const u8,
};

const Shape = union(enum) {
    simple: Simple,
    manual,
};

const Prong = struct { tags: []const []const u8, shape: Shape };

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn squash(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) {
            space = out.items.len != 0;
            continue;
        }
        if (space) try out.append(arena, ' ');
        space = false;
        try out.append(arena, c);
    }
    return out.items;
}

/// Maps Liveness's locals onto the adapter's (`data`, `air`). Null when the text depends on anything else.
fn rewrite(arena: Allocator, text: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const rest = text[i..];
        const boundary = i == 0 or !isIdent(text[i - 1]);
        if (boundary and std.mem.startsWith(u8, rest, "inst_datas[")) {
            var depth: usize = 0;
            var j = i + "inst_datas".len;
            while (j < text.len) : (j += 1) {
                if (text[j] == '[') depth += 1;
                if (text[j] == ']') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            try out.appendSlice(arena, "data");
            i = j + 1;
        } else if (boundary and std.mem.startsWith(u8, rest, "a.air.")) {
            try out.appendSlice(arena, "air.");
            i += "a.air.".len;
        } else {
            try out.append(arena, text[i]);
            i += 1;
        }
    }
    const z = try arena.allocSentinel(u8, out.items.len, 0);
    @memcpy(z, out.items);
    var tokenizer = std.zig.Tokenizer.init(z);
    var prev: std.zig.Token.Tag = .invalid;
    while (true) {
        const token = tokenizer.next();
        defer prev = token.tag;
        if (token.tag == .eof) break;
        if (token.tag != .identifier or prev == .period) continue;
        for (reject) |name| if (std.mem.eql(u8, z[token.loc.start..token.loc.end], name)) return null;
    }
    return z;
}

fn firstDataField(texts: []const []const u8) ?[]const u8 {
    for (texts) |t| {
        const at = std.mem.indexOf(u8, t, "data.") orelse continue;
        const rest = t[at + "data.".len ..];
        var end: usize = 0;
        while (end < rest.len and isIdent(rest[end])) end += 1;
        if (end != 0) return rest[0..end];
    }
    return null;
}

fn simpleShape(s: Source, arena: Allocator, body: Node.Index, tags: []const []const u8) !Shape {
    const tree = s.tree;
    var buf: [2]Node.Index = undefined;
    const stmts: []const Node.Index = tree.blockStatements(&buf, body) orelse &.{body};
    if (stmts.len == 0) return .manual;

    var decls: std.ArrayList(Decl) = .empty;
    for (stmts[0 .. stmts.len - 1]) |stmt| {
        const vd = tree.fullVarDecl(stmt) orelse return .manual;
        if (tree.tokenTag(vd.ast.mut_token) != .keyword_const) return .manual;
        const init = vd.ast.init_node.unwrap() orelse return .manual;
        const text = try rewrite(arena, try squash(arena, s.src(init))) orelse return .manual;
        try decls.append(arena, .{ .name = tree.tokenSlice(vd.ast.mut_token + 1), .text = text });
    }

    const last = stmts[stmts.len - 1];
    if (tree.nodeTag(last) != .@"return") return .manual;
    const value = tree.nodeData(last).opt_node.unwrap() orelse return .manual;
    var cbuf: [1]Node.Index = undefined;
    const call = tree.fullCall(&cbuf, value) orelse return .manual;
    const callee = s.src(call.ast.fn_expr);
    if (!std.mem.eql(u8, callee, "analyzeOperands") and !std.mem.eql(u8, callee, "analyzeFuncEnd")) return .manual;
    var abuf: [2]Node.Index = undefined;
    const tuple = tree.fullArrayInit(&abuf, call.ast.params[call.ast.params.len - 1]) orelse return .manual;

    var ops: std.ArrayList([]const u8) = .empty;
    for (tuple.ast.elements) |e| {
        const text = try rewrite(arena, try squash(arena, s.src(e))) orelse return .manual;
        if (!std.mem.eql(u8, text, ".none")) try ops.append(arena, text);
    }
    for (v1_order) |o| {
        if (tags.len != 1 or !std.mem.eql(u8, tags[0], o.tag)) continue;
        const permuted = try arena.alloc([]const u8, o.perm.len);
        for (o.perm, permuted) |from, *slot| slot.* = ops.items[from];
        ops.items = permuted;
    }

    var texts: std.ArrayList([]const u8) = .empty;
    for (decls.items) |d| try texts.append(arena, d.text);
    try texts.appendSlice(arena, ops.items);
    return .{ .simple = .{ .decls = decls.items, .ops = ops.items, .field = firstDataField(texts.items) } };
}

fn livenessProngs(s: Source, arena: Allocator) ![]const Prong {
    const sw = try s.switchIn(try s.fnDecl("analyzeInst"), "inst_tags");
    var out: std.ArrayList(Prong) = .empty;
    for (sw.ast.cases) |case_node| {
        const case = s.tree.fullSwitchCase(case_node).?;
        const tags = try s.caseTags(arena, case);
        const shape: Shape = if (s.tree.nodeTag(case.ast.target_expr) == .unreachable_literal)
            .manual
        else
            try simpleShape(s, arena, case.ast.target_expr, tags);
        try out.append(arena, .{ .tags = tags, .shape = shape });
    }
    return out.items;
}

const Field = struct { tag: []const u8, field: []const u8, line: usize = 0 };

fn typeOfFields(s: Source, arena: Allocator) ![]const Field {
    const sw = try s.switchIn(try s.fnDecl("typeOfIndex"), "items(.tag)");
    var out: std.ArrayList(Field) = .empty;
    for (sw.ast.cases) |case_node| {
        const case = s.tree.fullSwitchCase(case_node).?;
        const text = s.src(case.ast.target_expr);
        const at = std.mem.indexOf(u8, text, "datas[") orelse continue;
        const field = (firstDataFieldAfterIndex(text[at..]) orelse continue);
        for (try s.caseTags(arena, case)) |tag| try out.append(arena, .{ .tag = tag, .field = field, .line = s.line(s.tree.firstToken(case_node)) });
    }
    return out.items;
}

fn firstDataFieldAfterIndex(text: []const u8) ?[]const u8 {
    var depth: usize = 0;
    var j: usize = "datas".len;
    while (j < text.len) : (j += 1) {
        if (text[j] == '[') depth += 1;
        if (text[j] == ']') {
            depth -= 1;
            if (depth == 0) break;
        }
    }
    if (j + 1 >= text.len or text[j + 1] != '.') return null;
    var end = j + 2;
    while (end < text.len and isIdent(text[end])) end += 1;
    return text[j + 2 .. end];
}

fn tagNames(s: Source, arena: Allocator) ![]const []const u8 {
    for (0..s.count()) |i| {
        const n = s.at(i);
        const vd = s.tree.fullVarDecl(n) orelse continue;
        if (!std.mem.eql(u8, s.tree.tokenSlice(vd.ast.mut_token + 1), "Tag")) continue;
        const init = vd.ast.init_node.unwrap() orelse continue;
        var out: std.ArrayList([]const u8) = .empty;
        for (0..s.count()) |j| {
            const f = s.at(j);
            if (!s.inside(f, init) or f == init) continue;
            const cf = s.tree.fullContainerField(f) orelse continue;
            try out.append(arena, s.tree.tokenSlice(cf.ast.main_token));
        }
        if (out.items.len > 100) return out.items;
    }
    return error.TagEnumNotFound;
}

const Helper = struct { name: []const u8, field: []const u8, tag_param: ?usize, fixed: ?[]const u8, nparams: usize };

fn paramNames(s: Source, arena: Allocator, decl: Node.Index) ![]const []const u8 {
    var buf: [1]Node.Index = undefined;
    const proto = s.tree.fullFnProto(&buf, s.tree.nodeData(decl).node_and_node[0]).?;
    var out: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var k = proto.lparen;
    while (true) : (k += 1) {
        switch (s.tree.tokenTag(k)) {
            .l_paren, .l_brace, .l_bracket => depth += 1,
            .r_paren, .r_brace, .r_bracket => {
                depth -= 1;
                if (depth == 0) break;
            },
            .identifier => if (depth == 1 and s.tree.tokenTag(k + 1) == .colon) try out.append(arena, s.tree.tokenSlice(k)),
            else => {},
        }
    }
    return out.items;
}

const TagData = struct { tags: []const []const u8, field: []const u8, line: usize };

/// `.{ .tag = <tags>, .data = .{ .field = ... } }` in `n`.
fn tagDataInit(s: Source, arena: Allocator, n: Node.Index) !?TagData {
    var buf: [2]Node.Index = undefined;
    const init = s.tree.fullStructInit(&buf, n) orelse return null;
    var tag_node: ?Node.Index = null;
    var data_node: ?Node.Index = null;
    for (init.ast.fields) |f| {
        const name = s.tree.tokenSlice(s.tree.firstToken(f) - 2);
        if (std.mem.eql(u8, name, "tag")) tag_node = f;
        if (std.mem.eql(u8, name, "data")) data_node = f;
    }
    const data_init = s.tree.fullStructInit(&buf, data_node orelse return null) orelse return null;
    if (data_init.ast.fields.len != 1) return null;
    const field = s.tree.tokenSlice(s.tree.firstToken(data_init.ast.fields[0]) - 2);

    const tn = tag_node orelse return null;
    var tags: std.ArrayList([]const u8) = .empty;
    if (s.enumLiteral(tn)) |t| {
        try tags.append(arena, t);
    } else {
        const first = s.tree.firstToken(tn);
        var k = first;
        while (k < s.tree.lastToken(tn)) : (k += 1) {
            if (s.tree.tokenTag(k) != .period or s.tree.tokenTag(k + 1) != .identifier) continue;
            const prev = if (k == first) .comma else s.tree.tokenTag(k - 1);
            switch (prev) {
                .identifier, .r_paren, .r_bracket, .r_brace, .period => continue,
                else => try tags.append(arena, s.tree.tokenSlice(k + 1)),
            }
        }
    }
    return .{ .tags = tags.items, .field = field, .line = s.line(s.tree.firstToken(n)) };
}

fn semaWrites(s: Source, arena: Allocator) ![]const Field {
    var out: std.ArrayList(Field) = .empty;
    var helpers: std.ArrayList(Helper) = .empty;

    for (0..s.count()) |i| {
        const decl = s.at(i);
        if (s.tree.nodeTag(decl) != .fn_decl) continue;
        const name = s.fnName(decl) orelse continue;
        if (!std.mem.startsWith(u8, name, "add")) continue;
        const params = try paramNames(s, arena, decl);
        for (0..s.count()) |j| {
            const n = s.at(j);
            const td = try tagDataInit(s, arena, n) orelse continue;
            if (td.tags.len != 0 or !s.inside(n, s.fnBody(decl))) continue;
            var buf: [2]Node.Index = undefined;
            const init = s.tree.fullStructInit(&buf, n).?;
            for (init.ast.fields) |f| {
                if (!std.mem.eql(u8, s.tree.tokenSlice(s.tree.firstToken(f) - 2), "tag")) continue;
                const text = s.src(f);
                const idx = for (params, 0..) |p, k| {
                    if (std.mem.eql(u8, p, text)) break k;
                } else null;
                if (idx != null) try helpers.append(arena, .{ .name = name, .field = td.field, .tag_param = idx, .fixed = null, .nparams = params.len });
            }
        }
    }

    for (0..s.count()) |i| {
        const n = s.at(i);
        if (try tagDataInit(s, arena, n)) |td| {
            for (td.tags) |t| try out.append(arena, .{ .tag = t, .field = td.field, .line = td.line });
            continue;
        }
        var cbuf: [1]Node.Index = undefined;
        const call = s.tree.fullCall(&cbuf, n) orelse continue;
        const callee = s.tree.tokenSlice(s.tree.lastToken(call.ast.fn_expr));
        for (helpers.items) |h| {
            if (!std.mem.eql(u8, h.name, callee)) continue;
            const skip: usize = h.nparams - call.ast.params.len;
            const idx = (h.tag_param orelse continue);
            if (idx < skip) continue;
            const tag = s.enumLiteral(call.ast.params[idx - skip]) orelse continue;
            try out.append(arena, .{ .tag = tag, .field = h.field, .line = s.line(s.tree.firstToken(n)) });
        }
    }
    return out.items;
}

fn indexOfTag(list: []const []const u8, tag: []const u8) ?usize {
    for (list, 0..) |t, i| if (std.mem.eql(u8, t, tag)) return i;
    return null;
}

const Report = struct {
    tags: usize = 0,
    generated: usize = 0,
    manual: usize = 0,
    liveness_fields: usize = 0,
    type_of_fields: usize = 0,
    sema_tags: usize = 0,
    compared: usize = 0,
    conflicts: usize = 0,
};

fn crossCheck(
    arena: Allocator,
    tags: []const []const u8,
    prongs: []const Prong,
    type_of: []const Field,
    sema: []const Field,
    report: *Report,
) !void {
    for (tags) |tag| {
        var live: ?[]const u8 = null;
        for (prongs) |p| {
            if (indexOfTag(p.tags, tag) == null) continue;
            if (p.shape == .simple) live = p.shape.simple.field;
        }
        var ty: ?[]const u8 = null;
        for (type_of) |f| if (std.mem.eql(u8, f.tag, tag)) {
            ty = f.field;
        };
        var seen: std.ArrayList([]const u8) = .empty;
        for (sema) |f| {
            if (!std.mem.eql(u8, f.tag, tag)) continue;
            if (indexOfTag(seen.items, f.field) == null) try seen.append(arena, f.field);
        }
        if (live != null) report.liveness_fields += 1;
        if (ty != null) report.type_of_fields += 1;
        if (seen.items.len != 0) report.sema_tags += 1;

        var views: std.ArrayList([]const u8) = .empty;
        if (live) |f| try views.append(arena, f);
        if (ty) |f| if (indexOfTag(views.items, f) == null) try views.append(arena, f);
        for (seen.items) |f| if (indexOfTag(views.items, f) == null) try views.append(arena, f);
        const n_sources = @as(usize, @intFromBool(live != null)) + @intFromBool(ty != null) + @intFromBool(seen.items.len != 0);
        if (n_sources >= 2) report.compared += 1;
        if (views.items.len <= 1) continue;
        if (indexOfTag(&known_conflicts, tag) != null) continue;
        report.conflicts += 1;
        std.debug.print("conflict: .{s}: liveness={?s} typeOf={?s}\n", .{ tag, live, ty });
        for (type_of) |f| if (std.mem.eql(u8, f.tag, tag)) std.debug.print("  Air.zig:{d} {s}\n", .{ f.line, f.field });
        for (sema) |f| if (std.mem.eql(u8, f.tag, tag)) std.debug.print("  Sema.zig:{d} {s}\n", .{ f.line, f.field });
    }
}

fn writeTags(w: *std.Io.Writer, tags: []const []const u8, indent: []const u8) !void {
    try w.writeAll(indent);
    if (tags.len == 1) return w.print(".{s} =>", .{tags[0]});
    for (tags) |t| try w.print(".{s},\n{s}", .{ t, indent });
    try w.writeAll("=>");
}

fn emit(
    w: *std.Io.Writer,
    prongs: []const Prong,
    version: []const u8,
    hashes: []const [2][]const u8,
    report: Report,
) !void {
    try w.print(
        \\//! Generated by tools/zv_gen.zig from Zig {s}. Do not edit; rerun the generator and review the diff.
        \\//! Operands come from Air/Liveness.zig `analyzeInst`; Air.typeOfIndex and Sema's writes were cross-checked
        \\//! for the data union field ({d} tags compared, {d} conflicts).
        \\
        \\const std = @import("std");
        \\const Air = @import("../Air.zig");
        \\
        \\const sources = [_]struct {{ []const u8, u64 }}{{
        \\
    , .{ version, report.compared, report.conflicts });
    for (hashes) |h| try w.print("    .{{ \"{s}\", {s} }},\n", .{ h[0], h[1] });
    try w.writeAll(
        \\};
        \\
        \\comptime {
        \\    @setEvalBranchQuota(100_000_000);
        \\    for (sources) |source| {
        \\        if (std.hash.Wyhash.hash(0, @embedFile(source[0])) != source[1])
        \\            @compileError(source[0] ++ " changed since shapes.zig was generated: rerun tools/zv_gen.zig");
        \\    }
        \\}
        \\
        \\/// Prongs of Liveness `analyzeInst` that need hand-written decoding, named after their first tag.
        \\pub const Manual = enum {
        \\
    );
    for (prongs) |p| if (p.shape == .manual) try w.print("    {s},\n", .{p.tags[0]});
    try w.writeAll(
        \\};
        \\
        \\pub fn operands(a: anytype, air: *const Air, tag: Air.Inst.Tag, data: Air.Inst.Data) !?Manual {
        \\    switch (tag) {
        \\
    );
    for (prongs) |p| {
        try writeTags(w, p.tags, "        ");
        switch (p.shape) {
            .manual => try w.print(" return .{s},\n", .{p.tags[0]}),
            .simple => |sh| {
                if (sh.decls.len == 0 and sh.ops.len == 0) {
                    try w.writeAll(" {},\n");
                    continue;
                }
                try w.writeAll(" {\n");
                for (sh.decls) |d| try w.print("            const {s} = {s};\n", .{ d.name, d.text });
                if (sh.ops.len != 0) {
                    const pad = if (sh.ops.len == 1) "" else " ";
                    try w.print("            try a.ops(&.{{{s}", .{pad});
                    for (sh.ops, 0..) |o, i| try w.print("{s}{s}", .{ if (i == 0) "" else ", ", o });
                    try w.print("{s}}});\n", .{pad});
                }
                if (sh.field) |f| try w.print("            try a.field(.{s}, data.{s});\n", .{ f, f });
                for (sh.decls) |d| {
                    if (std.mem.indexOf(u8, d.text, "extraData(") != null) try w.print("            try a.extra({s});\n", .{d.name});
                }
                try w.writeAll("        },\n");
            },
        }
    }
    try w.writeAll(
        \\    }
        \\    return null;
        \\}
        \\
    );
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const check = args.len == 5 and std.mem.eql(u8, args[4], "--check");
    if (args.len != 4 and !check) {
        std.debug.print("usage: zv_gen ZIG_TREE VERSION OUT.zig [--check]\n", .{});
        std.process.exit(2);
    }
    const root = args[1];

    const liveness = try Source.load(arena, io, root, "Air/Liveness.zig");
    const air = try Source.load(arena, io, root, "Air.zig");
    const sema = try Source.load(arena, io, root, "Sema.zig");

    const prongs = try livenessProngs(liveness, arena);
    const tags = try tagNames(air, arena);
    const type_of = try typeOfFields(air, arena);
    const sema_fields = try semaWrites(sema, arena);

    var report: Report = .{ .tags = tags.len };
    for (prongs) |p| {
        for (p.tags) |t| if (indexOfTag(tags, t) == null) {
            std.debug.print("Liveness names a tag Air.Inst.Tag lacks: {s}\n", .{t});
            std.process.exit(1);
        };
        switch (p.shape) {
            .simple => report.generated += p.tags.len,
            .manual => report.manual += p.tags.len,
        }
    }
    if (report.generated + report.manual != tags.len) {
        std.debug.print("Liveness covers {d} of {d} tags\n", .{ report.generated + report.manual, tags.len });
        std.process.exit(1);
    }
    try crossCheck(arena, tags, prongs, type_of, sema_fields, &report);

    const version = args[2];
    const hashes = [_][2][]const u8{
        .{ "../Air.zig", try std.fmt.allocPrint(arena, "0x{x}", .{std.hash.Wyhash.hash(0, air.text)}) },
        .{ "../Air/Liveness.zig", try std.fmt.allocPrint(arena, "0x{x}", .{std.hash.Wyhash.hash(0, liveness.text)}) },
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    try emit(&aw.writer, prongs, version, &hashes, report);

    std.debug.print(
        "tags {d}: generated {d}, manual {d}; fields liveness {d} typeOf {d} sema {d}; compared {d}, conflicts {d}\n",
        .{ report.tags, report.generated, report.manual, report.liveness_fields, report.type_of_fields, report.sema_tags, report.compared, report.conflicts },
    );
    if (report.conflicts != 0) std.process.exit(1);

    const cwd = std.Io.Dir.cwd();
    if (check) {
        const existing = try cwd.readFileAlloc(io, args[3], arena, .limited(1 << 24));
        if (!std.mem.eql(u8, existing, aw.written())) {
            std.debug.print("{s} is stale\n", .{args[2]});
            std.process.exit(1);
        }
        return;
    }
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = aw.written() });
}
