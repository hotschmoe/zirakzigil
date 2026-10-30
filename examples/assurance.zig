//! `zig build assurance`: the Phase 0 gate for the examples. The walk starts at the root below,
//! so every module is covered; the build supplies the evidence from the examples' own tests.

const std = @import("std");
const zv = @import("zv");

const Examples = struct {
    pub const assurance = .{};
    pub const search = @import("search.zig");
    pub const ledger = @import("ledger.zig");
    pub const regress = @import("regress.zig");
    pub const queries = @import("queries.zig");
    pub const bump = @import("bump.zig");
    pub const pool = @import("pool.zig");
};

pub fn main(init: std.process.Init) !void {
    try zv.report.run(init, Examples, .tested);
}
