//! A library whose manifest claims more than its laws execute. `zig build assurance` must fail,
//! and the failure must name the function (checked by the parent build's `gate` step).

const std = @import("std");
const zirakzigil = @import("zirakzigil");

pub fn build(b: *std.Build) void {
    const zv = b.dependency("zirakzigil", .{}).module("zv");
    const lib = b.addModule("gate_fail", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{.{ .name = "zv", .module = zv }},
    });
    const report = b.addExecutable(.{ .name = "assurance", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/assurance.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "zv", .module = zv },
            .{ .name = "gate_fail", .module = lib },
        },
    }) });
    _ = zirakzigil.addAssuranceGate(b, .{
        .report = report,
        .src = b.path("src"),
        .lib_name = "gate_fail",
        .laws = &.{"laws.zig"},
    });
}
