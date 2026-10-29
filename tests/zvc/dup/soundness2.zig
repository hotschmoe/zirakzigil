//! A file named like tests/zvc/soundness2.zig with a different `lenBound`. A call of `lenBound` with both packs in one run
//! is not proved: it could not tell the two functions apart. Not pinned: it only has to differ.

const zv = @import("zv");

pub const assurance = .{
    .lenBound = .verified,
};

pub fn lenBound(xs: []const u8) bool {
    const ok = xs.len <= (@as(usize, 1) << 63);
    return zv.ensures(ok, ok);
}
