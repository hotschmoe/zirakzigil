//! The consumer's evidence root: laws and scenarios the Phase 0 gate counts. The unit test
//! in ring_buffer.zig does not count; this law covers the same behavior.

const std = @import("std");
const zv = @import("zv");
const ring_buffer = @import("ring_buffer.zig");

pub const laws = struct {
    /// A ring accepts exactly as many items as its storage holds, then refuses.
    pub fn enqueueFillsThenRefuses(capacity: zv.Ranged(0, 8), extra: u3) bool {
        var backing: [8]u8 = undefined;
        const cap: usize = capacity.get();
        var ring: ring_buffer.ByteRing = .init(backing[0..cap]);
        for (0..cap) |i| ring.enqueue(@intCast(i)) catch return false;
        for (0..extra) |_| if (ring.enqueue(0)) |_| return false else |e| if (e != error.Full) return false;
        return ring.len() == cap and ring_buffer.capacityOf(u8, ring) == cap;
    }
};

test "laws hold" {
    try zv.checkLaws(laws, .{ .iterations = 1000, .seed = 3 });
}
