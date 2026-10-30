//! Cases for the quantified invariants of docs/phase4.md M4: a copy of the free-list pool of examples/freelist.zig and
//! methods that break it one way each. Everything but the controls must not be proved. Verdicts are pinned in
//! `lists.expect`. Ghost builds only; not run: the unsound ones would panic.

const zv = @import("zv");

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

pub const L = struct {
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

    pub const assurance = .{
        .alloc = .verified,
        .free = .verified,
        .allocStuck = .verified,
        .allocLoses = .verified,
        .allocEmpty = .verified,
        .freeCycle = .verified,
        .freeNoLink = .verified,
        .freeWrongLink = .verified,
        .freeUnchecked = .verified,
        .freeTwice = .verified,
        .freeAndKeep = .verified,
        .forallShort = .verified,
        .storeBreaks = .verified,
        .storeKeeps = .verified,
        .storeSees = .verified,
        .storeClobbers = .verified,
    };
    comptime {
        zv.requireAssurance(L, .tested);
    }

    inline fn inMask(p: L, i: u32) bool {
        return (p.spare.mask >> @truncate(i)) & 1 == 1;
    }

    /// The k-th block of the list is in range and free, and knows its place.
    fn onList(p: L, k: usize) bool {
        const o = at(p.order, @truncate(k));
        return o < slots and inMask(p, o) and at(p.posn, o) == k;
    }

    /// Every free block is on the list, where it says it is.
    fn listed(p: L, i: usize) bool {
        const n: u32 = @truncate(i);
        return !inMask(p, n) or (at(p.posn, n) < p.nfree and at(p.order, at(p.posn, n)) == n);
    }

    /// The k-th block links to the one before it; the first links to `nil`.
    fn linked(p: L, k: usize) bool {
        const o = at(p.order, @truncate(k));
        return at(p.links, o) == (if (k == 0) nil else at(p.order, @truncate(k -% 1)));
    }

    inline fn sound(p: L) bool {
        return p.cap >= slots * block_size and p.nfree <= slots and p.nfree +% p.used == slots and
            (!zv.ghost or (p.spare.mask >> slots == 0 and @popCount(p.spare.mask) == p.nfree and
            p.head == (if (p.nfree == 0) nil else at(p.order, p.nfree -% 1)) and
            zv.forall(slots, p.nfree, p, onList) and zv.forall(slots, slots, p, listed) and zv.forall(slots, p.nfree, p, linked)));
    }

    inline fn owns(p: L, blk: Block) bool {
        return blk.idx < slots and blk.off == @as(usize, blk.idx) << block_shift and
            (!zv.ghost or (blk.perm.id == p.spare.id and blk.perm.mask == bitOf(blk.idx)));
    }

    inline fn granted(old: L, id: zv.Ghost(usize), mask0: zv.Ghost(u64), now: L, blk: Block) bool {
        return sound(now) and owns(now, blk) and now.cap == old.cap and
            now.nfree +% 1 == old.nfree and now.used == old.used +% 1 and
            blk.off +% block_size <= old.cap and blk.off & (block_size - 1) == 0 and
            (!zv.ghost or (now.spare.id == id and mask0 & bitOf(blk.idx) != 0 and !inMask(now, blk.idx) and mask0 == now.spare.mask | bitOf(blk.idx)));
    }

    inline fn unchanged(old: L, now: L) bool {
        return sound(now) and now.cap == old.cap and now.nfree == old.nfree and now.used == old.used and now.head == old.head;
    }

    /// The head of the list.
    pub fn alloc(self: *L) ?Block {
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
    pub fn free(self: *L, blk: Block) void {
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


    // Breaking the list.

    /// The head is not advanced: the next request gets the same block.
    pub fn allocStuck(self: *L) ?Block {
        zv.requires(sound(self.*));
        if (self.nfree == 0) return null;
        const idx = self.head;
        const parts = self.spare.cut(bitOf(idx));
        self.spare = parts.tail;
        self.nfree -= 1;
        self.used += 1;
        const blk: Block = .{ .idx = idx, .off = @as(usize, idx) << block_shift, .perm = parts.head };
        const got: ?Block = blk;
        return zv.ensures(got, sound(self.*));
    }

    /// Cuts the list after the first block: the rest is lost.
    pub fn allocLoses(self: *L) ?Block {
        zv.requires(sound(self.*));
        if (self.nfree == 0) return null;
        const idx = self.head;
        const parts = self.spare.cut(bitOf(idx));
        self.spare = parts.tail;
        self.head = nil;
        self.nfree -= 1;
        self.used += 1;
        const blk: Block = .{ .idx = idx, .off = @as(usize, idx) << block_shift, .perm = parts.head };
        const got: ?Block = blk;
        return zv.ensures(got, sound(self.*));
    }

    /// Takes from a pool that may be empty: `nil` is not a block.
    pub fn allocEmpty(self: *L) Block {
        zv.requires(sound(self.*));
        const idx = self.head;
        const next = self.links[idx];
        const parts = self.spare.cut(bitOf(idx));
        self.spare = parts.tail;
        self.head = next;
        self.nfree -= 1;
        self.used += 1;
        const blk: Block = .{ .idx = idx, .off = @as(usize, idx) << block_shift, .perm = parts.head };
        return blk;
    }

    /// The link of the block put back points at itself: a cycle.
    pub fn freeCycle(self: *L, blk: Block) void {
        zv.requires(sound(self.*) and owns(self.*, blk));
        const lemma = zv.BlockSet.apart(self.spare, blk.perm);
        self.spare = zv.BlockSet.join(lemma.head, lemma.tail);
        self.links[blk.idx] = blk.idx;
        self.order[@as(u3, @truncate(self.nfree))] = blk.idx;
        self.posn[@as(u3, @truncate(blk.idx))] = self.nfree;
        self.head = blk.idx;
        self.nfree += 1;
        self.used -= 1;
        return zv.ensures({}, sound(self.*));
    }

    /// The link is not written: the block points at whatever was there.
    pub fn freeNoLink(self: *L, blk: Block) void {
        zv.requires(sound(self.*) and owns(self.*, blk));
        const lemma = zv.BlockSet.apart(self.spare, blk.perm);
        self.spare = zv.BlockSet.join(lemma.head, lemma.tail);
        self.order[@as(u3, @truncate(self.nfree))] = blk.idx;
        self.posn[@as(u3, @truncate(blk.idx))] = self.nfree;
        self.head = blk.idx;
        self.nfree += 1;
        self.used -= 1;
        return zv.ensures({}, sound(self.*));
    }

    /// The link is written to the block before the one that is the head: the list is cut in two.
    pub fn freeWrongLink(self: *L, blk: Block) void {
        zv.requires(sound(self.*) and owns(self.*, blk));
        const lemma = zv.BlockSet.apart(self.spare, blk.perm);
        self.spare = zv.BlockSet.join(lemma.head, lemma.tail);
        self.links[blk.idx] = nil;
        self.order[@as(u3, @truncate(self.nfree))] = blk.idx;
        self.posn[@as(u3, @truncate(blk.idx))] = self.nfree;
        self.head = blk.idx;
        self.nfree += 1;
        self.used -= 1;
        return zv.ensures({}, sound(self.*));
    }

    /// No check that the block is this pool's: another pool's token, or no one's.
    pub fn freeUnchecked(self: *L, blk: Block) void {
        zv.requires(sound(self.*));
        self.free(blk);
    }

    /// A second `free` of the same block, through the list: its token is gone after the first.
    pub fn freeTwice(self: *L, blk: Block) void {
        zv.requires(sound(self.*) and owns(self.*, blk));
        self.free(blk);
        self.free(blk);
    }

    /// Gives a block back and hands the same one on: the token is gone.
    pub fn freeAndKeep(self: *L, blk: Block) Block {
        zv.requires(sound(self.*) and owns(self.*, blk));
        self.free(blk);
        return blk;
    }

    // Quantifier encoding.

    /// A bound too small for the pool: the instances past it would be missing from the claim.
    pub fn forallShort(self: *L) bool {
        zv.requires(sound(self.*));
        return zv.ensures(true, zv.forall(4, self.nfree, self.*, onList));
    }

    /// The invariant claimed after a store that breaks it for one index.
    pub fn storeBreaks(self: *L, k: u3, v: u32) bool {
        zv.requires(sound(self.*));
        self.links[k] = v;
        return zv.ensures(true, zv.forall(slots, self.nfree, self.*, linked));
    }

    /// A store at one index keeps the others.
    pub fn storeKeeps(self: *L, k: u3, j: u3, v: u32) bool {
        zv.requires(sound(self.*) and k != j);
        const before = self.links[j];
        self.links[k] = v;
        return zv.ensures(true, self.links[j] == before);
    }

    /// A store at one index is seen at it.
    pub fn storeSees(self: *L, k: u3, v: u32) bool {
        self.links[k] = v;
        return zv.ensures(true, self.links[k] == v);
    }

    /// The same store claimed to leave another index alone.
    pub fn storeClobbers(self: *L, k: u3, j: u3, v: u32) bool {
        const before = self.links[j];
        self.links[k] = v;
        return zv.ensures(true, self.links[j] == before);
    }
};
