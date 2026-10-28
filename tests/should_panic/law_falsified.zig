// A stateful law over a script of operations fails. The failure output must
// contain a ready-to-paste `pinned` entry and the replay call.
const std = @import("std");
const zv = @import("zv");

const Op = struct { kind: enum { push, pop }, weight: u8 };
const Cap = zv.Ranged(1, 8);

/// A bounded counter with a planted bug: a heavy push at capacity - 1 overshoots.
fn run(ops: [12]Op, cap: Cap) u32 {
    var len: u32 = 0;
    for (ops) |op| switch (op.kind) {
        .push => {
            const room = cap.get() - len;
            if (len < cap.get() or (room == 0 and op.weight > 200)) len += 1; // BUG: `or` clause
        },
        .pop => len -|= 1,
    };
    return len;
}

const laws = struct {
    pub fn neverExceedsCapacity(ops: [12]Op, cap: Cap, tag: ?u8) bool {
        _ = tag;
        return run(ops, cap) <= cap.get();
    }
};

pub fn main() !void {
    try zv.checkLaws(laws, .{ .iterations = 20_000, .seed = 11 });
    std.debug.print("unexpected: the law held\n", .{});
}
