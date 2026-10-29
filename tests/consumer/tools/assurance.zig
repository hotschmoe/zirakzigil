//! `zig build assurance`: the Phase 0 gate. The walk starts at the library root, so a module
//! cannot dodge it by not being listed; the build supplies the evidence.

const std = @import("std");
const zv = @import("zv");

pub fn main(init: std.process.Init) !void {
    try zv.report.run(init, @import("consumer"), .tested);
}
