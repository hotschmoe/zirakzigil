const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zir_walk = b.addExecutable(.{
        .name = "zir_walk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zir_walk.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run = b.addRunArtifact(zir_walk);
    run.addFileArg(b.path("../../corpus/corpus.zig"));
    const run_step = b.step("zir", "Walk corpus ZIR with a stock compiler");
    run_step.dependOn(&run.step);
}
