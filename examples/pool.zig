//! A pool of fixed-size blocks over a fixed region of bytes, specified with `zv.BlockSet` permission tokens
//! (docs/phase4.md). `alloc` hands out the lowest free block, `free` takes one back in any order. `zvc` proves of
//! every block: in bounds, aligned to the block size, disjoint from every other live block, and that a block is
//! never handed out twice and never freed twice (the second `free` of a token that was consumed is refuted at the
//! caller). A block of another pool is refused: its token names another pool.
//!
//! The free set is a bitmap, `free`, and its ghost twin is the token `spare`; an intrusive free list (a next link
//! inside every free block) is what phase4.md says is still missing in `zvc`.
//!
//! `Heap` is the checked shell over a real buffer: blocks become pointers, and the permissions of everything handed
//! out stay in `held`.

const std = @import("std");
const zv = @import("zv");

pub const assurance = .{
    .laws = .{ .blocks_hold = .tested, .pair_holds = .tested },
};

comptime {
    zv.requireAssurance(@This(), .tested);
}

/// Every block is `1 << block_shift` bytes, and a pool has at most `max_blocks` of them.
pub const block_shift = 6;
pub const block_size = 1 << block_shift;
pub const max_blocks = 64;

pub const Block = struct {
    idx: u32,
    /// Where the bytes start: `idx * block_size`.
    off: usize,
    /// The permission for this block alone.
    perm: zv.BlockSet,
};

pub const Two = struct { first: Block, second: Block };

pub const Pool = struct {
    /// The size of the region, and the number of blocks in it (`count * block_size <= cap`, `count <= max_blocks`).
    cap: usize,
    count: u32,
    /// The bits of the blocks that exist.
    all: u64,
    /// Bit `i` is set when block `i` is free.
    free_bits: u64,
    /// The permission for the free blocks.
    spare: zv.BlockSet,

    pub const assurance = .{ .init = .verified, .alloc = .verified, .free = .verified, .pair = .verified };
    comptime {
        zv.requireAssurance(Pool, .tested);
    }

    inline fn sound(p: Pool) bool {
        return p.count <= max_blocks and p.all & (p.all +% 1) == 0 and @as(u32, @popCount(p.all)) == p.count and p.free_bits & ~p.all == 0 and
            @as(usize, p.count) <= p.cap >> block_shift and
            p.spare.mask() == p.free_bits;
    }

    inline fn owns(p: Pool, blk: Block) bool {
        return blk.idx < p.count and blk.off == @as(usize, blk.idx) << block_shift and
            blk.perm.id() == p.spare.id() and blk.perm.mask() == zv.BlockSet.bit(blk.idx);
    }

    inline fn granted(old: Pool, id: usize, now: Pool, blk: Block) bool {
        return sound(now) and owns(now, blk) and now.cap == old.cap and now.count == old.count and now.all == old.all and
            old.free_bits & zv.BlockSet.bit(blk.idx) != 0 and now.free_bits == old.free_bits & ~zv.BlockSet.bit(blk.idx) and
            blk.off + block_size <= old.cap and blk.off & (block_size - 1) == 0 and
            now.spare.id() == id;
    }

    inline fn unchanged(old: Pool, now: Pool) bool {
        return sound(now) and now.cap == old.cap and now.count == old.count and now.free_bits == old.free_bits;
    }

    /// Every block of the first `region.len / block_size` (at most 64) is free.
    pub fn init(region: []u8) Pool {
        const n: u32 = @intCast(@min(region.len >> block_shift, max_blocks));
        const all: u64 = if (n == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) -% 1;
        const p: Pool = .{ .cap = region.len, .count = n, .all = all, .free_bits = all, .spare = zv.BlockSet.own(all) };
        return zv.ensures(p, sound(p) and p.cap == region.len and p.free_bits == p.all);
    }

    /// The lowest free block, if there is one.
    pub fn alloc(self: *Pool) ?Block {
        zv.requires(sound(self.*));
        const old = self.*;
        const id = self.spare.id();
        if (self.free_bits == 0) return zv.ensures(null, unchanged(old, self.*) and old.free_bits == 0);
        const idx: u32 = @ctz(self.free_bits);
        const parts = self.spare.cut(zv.BlockSet.bit(idx));
        self.spare = parts.tail;
        self.free_bits &= ~zv.BlockSet.bit(idx);
        const blk: Block = .{ .idx = idx, .off = @as(usize, idx) << block_shift, .perm = parts.head };
        return zv.ensures(blk, granted(old, id, self.*, blk));
    }

    /// Takes a block back. The token is the proof that it was handed out and not given back yet.
    pub fn free(self: *Pool, blk: Block) void {
        zv.requires(sound(self.*) and owns(self.*, blk));
        const old = self.*;
        const lemma = zv.BlockSet.apart(self.spare, blk.perm);
        self.spare = zv.BlockSet.join(lemma.head, lemma.tail);
        self.free_bits |= zv.BlockSet.bit(blk.idx);
        zv.ensures({}, sound(self.*) and self.cap == old.cap and self.count == old.count and
            old.free_bits & zv.BlockSet.bit(blk.idx) == 0 and self.free_bits == old.free_bits | zv.BlockSet.bit(blk.idx));
    }

    inline fn together(old: Pool, now: Pool, t: Two) bool {
        const x = t.first;
        const y = t.second;
        return sound(now) and owns(now, x) and owns(now, y) and now.cap == old.cap and x.idx != y.idx and
            x.off + block_size <= old.cap and y.off + block_size <= old.cap and
            (x.off + block_size <= y.off or y.off + block_size <= x.off) and
            x.off & (block_size - 1) == 0 and y.off & (block_size - 1) == 0;
    }

    /// Two allocations: the blocks are different and do not overlap; if there is only one block to give, nothing
    /// changes.
    pub fn pair(self: *Pool) ?Two {
        zv.requires(sound(self.*));
        const old = self.*;
        const x = self.alloc() orelse return zv.ensures(null, unchanged(old, self.*));
        const y = self.alloc() orelse {
            self.free(x);
            return zv.ensures(null, unchanged(old, self.*));
        };
        const t: Two = .{ .first = x, .second = y };
        return zv.ensures(t, together(old, self.*, t));
    }
};

