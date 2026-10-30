//! Proved arithmetic: `zig build verify` proves these from their AIR.

const std = @import("std");
const zv = @import("zv");

pub const assurance = .{
    .midpoint = .verified,
    .lowerBound = .verified,
    .clampedAdd = .verified,
    .laws = .{ .midpointBetween = .tested, .lowerBoundSplits = .tested, .clampedAddCaps = .tested },
};

comptime {
    zv.requireAssurance(@This(), .tested);
}

/// Overflow-free midpoint: `lo + hi` would overflow.
pub fn midpoint(lo: u32, hi: u32) u32 {
    zv.requires(lo <= hi);
    const mid = lo + (hi - lo) / 2;
    return zv.ensures(mid, lo <= mid and mid <= hi);
}

/// First index whose element is >= key.
pub fn lowerBound(xs: []const u32, key: u32) usize {
    var lo: usize = 0;
    var hi: usize = xs.len;
    while (lo < hi) {
        zv.invariant(lo <= hi and hi <= xs.len);
        const mid = lo + (hi - lo) / 2;
        if (xs[mid] < key) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return zv.ensures(lo, lo <= xs.len);
}

/// Saturating add with a cap.
pub fn clampedAdd(a: u32, b: u32, cap: u32) u32 {
    var r: u32 = cap;
    if (a <= cap) {
        if (b <= cap - a) {
            r = a + b;
        }
    }
    return zv.ensures(r, r <= cap);
}

pub const laws = struct {
    pub fn midpointBetween(lo: u32, hi: u32) bool {
        if (lo > hi) return true;
        const mid = midpoint(lo, hi);
        return lo <= mid and mid <= hi;
    }

    pub fn clampedAddCaps(a: u32, b: u32, cap: u32) bool {
        return clampedAdd(a, b, cap) <= cap;
    }

    pub fn lowerBoundSplits(key: u32) bool {
        const xs = [_]u32{ 1, 3, 3, 7, 9 };
        const at = lowerBound(&xs, key);
        return (at == 0 or xs[at - 1] < key) and (at == xs.len or xs[at] >= key);
    }
};

test "laws hold" {
    try zv.checkLaws(laws, .{ .iterations = 500, .seed = 3 });
    try std.testing.expectEqual(@as(u32, 100), clampedAdd(90, 20, 100));
}
