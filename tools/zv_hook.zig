//! Declarative hook inserter for the zig-zv fork.
//!   zv_hook check  RULES.zon ZIG_ROOT    every anchor resolves exactly once (applied or pending); writes nothing
//!   zv_hook apply  RULES.zon ZIG_ROOT    insert what is missing; all or nothing; idempotent
//!   zv_hook verify RULES.zon ZIG_ROOT    every rule is applied, exactly once, at its anchor
//!   zv_hook undo   RULES.zon ZIG_ROOT    remove every inserted block
//! An anchor is either `.text` (whole lines, compared without indentation) or a structural anchor
//! found through std.zig.Ast. Insertions are whole lines before or after the anchor's lines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Io = std.Io;

const Rules = struct { rules: []const Rule };

const Rule = struct {
    name: []const u8,
    file: []const u8,
    anchor: Anchor,
    position: enum { before, after },
    insert: []const u8,
};

const Anchor = union(enum) {
    /// One or more whole lines.
    text: []const u8,
    /// One line, required to follow the line `prev`; for lines that repeat in a file.
    text_after: struct { prev: []const u8, line: []const u8 },
    /// A top-level declaration (constant, variable or function) of the file, by name.
    decl: []const u8,
    /// A top-level statement of the function body.
    fn_stmt: struct { fn_name: []const u8, stmt: Stmt },
    /// A field of a container; the empty name selects the file's own struct.
    container_field: struct { container: []const u8 = "", field: Field },
    /// `.field = value` inside any struct initializer within the function.
    init_field: struct { fn_name: []const u8, field: []const u8 },
};

const Stmt = union(enum) { first, last, calls: []const u8 };
const Field = union(enum) { first, last, named: []const u8 };

const Command = enum { check, apply, verify, undo };

const Hit = struct { start: usize, end: usize };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return usage();
    const command = std.meta.stringToEnum(Command, args[1]) orelse return usage();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rules = try loadRules(arena, io, args[2]);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &stderr_buffer);
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);

    var run: Run = .{ .arena = arena, .io = io, .root = args[3], .err = &stderr.interface, .out = &stdout.interface };
    const ok = try run.all(command, rules.rules);
    try stdout.interface.flush();
    try stderr.interface.flush();
    if (!ok or (command == .verify and run.warnings != 0)) std.process.exit(1);
}

fn usage() !void {
    std.log.err("usage: zv_hook check|apply|verify|undo RULES.zon ZIG_ROOT", .{});
    std.process.exit(2);
}

fn loadRules(arena: Allocator, io: Io, path: []const u8) !Rules {
    const source = try Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(Rules, .{ .gpa = arena, .arena = arena, .source = source, .diagnostics = &diagnostics }) catch |err| switch (err) {
        error.ParseZon => {
            std.log.err("{f}", .{diagnostics.fmt(path)});
            std.process.exit(2);
        },
        else => |e| return e,
    };
}

