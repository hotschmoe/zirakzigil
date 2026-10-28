//! Generational handles over storage the caller owns.
//!
//! `zv.Pool` owns comptime-capacity storage and panics on a stale handle: right
//! for application code, where a stale handle is a bug. A library that lends
//! out handles (a socket set, a DNS query table) has the opposite contract.
//! Its slots are a slice the *caller* provides, its capacity is a runtime
//! value, and a stale handle is an ordinary outcome the caller may hit after a
//! timeout or a cancel, so it must come back as an error:
//!
//!     const Queries = zv.Slots(QueryState, struct {});   // brand: unique per set
//!     var storage: [4]Queries.Slot = @splat(.empty);
//!     var queries: Queries = .init(&storage);
//!
//!     const h = try queries.insert(.pending);            // error.NoFreeSlot when full
//!     const state = try queries.get(h);                  // error.StaleHandle after free/take
//!
//! `Brand` is any unique type (`struct {}` at the declaration site). Handles
//! of different brands are different types, so passing a handle to the wrong
//! set is a compile error. Two sets of the *same* brand (two instances of one
//! socket type) are told apart only by generation, as in any generational
//! scheme.
//!
//! A slot's generation counts how often it has been filled, starting at 0 for
//! never used, so a zeroed `Handle` is never live. After 2^32 refills of one
//! slot a very old handle could alias a new one (ABA); that is the same bound
//! `zv.Pool` has.

const std = @import("std");
const manifest = @import("manifest.zig");

/// A reference to one slot of a `Slots(T, Brand)`. Plain data: copy it, store
/// it, send it. It carries no pointer, so it cannot dangle; whether it is still
/// valid is decided by `Slots.get` at the moment of use.
pub fn Handle(comptime Brand: type) type {
    return struct {
        index: u32,
        generation: u32,

        const Self = @This();
        pub const brand = Brand;

        pub const assurance = .{ .eql = .tested };
        comptime {
            manifest.requireAssurance(Self, .tested);
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.index == b.index and a.generation == b.generation;
        }
    };
}

/// A set of `T` values stored in a caller-provided `[]Slot`. No allocation.
/// `insert` scans for a free slot, so it is O(slots); that suits the small,
/// fixed tables (sockets, queries) this exists for.
pub fn Slots(comptime T: type, comptime Brand: type) type {
    const H = Handle(Brand);
    return struct {
        slots: []Slot,

        const Self = @This();
        pub const brand = Brand;
        pub const Handle = H;

        /// The storage unit callers declare: `var storage: [8]Set.Slot = @splat(.empty);`.
        pub const Slot = struct {
            value: ?T = null,
            generation: u32 = 0,

            pub const empty: Slot = .{};
        };

        pub const Entry = struct { handle: H, value: *T };

        pub const Iterator = struct {
            slots: []Slot,
            at: usize = 0,

            pub const assurance = .{ .next = .tested };
            comptime {
                manifest.requireAssurance(Iterator, .tested);
            }

            /// Live entries in slot order. Do not insert or free while iterating
            /// through a stale `Iterator`; free the current entry through its handle.
            pub fn next(it: *Iterator) ?Entry {
                while (it.at < it.slots.len) {
                    const slot = &it.slots[it.at];
                    const index = it.at;
                    it.at += 1;
                    if (slot.value) |*value| return .{
                        .handle = .{ .index = @intCast(index), .generation = slot.generation },
                        .value = value,
                    };
                }
                return null;
            }
        };

        pub const assurance = .{
            .init = .tested,
            .insert = .tested,
            .get = .tested,
            .isLive = .tested,
            .take = .tested,
            .free = .tested,
            .count = .tested,
            .iterator = .tested,
        };
        comptime {
            manifest.requireAssurance(Self, .tested);
        }

        /// Borrow `storage`. Every slot is freed; generations are kept, so
        /// handles issued before the call stay stale.
        pub fn init(storage: []Slot) Self {
            std.debug.assert(storage.len <= std.math.maxInt(u32));
            for (storage) |*slot| slot.value = null;
            return .{ .slots = storage };
        }

        /// Store `value` in the first free slot.
        pub fn insert(self: *Self, value: T) error{NoFreeSlot}!H {
            for (self.slots, 0..) |*slot, index| {
                if (slot.value != null) continue;
                slot.generation +%= 1;
                slot.value = value;
                return .{ .index = @intCast(index), .generation = slot.generation };
            }
            return error.NoFreeSlot;
        }

        fn live(self: *const Self, handle: H) ?*Slot {
            if (handle.index >= self.slots.len) return null;
            const slot = &self.slots[handle.index];
            if (slot.generation != handle.generation or slot.value == null) return null;
            return slot;
        }

        /// The value behind `handle`, mutable in place, valid until the next
        /// `insert`, `take` or `free`.
        pub fn get(self: *Self, handle: H) error{StaleHandle}!*T {
            const slot = self.live(handle) orelse return error.StaleHandle;
            return &slot.value.?;
        }

        pub fn isLive(self: *const Self, handle: H) bool {
            return self.live(handle) != null;
        }

        /// Move the value out and free the slot.
        pub fn take(self: *Self, handle: H) error{StaleHandle}!T {
            const slot = self.live(handle) orelse return error.StaleHandle;
            defer slot.value = null;
            return slot.value.?;
        }

        /// Free the slot. `error.StaleHandle` if it was already freed: callers
        /// that treat a double cancel as harmless write `self.set.free(h) catch {}`.
        pub fn free(self: *Self, handle: H) error{StaleHandle}!void {
            const slot = self.live(handle) orelse return error.StaleHandle;
            slot.value = null;
        }

        /// Number of live values.
        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots) |slot| n += @intFromBool(slot.value != null);
            return n;
        }

        pub fn iterator(self: *Self) Iterator {
            return .{ .slots = self.slots };
        }
    };
}

