//! A pool of fixed-size blocks whose free blocks form a list: each free block holds the index of the next one in its
//! link word (`links[i]`), and the pool keeps only the head. `zvc` proves of every method that the list stays well
//! formed (docs/phase4.md, M4): every node is in bounds and free, no block is on it twice (so it cannot loop), it
//! ends in `nil`, it holds exactly the blocks whose permission the pool keeps, and `free + live = capacity`; a block
//! handed out is in bounds, aligned and different from every other live block, and a block cannot be taken back twice.
//!
//! The list is described by ghost data, an array `order` of the free blocks (the head last) and its inverse `posn`, and
//! the invariant is written with `zv.forall`, unrolled at comptime over the `slots` blocks: no quantifier reaches the
//! solver. A link word belongs to the pool only while its block is free; `free` writes it with the block's permission
//! in hand, and `alloc` never touches a block it gave away.
//!
//! `Heap` is the checked shell over a real buffer.

const std = @import("std");
const zv = @import("zv");

pub const assurance = .{
    .laws = .{ .blocks_hold = .tested, .reuse_holds = .tested },
};

comptime {
    zv.requireAssurance(@This(), .tested);
}

/// A pool has this many blocks of `block_size` bytes each; `nil` ends the list.
pub const slots = 8;
pub const block_shift = 6;
pub const block_size = 1 << block_shift;
pub const nil: u32 = slots;

inline fn bitOf(idx: u32) u64 {
    return @as(u64, 1) << @truncate(idx);
}

/// An element by a number that may be out of range: the specification reads it only where it is in range.
inline fn at(a: [slots]u32, i: u32) u32 {
    return a[@as(u3, @truncate(i))];
}

pub const Block = struct {
    idx: u32,
    /// Where the bytes start: `idx * block_size`.
    off: usize,
    /// Ghost: the permission for this block alone.
    perm: zv.BlockSet,
};

