//! A bump allocator over a fixed region of bytes, specified with `zv.PointsTo` permission tokens
//! (docs/phase4.md). The core manages offsets; the bytes themselves stay with the caller, as in Verus, where
//! an allocator hands out addresses and a token says who may use them. `zvc` proves of every block it
//! hands out: in bounds, aligned, and disjoint from every other block that is live, and that `free` and
//! `reset` give back exactly what was taken. The methods take `*Bump`: the allocator changes in place, and so
//! does the token it holds (`spare`), which a method must leave in the struct when it returns.
//!
//! Positions, not lengths, are what the specification talks about (`end` of a block, not `off + len`): every
//! fact is then a comparison, and the proofs need no arithmetic beyond computing the positions once.
//!
//! `Arena` is the checked shell over a real buffer: it turns blocks into slices and keeps the permission
//! for everything handed out, so `reset` is always legal for its callers.

const std = @import("std");
const zv = @import("zv");

pub const assurance = .{
    .laws = .{ .blocks_hold = .tested, .pair_holds = .tested },
};

comptime {
    zv.requireAssurance(@This(), .tested);
}

pub const Block = struct {
    /// Where the allocator was before this block, where the bytes start (after the alignment padding) and where
    /// they end.
    base: usize,
    off: usize,
    end: usize,
    /// Ghost: the permission for `[base, end)`: the padding and the bytes.
    perm: zv.PointsTo,
};

pub const Two = struct { first: Block, second: Block };

