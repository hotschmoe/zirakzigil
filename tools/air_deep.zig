//! Root for exporting a whole project: every pub function reachable through the pub declarations of the
//! selection, nested containers and imported files included (`tools/air_all.zig` stops at the first level):
//!   ZVC_DEEP=1 tools/zvc_export.sh OUT FILE.zig
//! Generic functions and type constructors have no body to analyze until they are instantiated, so they are
//! skipped; what instantiates them is reached through the functions that use them. A container is not entered
//! again below itself, so aliases that point back up cannot loop.
const std = @import("std");
const selection = @import("selection");

test "analyze every pub fn below the selection" {
    inline for (selection.items) |item| visit(item, &.{});
}

fn visit(comptime item: anytype, comptime path: []const type) void {
    switch (@typeInfo(@TypeOf(item))) {
        .type => {
            inline for (path) |ancestor| if (ancestor == item) return;
            const below = path ++ &[_]type{item};
            switch (@typeInfo(item)) {
                inline .@"struct", .@"enum", .@"union", .@"opaque" => |info| inline for (info.decl_names) |name| {
                    const decl = @field(item, name);
                    if (@TypeOf(decl) == type) visit(decl, below) else analyzeDecl(decl);
                },
                else => {},
            }
        },
        else => analyzeDecl(item),
    }
}

fn analyzeDecl(comptime value: anytype) void {
    const T = @TypeOf(value);
    if (@typeInfo(T) != .@"fn") return;
    const info = @typeInfo(T).@"fn";
    if (info.is_generic or info.return_type == null or info.return_type.? == type) return;
    std.mem.doNotOptimizeAway(&value);
}
