//! Build-time tool behind `addAssuranceGate`: copies a source tree and plants a
//! `zv.cover` hit at the top of every function body, so a test run reports
//! which functions it actually executed. Usage:
//!
//!     instrument <src_dir> <out_dir> <map_file> <dep_file> [<evidence_file>...]
//!
//! Every `test` block is blanked out of the copy except those in the evidence files
//! (paths relative to `src_dir`): unit tests cannot supply evidence because they do
//! not exist in the tree the evidence suites are built from.
//!
//! The map file has one `id<TAB>module<TAB>declaration` line per function, for
//! example `7<TAB>wire.tcp<TAB>Repr.parse`; module.declaration is the spelling
//! `zv.manifest.audit` claims use once instantiation arguments are stripped.
//! The repository is never modified, and source that mentions the hit function
//! itself is rejected, so evidence cannot be forged from inside. The dep file
//! lists every source read: the build reruns the tool when one changes, which a
//! directory argument alone does not do.

const std = @import("std");
const Ast = std.zig.Ast;
const Io = std.Io;

const forbidden = "cover" ++ ".hit";

const Scope = struct {
    name: []const u8,
    start: u32,
    end: u32,
};

const Fn = struct {
    scope: Scope,
    body_open: u32,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 5) fatal("usage: instrument <src_dir> <out_dir> <map_file> <dep_file> [<evidence_file>...]", .{});
    const evidence = args[5..];

    var src = try Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer src.close(io);
    var out = try Io.Dir.cwd().openDir(io, args[2], .{});
    defer out.close(io);

    var map: std.ArrayList(u8) = .empty;
    defer map.deinit(gpa);
    var deps: std.ArrayList(u8) = .empty;
    try deps.print(gpa, "{s}:", .{args[3]});
    var next_id: u32 = 0;

    var walker = try src.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const source = try entry.dir.readFileAllocOptions(io, entry.basename, gpa, .unlimited, .of(u8), 0);
        defer gpa.free(source);

        const rel = try gpa.dupe(u8, entry.path);
        defer gpa.free(rel);
        std.mem.replaceScalar(u8, rel, '\\', '/');

        try deps.print(gpa, " {s}/{s}", .{ std.mem.trimEnd(u8, args[1], "/\\"), rel });
        const keep_tests = for (evidence) |e| {
            if (std.mem.eql(u8, e, rel)) break true;
        } else false;
        const text = try instrument(gpa, rel, source, keep_tests, &next_id, &map);
        defer gpa.free(text);
        if (std.fs.path.dirnamePosix(rel)) |dir| try out.createDirPath(io, dir);
        try out.writeFile(io, .{ .sub_path = rel, .data = text });
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = map.items });
    try deps.append(gpa, 10);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[4], .data = deps.items });
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zv-instrument: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn instrument(gpa: std.mem.Allocator, rel: []const u8, source: [:0]const u8, keep_tests: bool, next_id: *u32, map: *std.ArrayList(u8)) ![]u8 {
    if (std.mem.indexOf(u8, source, forbidden) != null)
        fatal("{s} mentions `{s}`; coverage evidence is planted by the build, never written by hand", .{ rel, forbidden });

    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) fatal("{s} does not parse", .{rel});

    var scopes: std.ArrayList(Scope) = .empty;
    defer scopes.deinit(gpa);
    var fns: std.ArrayList(Fn) = .empty;
    defer fns.deinit(gpa);
    var tests: std.ArrayList(Scope) = .empty;
    defer tests.deinit(gpa);

    var container_buf: [2]Ast.Node.Index = undefined;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        switch (tree.nodeTag(node)) {
            .fn_decl => {
                var proto_buf: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&proto_buf, node).?;
                const name_token = proto.name_token orelse continue;
                const body = tree.nodeData(node).node_and_node[1];
                const scope = scopeOf(tree, tree.tokenSlice(name_token), node);
                try scopes.append(gpa, scope);
                if (isComptimeOnly(tree, proto)) continue;
                try fns.append(gpa, .{ .scope = scope, .body_open = tree.tokenStart(tree.nodeMainToken(body)) });
            },
            .simple_var_decl, .global_var_decl, .local_var_decl, .aligned_var_decl => {
                const decl = tree.fullVarDecl(node).?;
                const init_node = decl.ast.init_node.unwrap() orelse continue;
                if (tree.fullContainerDecl(&container_buf, init_node) == null) continue;
                try scopes.append(gpa, scopeOf(tree, tree.tokenSlice(decl.ast.mut_token + 1), init_node));
            },
            .test_decl => if (!keep_tests) try tests.append(gpa, scopeOf(tree, "", node)),
            else => {},
        }
    }

    const text = try gpa.dupe(u8, source);
    defer gpa.free(text);
    for (tests.items) |t| {
        for (text[t.start..t.end]) |*c| {
            if (c.* != 10 and c.* != 13) c.* = ' ';
        }
    }
    var kept: usize = 0;
    for (fns.items) |f| {
        const inside_test = for (tests.items) |t| {
            if (f.body_open >= t.start and f.body_open < t.end) break true;
        } else false;
        if (!inside_test) {
            fns.items[kept] = f;
            kept += 1;
        }
    }
    fns.shrinkRetainingCapacity(kept);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const module = try modulePath(gpa, rel);
    defer gpa.free(module);

    std.mem.sort(Fn, fns.items, {}, struct {
        fn lessThan(_: void, a: Fn, b: Fn) bool {
            return a.body_open < b.body_open;
        }
    }.lessThan);

    var copied: usize = 0;
    for (fns.items) |f| {
        try out.appendSlice(gpa, text[copied .. f.body_open + 1]);
        try out.print(gpa, " @import(\"zv\").cover.hit({d});", .{next_id.*});
        copied = f.body_open + 1;
        try map.print(gpa, "{d}\t{s}\t{s}\n", .{ next_id.*, module, try qualified(gpa, scopes.items, f.scope) });
        next_id.* += 1;
    }
    try out.appendSlice(gpa, text[copied..]);
    return out.toOwnedSlice(gpa);
}

