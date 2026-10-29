const zv = @import("zv");

pub const assurance = .{ .exercised = .tested, .forgotten = .tested, .vouched = .trusted };

comptime {
    zv.requireAssurance(@This(), .trusted);
}

pub fn exercised(x: u8) u8 {
    return x +| 1;
}

/// Claimed `.tested`, but no law or scenario calls it.
pub fn forgotten(x: u8) u8 {
    return x -| 1;
}

/// A code owner vouches for it; no evidence is required.
pub fn vouched() void {}

// Unit tests are not evidence: this one runs `forgotten`, and the gate must still reject it.
test "a unit test cannot vouch" {
    _ = forgotten(1);
}