const Run = struct {
    arena: Allocator,
    io: Io,
    root: []const u8,
    err: *Io.Writer,
    out: *Io.Writer,
    warnings: usize = 0,

    const State = enum { pending, applied };

    fn all(run: *Run, command: Command, rules: []const Rule) !bool {
        var files: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        var failures: usize = 0;
        for (rules) |rule| {
            const gop = try files.getOrPut(run.arena, rule.file);
            if (!gop.found_existing) gop.value_ptr.* = try run.read(rule.file);
            const source = gop.value_ptr.*;
            const result = run.one(command, rule, source) catch |err| switch (err) {
                error.RuleFailed => {
                    failures += 1;
                    continue;
                },
                else => |e| return e,
            };
            gop.value_ptr.* = result;
        }
        if (failures != 0) {
            try run.err.print("{d} of {d} rules failed; nothing was written\n", .{ failures, rules.len });
            return false;
        }
        if (command == .apply or command == .undo) {
            for (files.keys(), files.values()) |file, source| try run.write(file, source);
        }
        return true;
    }

    /// Returns the file's new contents.
    fn one(run: *Run, command: Command, rule: Rule, source: []const u8) ![]const u8 {
        const block = try run.indented(rule, source);
        const found = try run.state(rule, source, block);
        switch (found.state) {
            .pending => switch (command) {
                .verify => return run.fail(rule, "not applied", .{}),
                .undo => {
                    try run.report(rule, "absent", source, 0);
                    return source;
                },
                .check, .apply => {
                    const at = try run.resolve(rule, source);
                    try run.warnSiblings(rule, source, at);
                    const offset = insertionOffset(rule, at);
                    try run.report(rule, if (command == .apply) "inserted" else "pending", source, offset);
                    if (command == .check) return source;
                    return std.mem.concat(run.arena, u8, &.{ source[0..offset], block, source[offset..] });
                },
            },
            .applied => {
                const stripped = try std.mem.concat(run.arena, u8, &.{ source[0..found.hit.start], source[found.hit.end..] });
                if (command == .undo) {
                    try run.report(rule, "removed", source, found.hit.start);
                    return stripped;
                }
                const at = try run.resolve(rule, stripped);
                try run.warnSiblings(rule, stripped, at);
                if (insertionOffset(rule, at) != found.hit.start)
                    return run.fail(rule, "inserted text is present but not at its anchor (the anchor now resolves to line {d}, the text is at line {d})", .{
                        lineOf(stripped, at.start),
                        lineOf(source, found.hit.start),
                    });
                try run.report(rule, "applied", source, found.hit.start);
                return source;
            },
        }
    }

    /// A hooked call that is also made elsewhere in the file may be a path the hook does not cover.
    fn warnSiblings(run: *Run, rule: Rule, source: []const u8, hit: Hit) !void {
        const callee = switch (rule.anchor) {
            .fn_stmt => |a| switch (a.stmt) {
                .calls => |name| name,
                else => return,
            },
            else => return,
        };
        for (try otherCalls(run.arena, source, callee, hit)) |offset| {
            run.warnings += 1;
            try run.err.print("warning: rule '{s}' ({s}): {s} is also called at line {d} and is not hooked there\n", .{ rule.name, rule.file, callee, lineOf(source, offset) });
        }
    }

    const Found = struct { state: State, hit: Hit = .{ .start = 0, .end = 0 } };

    fn state(run: *Run, rule: Rule, source: []const u8, block: []const u8) !Found {
        const hits = try textHits(run.arena, source, block);
        switch (hits.len) {
            0 => return .{ .state = .pending },
            1 => return .{ .state = .applied, .hit = hits[0] },
            else => return run.fail(rule, "the inserted text occurs {d} times", .{hits.len}),
        }
    }

    fn resolve(run: *Run, rule: Rule, source: []const u8) !Hit {
        const hits = try anchorHits(run.arena, source, rule.anchor);
        if (hits.len == 1) return hits[0];
        try run.err.print("error: rule '{s}' ({s}): anchor matched {d} times, expected exactly 1\n  anchor: ", .{ rule.name, rule.file, hits.len });
        try printAnchor(run.err, rule.anchor);
        try run.err.writeByte('\n');
        if (hits.len > 1) {
            try run.err.writeAll("  candidates:\n");
            for (hits) |hit| try run.line(rule.file, source, hit.start);
        } else {
            try run.err.writeAll("  nearest lines mentioning the anchor's names:\n");
            var shown: usize = 0;
            for (anchorWords(rule.anchor)) |word| {
                if (word.len == 0) continue;
                var it = std.mem.splitScalar(u8, source, '\n');
                var offset: usize = 0;
                while (it.next()) |text| : (offset += text.len + 1) {
                    if (shown == 8) break;
                    if (std.mem.find(u8, text, word) != null) {
                        try run.line(rule.file, source, offset);
                        shown += 1;
                    }
                }
                if (shown != 0) break;
            }
            if (shown == 0) try run.err.writeAll("    (none)\n");
        }
        return error.RuleFailed;
    }

    fn line(run: *Run, file: []const u8, source: []const u8, offset: usize) !void {
        const end = std.mem.findScalarPos(u8, source, offset, '\n') orelse source.len;
        try run.err.print("    {s}:{d}: {s}\n", .{ file, lineOf(source, offset), std.mem.trim(u8, source[offset..end], " \t\r") });
    }

    fn fail(run: *Run, rule: Rule, comptime fmt: []const u8, args: anytype) error{ RuleFailed, WriteFailed } {
        run.err.print("error: rule '{s}' ({s}): " ++ fmt ++ "\n", .{ rule.name, rule.file } ++ args) catch return error.WriteFailed;
        return error.RuleFailed;
    }

    fn report(run: *Run, rule: Rule, what: []const u8, source: []const u8, offset: usize) !void {
        try run.out.print("{s:<9} {s}  {s}:{d}\n", .{ what, rule.name, rule.file, lineOf(source, offset) });
    }

    fn indented(run: *Run, rule: Rule, source: []const u8) ![]const u8 {
        const indent = indentAt(source, try anchorHits(run.arena, source, rule.anchor));
        var buffer: Io.Writer.Allocating = .init(run.arena);
        var it = std.mem.tokenizeScalar(u8, rule.insert, '\n');
        while (it.next()) |text| try buffer.writer.print("{s}{s}\n", .{ indent, text });
        return buffer.written();
    }

    fn read(run: *Run, file: []const u8) ![]u8 {
        const path = try std.fs.path.join(run.arena, &.{ run.root, file });
        return Io.Dir.cwd().readFileAlloc(run.io, path, run.arena, .limited(64 << 20));
    }

    fn write(run: *Run, file: []const u8, source: []const u8) !void {
        const path = try std.fs.path.join(run.arena, &.{ run.root, file });
        try Io.Dir.cwd().writeFile(run.io, .{ .sub_path = path, .data = source });
    }
};

