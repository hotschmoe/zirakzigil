//! What a stock compiler's standard library can see of a Zig file: AST + ZIR.
//! ZIR is untyped and not comptime-resolved. A generic is one declaration,
//! not one instruction stream per instantiation. Overflow intent is a tag
//! (`add` vs `add_unsafe` vs `addwrap` vs `add_sat`); the safety check itself
//! is chosen later, in Sema, and types are not on the instructions.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingPath;

    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        init.io,
        path,
        arena,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    );

    const tree = if (@import("builtin").zig_version.minor < 17)
        try std.zig.Ast.parse(arena, source, .zig)
    else
        try std.zig.Ast.parse(arena, source, .{});
    const zir = try std.zig.AstGen.generate(arena, tree);

    var tag_count: [std.enums.directEnumArrayLen(std.zig.Zir.Inst.Tag, 0)]u32 = @splat(0);
    for (zir.instructions.items(.tag)) |tag| tag_count[@intFromEnum(tag)] += 1;

    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const w = &stdout.interface;

    try w.print("compiler: {s}\n", .{@import("builtin").zig_version_string});
    try w.print("ast nodes: {d}\n", .{tree.nodes.len});
    try w.print("parse errors: {d}\n", .{tree.errors.len});
    try w.print("zir instructions: {d}\n", .{zir.instructions.len});
    try w.print("zir extra: {d}\n", .{zir.extra.len});
    try w.print("zir compile errors: {}\n", .{zir.hasCompileErrors()});
    try w.writeAll("declarations:\n");

    for (0..zir.instructions.len) |i| {
        if (zir.instructions.items(.tag)[i] != .declaration) continue;
        const decl = zir.getDeclaration(@enumFromInt(i));
        const name = zir.nullTerminatedString(decl.name);
        const body_len: usize = if (decl.value_body) |b| b.len else 0;
        try w.print("  {s} {s} line {d} value_body {d}\n", .{
            @tagName(decl.kind),
            name,
            decl.src_line + 1,
            body_len,
        });
    }

    try w.writeAll("zir tags with count > 0:\n");
    const tags = std.enums.values(std.zig.Zir.Inst.Tag);
    for (tags, 0..) |tag, i| {
        if (tag_count[i] == 0) continue;
        try w.print("  {d}\t{s}\n", .{ tag_count[i], @tagName(tag) });
    }
    try w.flush();
}
