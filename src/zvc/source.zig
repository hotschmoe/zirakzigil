//! What AIR does not carry, read from the source with `std.zig.Ast`: the assurance manifest, parameter
//! names, and the text of a line for diagnostics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

pub const Level = enum { verified, checked, tested, trusted, other };

pub const Entry = struct {
    /// Qualified like the compiler names the function: `search.midpoint`, `wire.tcp.SeqNumber.add`.
    name: []const u8,
    level: Level,
};

/// One line of a manifest as written: the qualified name and the enum literal after it.
pub const RawEntry = struct { name: []const u8, tag: []const u8 };

pub const Source = struct {
    text: [:0]const u8,
    tree: Ast,
    /// `wire/tcp.zig` is `wire.tcp`.
    module_path: []const u8,

    pub fn parse(gpa: Allocator, rel_path: []const u8, text: [:0]const u8) error{ OutOfMemory, BadSource }!Source {
        const tree = try Ast.parse(gpa, text, .{});
        if (tree.errors.len != 0) return error.BadSource;
        const stem = if (std.mem.endsWith(u8, rel_path, ".zig")) rel_path[0 .. rel_path.len - 4] else rel_path;
        const module_path = try gpa.dupe(u8, stem);
        std.mem.replaceScalar(u8, module_path, '/', '.');
        return .{ .text = text, .tree = tree, .module_path = module_path };
    }

    const Scope = struct { name: []const u8, start: u32, end: u32 };

    fn spanOf(tree: *const Ast, node: Ast.Node.Index) struct { u32, u32 } {
        const last = tree.lastToken(node);
        return .{ tree.tokenStart(tree.firstToken(node)), tree.tokenStart(last) + @as(u32, @intCast(tree.tokenSlice(last).len)) };
    }

    /// Every `assurance` declaration with the levels it lists, named by enclosing scopes.
    pub fn entries(s: *const Source, arena: Allocator) Allocator.Error![]const Entry {
        const raw = try s.rawEntries(arena, "assurance");
        const out = try arena.alloc(Entry, raw.len);
        for (out, raw) |*slot, e| slot.* = .{ .name = e.name, .level = std.meta.stringToEnum(Level, e.tag) orelse .other };
        return out;
    }

    /// Every declaration called `decl_name` (`assurance`, `ownership`) with the enum literals it lists, named by
    /// enclosing scopes.
    pub fn rawEntries(s: *const Source, arena: Allocator, decl_name: []const u8) Allocator.Error![]const RawEntry {
        const tree = &s.tree;
        var scopes: std.ArrayList(Scope) = .empty;
        var manifests: std.ArrayList(Ast.Node.Index) = .empty;
        var buf: [2]Ast.Node.Index = undefined;
        for (0..tree.nodes.len) |i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            switch (tree.nodeTag(node)) {
                .fn_decl => {
                    var proto_buf: [1]Ast.Node.Index = undefined;
                    const proto = tree.fullFnProto(&proto_buf, node).?;
                    const name_token = proto.name_token orelse continue;
                    const start, const end = spanOf(tree, node);
                    try scopes.append(arena, .{ .name = tree.tokenSlice(name_token), .start = start, .end = end });
                },
                .simple_var_decl, .global_var_decl, .local_var_decl, .aligned_var_decl => {
                    const decl = tree.fullVarDecl(node).?;
                    const name = tree.tokenSlice(decl.ast.mut_token + 1);
                    const init_node = decl.ast.init_node.unwrap() orelse continue;
                    if (std.mem.eql(u8, name, decl_name)) {
                        try manifests.append(arena, init_node);
                    } else if (tree.fullContainerDecl(&buf, init_node) != null) {
                        const start, const end = spanOf(tree, init_node);
                        try scopes.append(arena, .{ .name = name, .start = start, .end = end });
                    }
                },
                else => {},
            }
        }
        var out: std.ArrayList(RawEntry) = .empty;
        for (manifests.items) |init_node| {
            const start, _ = spanOf(tree, init_node);
            var prefix: std.ArrayList(u8) = .empty;
            try prefix.appendSlice(arena, s.module_path);
            var chain: std.ArrayList(Scope) = .empty;
            for (scopes.items) |sc| if (sc.start < start and start < sc.end) try chain.append(arena, sc);
            std.mem.sort(Scope, chain.items, {}, struct {
                fn lessThan(_: void, a: Scope, b: Scope) bool {
                    return a.start < b.start;
                }
            }.lessThan);
            for (chain.items) |sc| {
                try prefix.append(arena, '.');
                try prefix.appendSlice(arena, sc.name);
            }
            try s.walkManifest(arena, init_node, prefix.items, &out);
        }
        return out.items;
    }

    fn walkManifest(s: *const Source, arena: Allocator, node: Ast.Node.Index, prefix: []const u8, out: *std.ArrayList(RawEntry)) Allocator.Error!void {
        const tree = &s.tree;
        var buf: [2]Ast.Node.Index = undefined;
        const init = tree.fullStructInit(&buf, node) orelse return;
        for (init.ast.fields) |field| {
            const name = tree.tokenSlice(tree.firstToken(field) - 2);
            const qualified = try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, name });
            if (tree.nodeTag(field) == .enum_literal) {
                try out.append(arena, .{ .name = qualified, .tag = tree.tokenSlice(tree.nodeMainToken(field)) });
            } else try s.walkManifest(arena, field, qualified, out);
        }
    }

    /// Names of the runtime parameters of the function `name` declared on `line` (1-based).
    pub fn paramNames(s: *const Source, arena: Allocator, name: []const u8, line: u32) Allocator.Error!?[]const []const u8 {
        const tree = &s.tree;
        for (0..tree.nodes.len) |i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (tree.nodeTag(node) != .fn_decl) continue;
            var proto_buf: [1]Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&proto_buf, node).?;
            const name_token = proto.name_token orelse continue;
            if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;
            if (tree.tokenLocation(0, proto.ast.fn_token).line + 1 != line) continue;
            var names: std.ArrayList([]const u8) = .empty;
            var it = proto.iterate(tree);
            while (it.next()) |param| {
                if (param.comptime_noalias) |t| if (tree.tokenTag(t) == .keyword_comptime) continue;
                if (param.type_expr) |te| if (std.mem.eql(u8, tree.getNodeSource(te), "type")) continue;
                try names.append(arena, if (param.name_token) |t| tree.tokenSlice(t) else "_");
            }
            return names.items;
        }
        return null;
    }

    /// The name of field `index` of the struct this file declares as `const NAME = struct { ... }`, where `type_name`
    /// ends in NAME.
    pub fn fieldName(s: *const Source, type_name: []const u8, index: u32) ?[]const u8 {
        const tree = &s.tree;
        const want = if (std.mem.lastIndexOfScalar(u8, type_name, '.')) |i| type_name[i + 1 ..] else type_name;
        var buf: [2]Ast.Node.Index = undefined;
        for (0..tree.nodes.len) |i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            switch (tree.nodeTag(node)) {
                .simple_var_decl, .global_var_decl, .local_var_decl, .aligned_var_decl => {},
                else => continue,
            }
            const decl = tree.fullVarDecl(node).?;
            if (!std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), want)) continue;
            const init_node = decl.ast.init_node.unwrap() orelse continue;
            const container = tree.fullContainerDecl(&buf, init_node) orelse continue;
            var k: u32 = 0;
            for (container.ast.members) |member| {
                const field = tree.fullContainerField(member) orelse continue;
                if (k == index) return tree.tokenSlice(field.ast.main_token);
                k += 1;
            }
        }
        return null;
    }

    /// Line `n` (1-based) without its newline.
    pub fn lineText(s: *const Source, n: u32) ?[]const u8 {
        var it = std.mem.splitScalar(u8, s.text, '\n');
        var i: u32 = 1;
        while (it.next()) |l| : (i += 1) if (i == n) return std.mem.trimEnd(u8, l, "\r");
        return null;
    }
};

/// The declared name of a pack function: type arguments (`Ring(u8).push`) and instance suffixes
/// (`push__func`, `push__anon`) are not part of what a manifest says.
pub fn declaredName(arena: Allocator, fqn: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    for (fqn) |c| {
        if (c == '(') depth += 1;
        if (depth == 0) try out.append(arena, c);
        if (c == ')' and depth > 0) depth -= 1;
    }
    var name: []const u8 = out.items;
    for ([_][]const u8{ "__func", "__anon" }) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) name = name[0 .. name.len - suffix.len];
    }
    return name;
}