pub const FreeList = struct {
    cap: usize,
    /// How many blocks are on the list and how many are out; they add up to `slots`.
    nfree: u32,
    used: u32,
    /// The first block of the list, `nil` when it is empty.
    head: u32,
    /// The link word of each block: valid only while the block is on the list.
    links: [slots]u32,
    /// Ghost: the permission for the blocks on the list.
    spare: zv.BlockSet,
    /// Ghost: the blocks on the list, the head last (`order[nfree - 1]`), and where each one is in `order`.
    order: zv.Ghost([slots]u32),
    posn: zv.Ghost([slots]u32),

    pub const assurance = .{ .init = .verified, .alloc = .verified, .free = .verified, .reuse = .verified };
    comptime {
        zv.requireAssurance(FreeList, .tested);
    }

    inline fn inMask(p: FreeList, i: u32) bool {
        return (p.spare.mask >> @truncate(i)) & 1 == 1;
    }

    /// The k-th block of the list is in range and free, and knows its place.
    fn onList(p: FreeList, k: usize) bool {
        const o = at(p.order, @truncate(k));
        return o < slots and inMask(p, o) and at(p.posn, o) == k;
    }

    /// Every free block is on the list, where it says it is.
    fn listed(p: FreeList, i: usize) bool {
        const n: u32 = @truncate(i);
        return !inMask(p, n) or (at(p.posn, n) < p.nfree and at(p.order, at(p.posn, n)) == n);
    }

    /// The k-th block links to the one before it; the first links to `nil`.
    fn linked(p: FreeList, k: usize) bool {
        const o = at(p.order, @truncate(k));
        return at(p.links, o) == (if (k == 0) nil else at(p.order, @truncate(k -% 1)));
    }

    inline fn sound(p: FreeList) bool {
        return p.cap >= slots * block_size and p.nfree <= slots and p.nfree +% p.used == slots and
            (!zv.ghost or (p.spare.mask >> slots == 0 and @popCount(p.spare.mask) == p.nfree and
            p.head == (if (p.nfree == 0) nil else at(p.order, p.nfree -% 1)) and
            zv.forall(slots, p.nfree, p, onList) and zv.forall(slots, slots, p, listed) and zv.forall(slots, p.nfree, p, linked)));
    }

    inline fn owns(p: FreeList, blk: Block) bool {
        return blk.idx < slots and blk.off == @as(usize, blk.idx) << block_shift and
            (!zv.ghost or (blk.perm.id == p.spare.id and blk.perm.mask == bitOf(blk.idx)));
    }

    inline fn granted(old: FreeList, id: zv.Ghost(usize), mask0: zv.Ghost(u64), now: FreeList, blk: Block) bool {
        return sound(now) and owns(now, blk) and now.cap == old.cap and
            now.nfree +% 1 == old.nfree and now.used == old.used +% 1 and
            blk.off +% block_size <= old.cap and blk.off & (block_size - 1) == 0 and
            (!zv.ghost or (now.spare.id == id and mask0 & bitOf(blk.idx) != 0 and !inMask(now, blk.idx) and mask0 == now.spare.mask | bitOf(blk.idx)));
    }

    inline fn unchanged(old: FreeList, now: FreeList) bool {
        return sound(now) and now.cap == old.cap and now.nfree == old.nfree and now.used == old.used and now.head == old.head;
    }

    /// A pool over the first `slots * block_size` bytes of `region`, every block free.
    pub fn init(region: []u8) FreeList {
        zv.requires(region.len >= slots * block_size);
        var p: FreeList = .{
            .cap = region.len,
            .nfree = 0,
            .used = 0,
            .head = nil,
            .links = undefined,
            .spare = undefined,
            .order = if (zv.ghost) undefined else {},
            .posn = if (zv.ghost) undefined else {},
        };
        const whole = if (zv.ghost) zv.BlockSet.own((1 << slots) - 1) else {};
        const none = if (zv.ghost) whole.cut(0) else {};
        p.spare = if (zv.ghost) none.head else {};
        var rest = if (zv.ghost) none.tail else {};
        p.used = slots;
        inline for (0..slots) |i| {
            const one = if (zv.ghost) rest.cut(bitOf(i)) else {};
            rest = if (zv.ghost) one.tail else {};
            p.free(.{ .idx = i, .off = i << block_shift, .perm = if (zv.ghost) one.head else {} });
        }
        if (zv.ghost) rest.discard();
        return zv.ensures(p, sound(p) and p.cap == region.len and p.nfree == slots and p.used == 0);
    }

    /// The head of the list.
    pub fn alloc(self: *FreeList) ?Block {
        zv.requires(sound(self.*));
        const old = self.*;
        const id = if (zv.ghost) self.spare.id else {};
        const mask0 = if (zv.ghost) self.spare.mask else {};
        if (self.nfree == 0) {
            const none: ?Block = null;
            return zv.ensures(none, unchanged(old, self.*) and old.nfree == 0);
        }
        const idx = self.head;
        const next = self.links[idx];
        const parts = if (zv.ghost) self.spare.cut(bitOf(idx)) else {};
        self.spare = if (zv.ghost) parts.tail else {};
        self.head = next;
        self.nfree -= 1;
        self.used += 1;
        const blk: Block = .{ .idx = idx, .off = @as(usize, idx) << block_shift, .perm = if (zv.ghost) parts.head else {} };
        const got: ?Block = blk;
        return zv.ensures(got, granted(old, id, mask0, self.*, blk));
    }

    /// Puts a block on the front of the list. The permission is the proof that it was handed out and not taken back.
    pub fn free(self: *FreeList, blk: Block) void {
        zv.requires(sound(self.*) and owns(self.*, blk));
        const old = self.*;
        const lemma = if (zv.ghost) zv.BlockSet.apart(self.spare, blk.perm) else {};
        self.spare = if (zv.ghost) zv.BlockSet.join(lemma.head, lemma.tail) else {};
        self.links[blk.idx] = self.head;
        if (zv.ghost) {
            self.order[@as(u3, @truncate(self.nfree))] = blk.idx;
            self.posn[@as(u3, @truncate(blk.idx))] = self.nfree;
        }
        self.head = blk.idx;
        self.nfree += 1;
        self.used -= 1;
        return zv.ensures({}, sound(self.*) and self.cap == old.cap and self.nfree == old.nfree +% 1 and self.used +% 1 == old.used and self.head == blk.idx);
    }

    /// A block taken and given back leaves the pool with the same number of free blocks.
    pub fn reuse(self: *FreeList) bool {
        zv.requires(sound(self.*));
        const before = self.nfree;
        const blk = self.alloc() orelse return zv.ensures(true, before == 0 and sound(self.*));
        self.free(blk);
        return zv.ensures(true, self.nfree == before and sound(self.*));
    }
};

