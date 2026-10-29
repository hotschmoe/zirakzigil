const std = @import("std");

pub fn build(b: *std.Build) void {
    const obj = b.addObject(.{
        .name = "answer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("answer.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = .Debug,
        }),
    });
    b.getInstallStep().dependOn(&obj.step);
}
