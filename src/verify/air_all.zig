//! Root for exporting what a file defines, also the functions no test of it reaches:
//!   ZV_AIR_OUT=DIR zig-zv test -fno-emit-bin --dep target --dep selection -Mroot=src/verify/air_all.zig -Mtarget=FILE.zig -Mselection=sel.zig
//! `selection` is `pub const items = .{ target.a.b, target.c };`: the containers whose functions to export
//! (tools/zvc_export.sh writes it). Taking the address of a function as a runtime value makes the compiler
//! analyze its body. Generic functions and type constructors have no body to analyze until they are
//! instantiated, so they are skipped.
const std = @import("std");
const selection = @import("selection");

test "analyze every pub fn of the selection" {
    inline for (selection.items) |item| analyze(item);
}

fn analyze(comptime item: anytype) void {
    switch (@typeInfo(@TypeOf(item))) {
        .type => switch (@typeInfo(item)) {
            inline .@"struct", .@"enum", .@"union", .@"opaque" => |info| inline for (info.decl_names) |name| analyzeDecl(@field(item, name)),
            else => {},
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
