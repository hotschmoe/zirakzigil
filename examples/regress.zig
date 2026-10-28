//! The regression workflow, end to end. `neverExceedsCapacity` once failed;
//! `zv.checkLaws` printed the entry now living in `pinned`, verbatim. The bug
//! is fixed (see the comment in `push`), and the case stays in the suite: it
//! is replayed before any random case, whatever the generators do later.
//! `tests/should_panic/law_falsified.zig` is the buggy version.

const zv = @import("zv");

pub const assurance = .{
    .run = .tested,
    .laws = .{ .neverExceedsCapacity = .tested },
};

comptime {
    zv.requireAssurance(@This(), .tested);
}

pub const Op = struct { kind: enum { push, pop }, weight: u8 };
pub const Cap = zv.Ranged(1, 8);

/// A bounded counter. A heavy push at capacity used to overshoot because
/// `push` read `len < cap or (room == 0 and weight > 200)`.
pub fn run(ops: [12]Op, cap: Cap) u32 {
    var len: u32 = 0;
    for (ops) |op| switch (op.kind) {
        .push => if (len < cap.get()) {
            len += 1;
        },
        .pop => len -|= 1,
    };
    return len;
}

pub const laws = struct {
    pub fn neverExceedsCapacity(ops: [12]Op, cap: Cap, tag: ?u8) bool {
        _ = tag;
        return run(ops, cap) <= cap.get();
    }

    /// Regressions: exact argument tuples, replayed first on every run.
    pub const pinned = .{
        .neverExceedsCapacity = .{
            .{
                .{
                    .{ .kind = .pop, .weight = 0 },
                    .{ .kind = .push, .weight = 255 },
                    .{ .kind = .pop, .weight = 0 },
                    .{ .kind = .pop, .weight = 9 },
                    .{ .kind = .pop, .weight = 0 },
                    .{ .kind = .push, .weight = 50 },
                    .{ .kind = .pop, .weight = 0 },
                    .{ .kind = .pop, .weight = 133 },
                    .{ .kind = .push, .weight = 255 },
                    .{ .kind = .push, .weight = 1 },
                    .{ .kind = .push, .weight = 94 },
                    .{ .kind = .push, .weight = 249 },
                },
                2,
                1,
            },
        },
    };
};

test "pinned regressions are replayed, then random cases" {
    try zv.checkLaws(laws, .{ .iterations = 0 }); // pinned only
    try zv.checkLaws(laws, .{ .iterations = 2_000, .seed = 3 });
}

test "the same laws under the fuzzer, seeded with the pinned case" {
    try zv.fuzzLaws(laws, &.{});
}