fn insertionOffset(rule: Rule, hit: Hit) usize {
    return switch (rule.position) {
        .before => hit.start,
        .after => hit.end,
    };
}

/// The indentation is that of the first anchor line; an unresolved anchor indents nothing, and
/// `resolve` reports it right after.
fn indentAt(source: []const u8, hits: []const Hit) []const u8 {
    if (hits.len == 0) return "";
    const rest = source[hits[0].start..];
    return rest[0 .. std.mem.findNone(u8, rest, " \t") orelse 0];
}

fn lineOf(source: []const u8, offset: usize) usize {
    return 1 + std.mem.countScalar(u8, source[0..@min(offset, source.len)], '\n');
}

fn anchorWords(anchor: Anchor) []const []const u8 {
    return switch (anchor) {
        .text => |t| &.{longestWord(t)},
        .text_after => |a| &.{longestWord(a.line)},
        .decl => |name| &.{name},
        .fn_stmt => |a| switch (a.stmt) {
            .calls => |callee| &.{ callee, a.fn_name },
            else => &.{a.fn_name},
        },
        .container_field => |a| switch (a.field) {
            .named => |name| &.{ name, a.container },
            else => &.{a.container},
        },
        .init_field => |a| &.{ a.field, a.fn_name },
    };
}

fn longestWord(text: []const u8) []const u8 {
    var best: []const u8 = "";
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
        if (i - start > best.len) best = text[start..i];
        if (i == start) i += 1;
    }
    return best;
}

fn printAnchor(w: *Io.Writer, anchor: Anchor) !void {
    switch (anchor) {
        .text => |t| try w.print("text \"{s}\"", .{std.mem.trim(u8, t, "\n")}),
        .text_after => |a| try w.print("text \"{s}\" after \"{s}\"", .{ a.line, a.prev }),
        .decl => |name| try w.print("declaration {s}", .{name}),
        .fn_stmt => |a| switch (a.stmt) {
            .first, .last => try w.print("fn {s}, {t} statement", .{ a.fn_name, a.stmt }),
            .calls => |callee| try w.print("fn {s}, statement calling {s}", .{ a.fn_name, callee }),
        },
        .container_field => |a| switch (a.field) {
            .named => |name| try w.print("container '{s}', field {s}", .{ a.container, name }),
            else => try w.print("container '{s}', {t} field", .{ a.container, a.field }),
        },
        .init_field => |a| try w.print("fn {s}, initializer field .{s}", .{ a.fn_name, a.field }),
    }
}

fn anchorHits(arena: Allocator, source: []const u8, anchor: Anchor) ![]const Hit {
    return switch (anchor) {
        .text => |t| textHits(arena, source, t),
        .text_after => |a| textAfterHits(arena, source, a.prev, a.line),
        else => astHits(arena, source, anchor),
    };
}

fn splitLines(arena: Allocator, source: []const u8) ![]const Hit {
    var lines: std.ArrayList(Hit) = .empty;
    var start: usize = 0;
    while (start < source.len) {
        const end = if (std.mem.findScalarPos(u8, source, start, '\n')) |i| i + 1 else source.len;
        try lines.append(arena, .{ .start = start, .end = end });
        start = end;
    }
    return lines.items;
}