pub const Bump = struct {
    cap: usize,
    /// Everything below `next` was handed out or skipped for alignment; everything from `next` on is free.
    next: usize,
    /// Ghost: the permission for the free bytes, `[next, cap)`.
    spare: zv.PointsTo,

    pub const assurance = .{ .init = .verified, .padTo = .verified, .carve = .verified, .alloc = .verified, .free = .verified, .reset = .verified, .pair = .verified };
    comptime {
        zv.requireAssurance(Bump, .tested);
    }

    inline fn sound(b: Bump) bool {
        return !zv.ghost or (b.next <= b.cap and b.spare.lo == b.next and b.spare.hi == b.cap);
    }

    inline fn owns(blk: Block) bool {
        return !zv.ghost or (blk.perm.lo == blk.base and blk.perm.hi == blk.end and blk.base <= blk.off and blk.off <= blk.end);
    }

    inline fn isPow2(n: usize) bool {
        return n != 0 and n & (n -% 1) == 0;
    }

    inline fn padFor(n: usize, alignment: usize) usize {
        return (0 -% n) & (alignment -% 1);
    }

    inline fn carved(old: Bump, off: usize, end: usize, now: Bump, blk: Block) bool {
        return sound(now) and owns(blk) and now.cap == old.cap and now.next == end and
            blk.base == old.next and blk.off == off and blk.end == end;
    }

    inline fn granted(old: Bump, len: usize, alignment: usize, now: Bump, blk: Block) bool {
        return sound(now) and owns(blk) and now.cap == old.cap and now.next == blk.end and
            blk.base == old.next and blk.off +% len == blk.end and blk.off & (alignment -% 1) == 0;
    }

    /// A request is refused only when it does not fit with the padding it needs, and nothing changes.
    inline fn refused(old: Bump, len: usize, alignment: usize, now: Bump) bool {
        const room = old.cap -% old.next;
        const pad = padFor(old.next, alignment);
        return sound(now) and now.cap == old.cap and now.next == old.next and (pad > room or len > room -% pad);
    }

    inline fn together(old: Bump, n: usize, m: usize, alignment: usize, now: Bump, t: Two) bool {
        const x = t.first;
        const y = t.second;
        return sound(now) and owns(x) and owns(y) and now.cap == old.cap and now.next == y.end and
            x.base == old.next and x.off +% n == x.end and y.off +% m == y.end and
            x.off & (alignment -% 1) == 0 and y.off & (alignment -% 1) == 0 and
            x.end <= y.off and (!zv.ghost or x.perm.hi <= y.perm.lo);
    }

    inline fn unchanged(old: Bump, now: Bump) bool {
        return sound(now) and now.cap == old.cap and now.next == old.next;
    }

    pub fn init(region: []u8) Bump {
        const whole = if (zv.ghost) zv.PointsTo.own(region) else {};
        const b: Bump = .{ .cap = region.len, .next = 0, .spare = whole };
        return zv.ensures(b, b.cap == region.len and b.next == 0 and sound(b));
    }

    /// The bytes from `n` to the next multiple of `alignment`, which must be a power of two.
    pub fn padTo(n: usize, alignment: usize) usize {
        zv.requires(isPow2(alignment));
        const pad = (0 -% n) & (alignment - 1);
        return zv.ensures(pad, pad < alignment and (n +% pad) & (alignment -% 1) == 0);
    }

    /// The block `[off, end)`, with the padding before it from where the allocator was.
    pub fn carve(self: *Bump, off: usize, end: usize) Block {
        zv.requires(sound(self.*) and self.next <= off and off <= end and end <= self.cap);
        const old = self.*;
        const parts = if (zv.ghost) self.spare.split(end) else {};
        self.next = end;
        self.spare = if (zv.ghost) parts.tail else {};
        const blk: Block = .{ .base = old.next, .off = off, .end = end, .perm = if (zv.ghost) parts.head else {} };
        return zv.ensures(blk, carved(old, off, end, self.*, blk));
    }

    /// A block of `len` bytes at a multiple of `alignment`, which must be a power of two.
    pub fn alloc(self: *Bump, len: usize, alignment: usize) ?Block {
        zv.requires(sound(self.*) and isPow2(alignment));
        const old = self.*;
        const pad = padTo(self.next, alignment);
        const room = self.cap - self.next;
        if (pad <= room and len <= room - pad) {
            const off = self.next + pad;
            const blk = self.carve(off, off + len);
            const got: ?Block = blk;
            return zv.ensures(got, granted(old, len, alignment, self.*, blk));
        }
        const none: ?Block = null;
        return zv.ensures(none, refused(old, len, alignment, self.*));
    }

    /// Takes back the block that was handed out last, padding included.
    pub fn free(self: *Bump, blk: Block) void {
        zv.requires(sound(self.*) and owns(blk) and blk.end == self.next);
        self.spare = if (zv.ghost) blk.perm.join(self.spare) else {};
        self.next = blk.base;
        return zv.ensures({}, sound(self.*) and self.next == blk.base);
    }

    /// Takes back every block at once. `used` is the permission for all of them, joined: `[0, next)`, which is
    /// the proof that nobody holds one any more.
    pub fn reset(self: *Bump, used: zv.PointsTo) void {
        zv.requires(sound(self.*));
        zv.requires(!zv.ghost or (used.lo == 0 and used.hi == self.next));
        self.spare = if (zv.ghost) used.join(self.spare) else {};
        self.next = 0;
        return zv.ensures({}, sound(self.*) and self.next == 0);
    }

    /// Two allocations in a row: a caller that knows `alloc` only through its contract still gets blocks that
    /// do not overlap, and a failure of the second leaves the allocator as it was.
    pub fn pair(self: *Bump, n: usize, m: usize, alignment: usize) ?Two {
        zv.requires(sound(self.*) and isPow2(alignment));
        const old = self.*;
        const none: ?Two = null;
        const x = self.alloc(n, alignment) orelse return zv.ensures(none, unchanged(old, self.*));
        const y = self.alloc(m, alignment) orelse {
            self.free(x);
            return zv.ensures(none, unchanged(old, self.*));
        };
        const t: Two = .{ .first = x, .second = y };
        const got: ?Two = t;
        return zv.ensures(got, together(old, n, m, alignment, self.*, t));
    }
};

/// The shell over bytes: blocks become slices, and the permissions of everything handed out stay in `used`.
pub const Arena = struct {
    region: []align(base_alignment) u8,
    bump: Bump,
    used: zv.PointsTo,

    pub const assurance = .{ .init = .checked, .alloc = .checked, .reset = .checked };
    comptime {
        zv.requireAssurance(Arena, .tested);
    }

    /// The strictest alignment `alloc` accepts; `region` is aligned to it.
    pub const base_alignment = 64;

    pub fn init(region: []align(base_alignment) u8) Arena {
        var bump = Bump.init(region);
        const parts = if (zv.ghost) bump.spare.split(0) else {};
        bump.spare = if (zv.ghost) parts.tail else {};
        return .{ .region = region, .bump = bump, .used = if (zv.ghost) parts.head else {} };
    }

    pub fn alloc(self: *Arena, comptime alignment: usize, len: usize) ?[]align(alignment) u8 {
        comptime std.debug.assert(alignment <= base_alignment);
        const blk = self.bump.alloc(len, alignment) orelse return null;
        if (zv.ghost) self.used = self.used.join(blk.perm);
        return @alignCast(self.region[blk.off..blk.end]);
    }

    pub fn reset(self: *Arena) void {
        self.bump.reset(self.used);
        const parts = if (zv.ghost) self.bump.spare.split(0) else {};
        self.bump.spare = if (zv.ghost) parts.tail else {};
        self.used = if (zv.ghost) parts.head else {};
    }
};

