const std = @import("std");
const zv = @import("zv");

pub fn main(init: std.process.Init) !void {
    try zv.report.run(init, @import("gate_fail"), .trusted);
}