fn trimmed(source: []const u8, hit: Hit) []const u8 {
    return std.mem.trim(u8, source[hit.start..hit.end], " \t\r\n");
}

/// Consecutive whole lines equal to the lines of `pattern`, ignoring indentation.
fn textHits(arena: Allocator, source: []const u8, pattern: []const u8) ![]const Hit {
    const lines = try splitLines(arena, source);
    var wanted: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, pattern, '\n');
    while (it.next()) |text| try wanted.append(arena, std.mem.trim(u8, text, " \t\r"));
    var hits: std.ArrayList(Hit) = .empty;
    if (wanted.items.len == 0 or lines.len < wanted.items.len) return hits.items;
    for (0..lines.len - wanted.items.len + 1) |i| {
        for (wanted.items, 0..) |want, k| {
            if (!std.mem.eql(u8, trimmed(source, lines[i + k]), want)) break;
        } else try hits.append(arena, .{ .start = lines[i].start, .end = lines[i + wanted.items.len - 1].end });
    }
    return hits.items;
}

fn textAfterHits(arena: Allocator, source: []const u8, prev: []const u8, line: []const u8) ![]const Hit {
    const pair = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ prev, line });
    const hits = try arena.dupe(Hit, try textHits(arena, source, pair));
    for (hits) |*hit| hit.start = std.mem.findScalarPos(u8, source, hit.start, '\n').? + 1;
    return hits;
}

/// The whole lines covered by the tokens first..last.
fn tokenLines(tree: *const Ast, source: []const u8, first: Ast.TokenIndex, last: Ast.TokenIndex) Hit {
    const from = tree.tokenStart(first);
    const to = tree.tokenStart(last) + tree.tokenSlice(last).len;
    const start = if (std.mem.findScalarLast(u8, source[0..from], '\n')) |i| i + 1 else 0;
    const end = if (std.mem.findScalarPos(u8, source, to, '\n')) |i| i + 1 else source.len;
    return .{ .start = start, .end = end };
}

fn astHits(arena: Allocator, source: []const u8, anchor: Anchor) ![]const Hit {
    const owned = try arena.dupeSentinel(u8, source, 0);
    const tree = try arena.create(Ast);
    tree.* = try .parse(arena, owned, .{});
    if (tree.errors.len != 0) return &.{};
    var hits: std.ArrayList(Hit) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        switch (anchor) {
            .text, .text_after => unreachable,
            .decl => |name| try declHits(arena, tree, source, node, name, &hits),
            .fn_stmt => |a| try fnStmtHits(arena, tree, source, node, a, &hits),
            .init_field => |a| try initFieldHits(arena, tree, source, node, a, &hits),
            .container_field => |a| try containerFieldHits(arena, tree, source, node, a, &hits),
        }
    }
    return hits.items;
}

fn declHits(arena: Allocator, tree: *const Ast, source: []const u8, node: Ast.Node.Index, name: []const u8, hits: *std.ArrayList(Hit)) !void {
    const is_root_decl = std.mem.findScalar(Ast.Node.Index, tree.rootDecls(), node) != null;
    if (!is_root_decl) return;
    const found = if (tree.fullVarDecl(node)) |decl|
        std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), name)
    else
        fnNamed(tree, node, name) != null;
    if (found) try hits.append(arena, stmtLines(tree, source, node));
}

/// Offsets of calls `callee(` outside `hit`, not counting its own declaration.
fn otherCalls(arena: Allocator, source: []const u8, callee: []const u8, hit: Hit) ![]const usize {
    const owned = try arena.dupeSentinel(u8, source, 0);
    const tree = try arena.create(Ast);
    tree.* = try .parse(arena, owned, .{});
    var offsets: std.ArrayList(usize) = .empty;
    var token: Ast.TokenIndex = 1;
    while (token + 1 < tree.tokens.len) : (token += 1) {
        if (tree.tokenTag(token) != .identifier or tree.tokenTag(token + 1) != .l_paren) continue;
        if (tree.tokenTag(token - 1) == .keyword_fn or !std.mem.eql(u8, tree.tokenSlice(token), callee)) continue;
        const offset = tree.tokenStart(token);
        if (offset < hit.start or offset >= hit.end) try offsets.append(arena, offset);
    }
    return offsets.items;
}