/// The shell over bytes: blocks become pointers, and the permissions of everything handed out stay in `held`.
pub const Heap = struct {
    region: []align(block_size) u8,
    pool: Pool,
    held: zv.BlockSet,

    pub const assurance = .{ .init = .checked, .alloc = .checked, .free = .checked };
    comptime {
        zv.requireAssurance(Heap, .tested);
    }

    pub fn init(region: []align(block_size) u8) Heap {
        var pool = Pool.init(region);
        const parts = pool.spare.cut(0);
        pool.spare = parts.tail;
        return .{ .region = region, .pool = pool, .held = parts.head };
    }

    pub fn alloc(self: *Heap) ?*align(block_size) [block_size]u8 {
        const blk = self.pool.alloc() orelse return null;
        self.held = zv.BlockSet.join(self.held, blk.perm);
        return @alignCast(self.region[blk.off..][0..block_size]);
    }

    /// `ptr` must be a block this heap handed out and has not taken back.
    pub fn free(self: *Heap, ptr: *align(block_size) [block_size]u8) void {
        const off = @intFromPtr(ptr) -% @intFromPtr(self.region.ptr);
        if (@intFromPtr(ptr) < @intFromPtr(self.region.ptr) or off >> block_shift >= self.pool.count) @panic("zv.Heap: not a block of this heap");
        const idx: u32 = @intCast(off >> block_shift);
        if (self.pool.free_bits >> @intCast(idx) & 1 == 1) @panic("zv.Heap: block freed twice");
        const parts = self.held.cut(zv.BlockSet.bit(idx));
        self.held = parts.tail;
        self.pool.free(.{ .idx = idx, .off = off, .perm = parts.head });
    }
};

pub const laws = struct {
    /// Whatever sequence of allocations and frees: every block is inside the region, aligned, different from every other
    /// live block, keeps its bytes, and a request is refused only when every block is out.
    pub fn blocks_hold(ops: [40]u8) bool {
        var region: [4 * block_size]u8 align(block_size) = undefined;
        var heap = Heap.init(&region);
        var live: [4]?*align(block_size) [block_size]u8 = @splat(null);
        for (ops, 0..) |op, step| {
            const slot = op % 4;
            if (op & 0x80 == 0) {
                const got = heap.alloc();
                const full = for (live) |l| {
                    if (l == null) break false;
                } else true;
                if (got == null) {
                    if (!full) return false;
                } else {
                    const ptr = got.?;
                    if (@intFromPtr(ptr) % block_size != 0 or @intFromPtr(ptr) < @intFromPtr(&region) or @intFromPtr(ptr) >= @intFromPtr(&region) + region.len) return false;
                    for (live) |l| if (l == ptr) return false;
                    @memset(ptr, @intCast(step + 1));
                    const at = for (live, 0..) |l, i| {
                        if (l == null) break i;
                    } else return false;
                    live[at] = ptr;
                }
            } else if (live[slot]) |ptr| {
                for (ptr) |byte| if (byte == 0) return false;
                heap.free(ptr);
                live[slot] = null;
            }
            for (live) |l| if (l) |ptr| for (ptr[1..]) |byte| if (byte != ptr[0]) return false;
        }
        return true;
    }

    /// `pair` gives two different blocks, or leaves the pool as it was.
    pub fn pair_holds(taken: u3) bool {
        var region: [3 * block_size]u8 align(block_size) = undefined;
        var pool = Pool.init(&region);
        var i: u3 = 0;
        while (i < taken % 4) : (i += 1) _ = pool.alloc();
        const before = pool.free_bits;
        const t = pool.pair() orelse return pool.free_bits == before and @popCount(before) < 2;
        return t.first.idx != t.second.idx and pool.free_bits == before & ~(@as(u64, 1) << @intCast(t.first.idx)) & ~(@as(u64, 1) << @intCast(t.second.idx));
    }
};

test "laws hold on random request sequences" {
    try zv.checkLaws(laws, .{ .iterations = 4_000, .seed = 0xB10C });
}

test "blocks are handed out lowest first and come back in any order" {
    var region: [3 * block_size]u8 align(block_size) = undefined;
    var heap = Heap.init(&region);
    const a = heap.alloc().?;
    const b = heap.alloc().?;
    const c = heap.alloc().?;
    try std.testing.expect(heap.alloc() == null);
    try std.testing.expectEqual(@intFromPtr(&region), @intFromPtr(a));
    heap.free(b);
    try std.testing.expectEqual(@intFromPtr(b), @intFromPtr(heap.alloc().?));
    heap.free(c);
    heap.free(a);
    try std.testing.expectEqual(@intFromPtr(a), @intFromPtr(heap.alloc().?));
}

test "tokens cost nothing outside ghost builds" {
    try std.testing.expect(zv.ghost or @sizeOf(Pool) == 4 * @sizeOf(usize));
}