pub const assurance = .{
    .Handle = manifest.governed(Handle(struct {})),
    .Slots = manifest.governed(Slots(u8, struct {})),
};

comptime {
    manifest.requireAssurance(@This(), .tested);
}

// ── tests ────────────────────────────────────────────────────────────────────

const zv = @import("zv.zig");

const Set = Slots(u32, struct {});

/// The specification: whatever sequence of operations runs, a handle resolves
/// exactly when a reference model says its value is still live, and with that
/// value. Covers reuse of freed slots (stale handles), forged and out-of-range
/// handles, a full set, and re-initialization over used storage.
const laws = struct {
    const capacity = 3;
    const Op = struct {
        kind: enum { insert, get, free, take, forge, reinit },
        which: zv.Ranged(0, 7),
        value: u8,
    };

    pub fn handlesResolveExactlyWhenLive(ops: [24]Op) bool {
        var storage: [capacity]Set.Slot = @splat(.empty);
        var set: Set = .init(&storage);

        // Every handle ever issued, in order, with the value it was issued for.
        var issued: [24]Set.Handle = undefined;
        var values: [24]u8 = undefined;
        var live: [24]bool = @splat(false);
        var n: usize = 0;
        var live_count: usize = 0;

        for (ops) |op| {
            const k = if (n == 0) 0 else op.which.get() % n;
            switch (op.kind) {
                .insert => if (set.insert(op.value)) |h| {
                    if (live_count == capacity) return false;
                    issued[n] = h;
                    values[n] = op.value;
                    live[n] = true;
                    n += 1;
                    live_count += 1;
                } else |_| {
                    if (live_count != capacity) return false;
                },
                .get => if (n > 0) {
                    if (set.get(issued[k])) |got| {
                        if (!live[k] or got.* != values[k]) return false;
                    } else |_| if (live[k]) return false;
                },
                .free => if (n > 0) {
                    if (set.free(issued[k])) {
                        if (!live[k]) return false;
                        live[k] = false;
                        live_count -= 1;
                    } else |_| if (live[k]) return false;
                },
                .take => if (n > 0) {
                    if (set.take(issued[k])) |v| {
                        if (!live[k] or v != values[k]) return false;
                        live[k] = false;
                        live_count -= 1;
                    } else |_| if (live[k]) return false;
                },
                .forge => {
                    const forged: Set.Handle = .{ .index = op.which.get(), .generation = op.value % 8 };
                    var expected = false;
                    for (issued[0..n], live[0..n]) |h, is_live| expected = expected or (is_live and h.eql(forged));
                    if (set.isLive(forged) != expected) return false;
                },
                .reinit => {
                    set = .init(&storage);
                    live = @splat(false);
                    live_count = 0;
                },
            }
            if (set.count() != live_count) return false;
        }
        return true;
    }

    /// Iteration visits exactly the live entries, and each yielded handle resolves.
    pub fn iteratorVisitsLiveEntries(frees: [4]bool, values: [4]u8) bool {
        var storage: [4]Set.Slot = @splat(.empty);
        var set: Set = .init(&storage);
        var handles: [4]Set.Handle = undefined;
        for (&handles, values) |*h, v| h.* = set.insert(v) catch return false;
        var expected: usize = 0;
        for (handles, frees) |h, f| {
            if (f) set.free(h) catch return false else expected += 1;
        }
        var seen: usize = 0;
        var it = set.iterator();
        while (it.next()) |entry| {
            const got = set.get(entry.handle) catch return false;
            if (got != entry.value) return false;
            seen += 1;
        }
        return seen == expected and set.count() == expected;
    }
};

test "laws: Slots agrees with a reference model" {
    try zv.checkLaws(laws, .{ .iterations = 5_000, .seed = 0x510_75 });
}

test "handles of different brands are different types" {
    const Other = Slots(u32, struct {});
    comptime std.debug.assert(Set.Handle != Other.Handle);
    comptime std.debug.assert(Handle(Set.brand) == Set.Handle);
}