fn fnNamed(tree: *const Ast, node: Ast.Node.Index, name: []const u8) ?struct { body: Ast.Node.Index } {
    if (tree.nodeTag(node) != .fn_decl) return null;
    const proto, const body = tree.nodeData(node).node_and_node;
    var buffer: [1]Ast.Node.Index = undefined;
    const full = tree.fullFnProto(&buffer, proto) orelse return null;
    const name_token = full.name_token orelse return null;
    if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) return null;
    return .{ .body = body };
}

fn fnStmtHits(arena: Allocator, tree: *const Ast, source: []const u8, node: Ast.Node.Index, a: anytype, hits: *std.ArrayList(Hit)) !void {
    const found = fnNamed(tree, node, a.fn_name) orelse return;
    var buffer: [2]Ast.Node.Index = undefined;
    const stmts = tree.blockStatements(&buffer, found.body) orelse return;
    if (stmts.len == 0) return;
    switch (a.stmt) {
        .first => try hits.append(arena, stmtLines(tree, source, stmts[0])),
        .last => try hits.append(arena, stmtLines(tree, source, stmts[stmts.len - 1])),
        .calls => |callee| for (stmts) |stmt| {
            var token = tree.firstToken(stmt);
            const last = tree.lastToken(stmt);
            while (token < last) : (token += 1) {
                if (tree.tokenTag(token) == .identifier and tree.tokenTag(token + 1) == .l_paren and
                    std.mem.eql(u8, tree.tokenSlice(token), callee))
                {
                    try hits.append(arena, stmtLines(tree, source, stmt));
                    break;
                }
            }
        },
    }
}

fn stmtLines(tree: *const Ast, source: []const u8, stmt: Ast.Node.Index) Hit {
    return tokenLines(tree, source, tree.firstToken(stmt), tree.lastToken(stmt));
}

fn initFieldHits(arena: Allocator, tree: *const Ast, source: []const u8, node: Ast.Node.Index, a: anytype, hits: *std.ArrayList(Hit)) !void {
    const found = fnNamed(tree, node, a.fn_name) orelse return;
    const first = tree.firstToken(found.body);
    const last = tree.lastToken(found.body);
    for (0..tree.nodes.len) |i| {
        const inner: Ast.Node.Index = @enumFromInt(i);
        var buffer: [2]Ast.Node.Index = undefined;
        const init = tree.fullStructInit(&buffer, inner) orelse continue;
        for (init.ast.fields) |value| {
            const value_first = tree.firstToken(value);
            if (value_first < first + 3 or tree.lastToken(value) > last) continue;
            if (tree.tokenTag(value_first - 1) != .equal) continue;
            if (!std.mem.eql(u8, tree.tokenSlice(value_first - 2), a.field)) continue;
            try hits.append(arena, tokenLines(tree, source, value_first - 3, tree.lastToken(value)));
        }
    }
}

fn containerFieldHits(arena: Allocator, tree: *const Ast, source: []const u8, node: Ast.Node.Index, a: anytype, hits: *std.ArrayList(Hit)) !void {
    var buffer: [2]Ast.Node.Index = undefined;
    const members: []const Ast.Node.Index = if (a.container.len == 0) blk: {
        if (@intFromEnum(node) != 0) return;
        break :blk tree.rootDecls();
    } else blk: {
        const decl = tree.fullVarDecl(node) orelse return;
        if (!std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), a.container)) return;
        const init = decl.ast.init_node.unwrap() orelse return;
        const container = tree.fullContainerDecl(&buffer, init) orelse return;
        break :blk container.ast.members;
    };
    var fields: std.ArrayList(Ast.Node.Index) = .empty;
    for (members) |member| if (tree.fullContainerField(member) != null) try fields.append(arena, member);
    if (fields.items.len == 0) return;
    switch (a.field) {
        .first => try hits.append(arena, stmtLines(tree, source, fields.items[0])),
        .last => try hits.append(arena, stmtLines(tree, source, fields.items[fields.items.len - 1])),
        .named => |name| for (fields.items) |field| {
            const full = tree.fullContainerField(field).?;
            if (std.mem.eql(u8, tree.tokenSlice(full.ast.main_token), name)) try hits.append(arena, stmtLines(tree, source, field));
        },
    }
}