fn scopeOf(tree: Ast, name: []const u8, node: Ast.Node.Index) Scope {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    return .{
        .name = name,
        .start = tree.tokenStart(first),
        .end = tree.tokenStart(last) + @as(u32, @intCast(tree.tokenSlice(last).len)),
    };
}

/// Type constructors and functions whose result is a type run only at comptime.
fn isComptimeOnly(tree: Ast, proto: Ast.full.FnProto) bool {
    if (proto.ast.callconv_expr.unwrap()) |cc| {
        const text = tree.tokenSlice(tree.firstToken(cc));
        if (std.mem.eql(u8, text, ".naked")) return true;
        if (std.mem.eql(u8, tree.tokenSlice(tree.lastToken(cc)), "naked")) return true;
    }
    const rt = proto.ast.return_type.unwrap() orelse return false;
    return tree.firstToken(rt) == tree.lastToken(rt) and std.mem.eql(u8, tree.tokenSlice(tree.firstToken(rt)), "type");
}

/// `wire/tcp.zig` is `wire.tcp`, the name Zig gives the file's struct.
fn modulePath(gpa: std.mem.Allocator, rel: []const u8) ![]u8 {
    const stem = rel[0 .. rel.len - ".zig".len];
    const out = try gpa.dupe(u8, stem);
    std.mem.replaceScalar(u8, out, '/', '.');
    return out;
}

/// Names of the enclosing named containers and functions, outermost first.
fn qualified(gpa: std.mem.Allocator, scopes: []const Scope, f: Scope) ![]const u8 {
    var chain: std.ArrayList(Scope) = .empty;
    defer chain.deinit(gpa);
    for (scopes) |s| {
        if (s.start == f.start and s.end == f.end) continue;
        if (s.start <= f.start and f.end <= s.end) try chain.append(gpa, s);
    }
    std.mem.sort(Scope, chain.items, {}, struct {
        fn lessThan(_: void, a: Scope, b: Scope) bool {
            return a.start < b.start or (a.start == b.start and a.end > b.end);
        }
    }.lessThan);
    var name: std.ArrayList(u8) = .empty;
    for (chain.items) |s| try name.print(gpa, "{s}.", .{s.name});
    try name.appendSlice(gpa, f.name);
    return name.toOwnedSlice(gpa);
}