/// LAWS: the allocator behaves like its specification on any sequence of requests.
pub const laws = struct {
    /// Blocks stay inside the region, aligned in memory, disjoint, and keep their bytes, through any
    /// mix of allocations and resets; every request that fits with its worst padding is served.
    pub fn blocks_hold(ops: [24]u8, sizes: [24]u8) bool {
        var region: [256]u8 align(Arena.base_alignment) = undefined;
        var arena = Arena.init(&region);
        var live: [24]struct { off: usize, len: usize, id: u8 } = undefined;
        var n: usize = 0;
        for (ops, sizes, 0..) |op, size, step| {
            if (op % 8 == 0) {
                arena.reset();
                n = 0;
            } else {
                const len: usize = size % 70;
                const got = switch (op % 4) {
                    0 => allocAt(&arena, 1, len),
                    1 => allocAt(&arena, 8, len),
                    2 => allocAt(&arena, 16, len),
                    else => allocAt(&arena, 64, len),
                };
                const slice = got orelse {
                    if (len + 63 <= arena.region.len - arena.bump.next) return false;
                    continue;
                };
                const off = @intFromPtr(slice.ptr) - @intFromPtr(&region);
                if (off + slice.len > region.len) return false;
                const id: u8 = @intCast(step + 1);
                @memset(slice, id);
                live[n] = .{ .off = off, .len = slice.len, .id = id };
                n += 1;
            }
            for (live[0..n], 0..) |a, i| {
                for (region[a.off..][0..a.len]) |byte| if (byte != a.id) return false;
                for (live[i + 1 .. n]) |b| if (a.off + a.len > b.off and b.off + b.len > a.off) return false;
            }
        }
        return true;
    }

    fn allocAt(arena: *Arena, comptime alignment: usize, len: usize) ?[]u8 {
        const slice = arena.alloc(alignment, len) orelse return null;
        if (@intFromPtr(slice.ptr) % alignment != 0) @panic("misaligned block");
        return slice;
    }

    /// Two allocations never overlap, whatever the sizes and alignments; a second that does not fit leaves
    /// the region untouched, and `free` of the first gives back exactly what it took.
    pub fn pair_holds(n: u8, m: u8, shift: u3) bool {
        var region: [128]u8 align(Arena.base_alignment) = undefined;
        var bump = Bump.init(&region);
        const t = bump.pair(n % 80, m % 80, @as(usize, 1) << shift) orelse return bump.next == 0;
        return t.first.end <= t.second.off and t.second.end <= region.len and bump.next == t.second.end;
    }
};

test "laws hold on random request sequences" {
    try zv.checkLaws(laws, .{ .iterations = 4_000, .seed = 0xB0B });
}

test "an arena refuses what does not fit and serves again after reset" {
    var region: [64]u8 align(Arena.base_alignment) = undefined;
    var arena = Arena.init(&region);
    const a = arena.alloc(16, 40).?;
    try std.testing.expectEqual(@as(usize, 40), a.len);
    try std.testing.expect(arena.alloc(16, 40) == null);
    const b = arena.alloc(8, 24).?;
    try std.testing.expectEqual(@as(usize, 24), b.len);
    arena.reset();
    try std.testing.expect(arena.alloc(64, 64) != null);
}

test "the core alone: pair gives disjoint blocks and undoes a failed second request" {
    var region: [32]u8 align(Arena.base_alignment) = undefined;
    var bump = Bump.init(&region);
    const t = bump.pair(10, 12, 4).?;
    try std.testing.expect(t.first.end <= t.second.off and t.second.off % 4 == 0);
    var other = Bump.init(&region);
    try std.testing.expect(other.pair(10, 30, 4) == null and other.next == 0);
}

test "tokens cost nothing outside ghost builds" {
    try std.testing.expectEqual(@as(usize, if (zv.ghost) 4 * @sizeOf(usize) else 2 * @sizeOf(usize)), @sizeOf(Bump));
}