/// The shell over bytes: blocks become pointers, and the permissions of everything handed out stay in `held`.
pub const Heap = struct {
    region: []align(block_size) u8,
    list: FreeList,
    held: zv.BlockSet,

    pub const assurance = .{ .init = .checked, .alloc = .checked, .free = .checked };
    comptime {
        zv.requireAssurance(Heap, .tested);
    }

    pub fn init(region: []align(block_size) u8) Heap {
        var list = FreeList.init(region);
        const parts = if (zv.ghost) list.spare.cut(0) else {};
        list.spare = if (zv.ghost) parts.tail else {};
        return .{ .region = region, .list = list, .held = if (zv.ghost) parts.head else {} };
    }

    pub fn alloc(self: *Heap) ?*align(block_size) [block_size]u8 {
        const blk = self.list.alloc() orelse return null;
        if (zv.ghost) self.held = zv.BlockSet.join(self.held, blk.perm);
        return @alignCast(self.region[blk.off..][0..block_size]);
    }

    /// `ptr` must be a block this heap handed out and has not taken back.
    pub fn free(self: *Heap, ptr: *align(block_size) [block_size]u8) void {
        if (@intFromPtr(ptr) < @intFromPtr(self.region.ptr)) @panic("zv.Heap: not a block of this heap");
        const off = @intFromPtr(ptr) - @intFromPtr(self.region.ptr);
        if (off >> block_shift >= slots) @panic("zv.Heap: not a block of this heap");
        const idx: u32 = @intCast(off >> block_shift);
        if (zv.ghost and (self.held.mask >> @intCast(idx)) & 1 == 0) @panic("zv.Heap: block freed twice");
        const parts = if (zv.ghost) self.held.cut(bitOf(idx)) else {};
        self.held = if (zv.ghost) parts.tail else {};
        self.list.free(.{ .idx = idx, .off = off, .perm = if (zv.ghost) parts.head else {} });
    }
};

pub const laws = struct {
    /// Whatever sequence of allocations and frees: every block is inside the region, aligned, different from every other
    /// live block, keeps its bytes, and a request is refused only when every block is out.
    pub fn blocks_hold(ops: [48]u8) bool {
        var region: [slots * block_size]u8 align(block_size) = undefined;
        var heap = Heap.init(&region);
        var live: [slots]?*align(block_size) [block_size]u8 = @splat(null);
        for (ops, 0..) |op, step| {
            const slot = op % slots;
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
                    const at_ = for (live, 0..) |l, i| {
                        if (l == null) break i;
                    } else return false;
                    live[at_] = ptr;
                }
            } else if (live[slot]) |ptr| {
                for (ptr[1..]) |byte| if (byte != ptr[0]) return false;
                heap.free(ptr);
                live[slot] = null;
            }
            for (live) |l| if (l) |ptr| for (ptr[1..]) |byte| if (byte != ptr[0]) return false;
        }
        return true;
    }

    /// A block taken and given back changes nothing the next request can see, and the list serves every block once
    /// before it is empty.
    pub fn reuse_holds(taken: u4) bool {
        var region: [slots * block_size]u8 align(block_size) = undefined;
        var list = FreeList.init(&region);
        var out: [slots]?Block = @splat(null);
        var i: u4 = 0;
        while (i < taken % (slots + 1)) : (i += 1) out[i] = list.alloc();
        if (list.nfree != slots - taken % (slots + 1)) return false;
        const before = list.nfree;
        if (list.reuse() != true or list.nfree != before) return false;
        var seen: u64 = 0;
        for (out) |b| if (b) |blk| {
            if (seen & bitOf(blk.idx) != 0) return false;
            seen |= bitOf(blk.idx);
        };
        return true;
    }
};

test "laws hold on random request sequences" {
    try zv.checkLaws(laws, .{ .iterations = 4_000, .seed = 0xF4EE });
}

test "blocks are handed out head first and come back to the front" {
    var region: [slots * block_size]u8 align(block_size) = undefined;
    var heap = Heap.init(&region);
    const a = heap.alloc().?;
    const b = heap.alloc().?;
    try std.testing.expect(a != b);
    heap.free(a);
    try std.testing.expectEqual(@intFromPtr(a), @intFromPtr(heap.alloc().?));
    heap.free(b);
    try std.testing.expectEqual(@intFromPtr(b), @intFromPtr(heap.alloc().?));
}

test "the list is the whole pool" {
    var region: [slots * block_size]u8 align(block_size) = undefined;
    var heap = Heap.init(&region);
    var n: usize = 0;
    while (heap.alloc() != null) n += 1;
    try std.testing.expectEqual(@as(usize, slots), n);
}
