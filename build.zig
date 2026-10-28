const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ghost = b.option(bool, "ghost", "Compile ghost (verification-only) code") orelse false;
    const opts = b.addOptions();
    opts.addOption(bool, "ghost", ghost);

    const zv = b.addModule("zv", .{
        .root_source_file = b.path("src/zv.zig"),
        .target = target,
        .optimize = optimize,
    });
    zv.addOptions("zv_options", opts);

    const test_step = b.step("test", "Run example tests with runtime contracts");
    for ([_][]const u8{ "examples/search.zig", "examples/ledger.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zv", .module = zv }},
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Programs that must PANIC at runtime (run by tools/run_negative.sh).
    const neg = b.step("negative", "Build should-panic programs");
    for ([_][]const u8{ "double_consume", "stale_handle", "pin_copy", "precondition" }) |name| {
        const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/should_panic/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zv", .module = zv },
                .{ .name = "ledger", .module = b.createModule(.{
                    .root_source_file = b.path("examples/ledger.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "zv", .module = zv }},
                }) },
            },
        }) });
        neg.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
}
