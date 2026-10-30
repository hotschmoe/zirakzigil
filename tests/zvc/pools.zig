//! Cases for `zv.BlockSet` tokens and a pool built on them (docs/phase4.md): what zvc must refuse about a pool that
//! hands a block out twice, takes back a block twice or one of another pool, corrupts its free set or forges a token;
//! and the controls. Verdicts are pinned in `pools.expect`. Ghost builds only; not run: the unsound ones would panic.

const zv = @import("zv");

pub const Block = struct { idx: u32, perm: zv.BlockSet };
pub const Two = struct { first: Block, second: Block };

inline fn bit(idx: u32) u64 {
    return @as(u64, 1) << @truncate(idx);
}

pub const P = struct {
    free_bits: u64,
    spare: zv.BlockSet,

    pub const assurance = .{
        .take = .verified,
        .give = .verified,
        .pairDistinct = .verified,
        .roundTrip = .verified,
        .twoMints = .verified,
        .giveTwice = .verified,
        .foreignFree = .verified,
        .giveUnchecked = .verified,
        .dupBlock = .verified,
        .takeNoClear = .verified,
        .takeFromEmpty = .verified,
        .giveWrongBit = .verified,
        .forgeSet = .verified,
        .forgeMask = .verified,
        .apartSame = .verified,
        .copyAndHandOut = .verified,
    };

    inline fn sound(p: P) bool {
        return p.spare.mask == p.free_bits;
    }

    inline fn owns(p: P, blk: Block) bool {
        return blk.perm.id == p.spare.id and blk.perm.mask == bit(blk.idx);
    }

    // Controls.

    /// The lowest free block.
    pub fn take(self: *P) ?Block {
        zv.requires(sound(self.*));
        const before = self.free_bits;
        if (self.free_bits == 0) return null;
        const idx: u32 = @ctz(self.free_bits);
        const parts = self.spare.cut(bit(idx));
        self.spare = parts.tail;
        self.free_bits &= ~bit(idx);
        const blk: Block = .{ .idx = idx, .perm = parts.head };
        const got: ?Block = blk;
        return zv.ensures(got, sound(self.*) and owns(self.*, blk) and before & bit(idx) != 0 and self.free_bits == before & ~bit(idx));
    }

    /// Takes a block back, in any order: the lemma says it was not free.
    pub fn give(self: *P, blk: Block) void {
        zv.requires(sound(self.*) and owns(self.*, blk));
        const before = self.free_bits;
        const lemma = zv.BlockSet.apart(self.spare, blk.perm);
        self.spare = zv.BlockSet.join(lemma.head, lemma.tail);
        self.free_bits |= bit(blk.idx);
        return zv.ensures({}, sound(self.*) and before & bit(blk.idx) == 0 and self.free_bits == before | bit(blk.idx));
    }

    /// Two blocks in a row are different.
    pub fn pairDistinct(self: *P) bool {
        zv.requires(sound(self.*));
        const x = self.take() orelse return true;
        const y = self.take() orelse return true;
        return zv.ensures(true, x.idx != y.idx and sound(self.*));
    }

    pub fn roundTrip(set: zv.BlockSet, bits: u64) zv.BlockSet {
        zv.requires(bits & ~set.mask == 0);
        const id = set.id;
        const mask = set.mask;
        const parts = set.cut(bits);
        const back = zv.BlockSet.join(parts.head, parts.tail);
        return zv.ensures(back, back.id == id and back.mask == mask);
    }

    pub fn twoMints(a: u64, b: u64) u64 {
        const x = zv.BlockSet.own(a);
        const y = zv.BlockSet.own(b);
        return zv.ensures(x.mask, x.mask == a and y.mask == b);
    }

    // Reuse and the wrong pool.

    pub fn giveTwice(self: *P, blk: Block) void {
        zv.requires(sound(self.*) and owns(self.*, blk));
        self.give(blk);
        self.give(blk);
    }

    /// A block of another pool: its token names that pool.
    pub fn foreignFree(a: *P, b: *P) void {
        zv.requires(sound(a.*) and sound(b.*));
        const blk = a.take() orelse return;
        b.give(blk);
    }

    /// No check that the block is this pool's.
    pub fn giveUnchecked(self: *P, blk: Block) void {
        zv.requires(sound(self.*));
        self.give(blk);
    }

    // Free-set corruption and duplicated tokens.

    /// Hands out the block and keeps its token: the same block is handed out again.
    pub fn dupBlock(self: *P) ?Block {
        zv.requires(sound(self.*) and self.free_bits != 0);
        const idx: u32 = @ctz(self.free_bits);
        const blk: Block = .{ .idx = idx, .perm = self.spare };
        return blk;
    }

    /// The bit stays set although the block was taken.
    pub fn takeNoClear(self: *P) ?Block {
        zv.requires(sound(self.*));
        if (self.free_bits == 0) return null;
        const idx: u32 = @ctz(self.free_bits);
        const parts = self.spare.cut(bit(idx));
        self.spare = parts.tail;
        const blk: Block = .{ .idx = idx, .perm = parts.head };
        const got: ?Block = blk;
        return zv.ensures(got, sound(self.*));
    }

    /// Takes from a pool that may be empty.
    pub fn takeFromEmpty(self: *P) Block {
        zv.requires(sound(self.*));
        const idx: u32 = @ctz(self.free_bits);
        const parts = self.spare.cut(bit(idx));
        self.spare = parts.tail;
        self.free_bits &= ~bit(idx);
        const blk: Block = .{ .idx = idx, .perm = parts.head };
        return blk;
    }

    /// Marks the wrong block free.
    pub fn giveWrongBit(self: *P, blk: Block) void {
        zv.requires(sound(self.*) and owns(self.*, blk));
        const lemma = zv.BlockSet.apart(self.spare, blk.perm);
        self.spare = zv.BlockSet.join(lemma.head, lemma.tail);
        self.free_bits |= bit(blk.idx +% 1);
        return zv.ensures({}, sound(self.*));
    }

    /// Keeps the token in the struct and also hands out a copy of it.
    pub fn copyAndHandOut(self: *P) ?Block {
        zv.requires(sound(self.*) and self.free_bits != 0);
        const idx: u32 = @ctz(self.free_bits);
        const copy = self.spare;
        const dup: Block = .{ .idx = idx, .perm = copy };
        return dup;
    }

    // Forging.

    pub fn forgeSet(id: usize, mask: u64) zv.BlockSet {
        const s: zv.BlockSet = .{ .id = id, .mask = mask };
        return s;
    }

    pub fn forgeMask(s: zv.BlockSet) zv.BlockSet {
        var t = s;
        t.mask = ~@as(u64, 0);
        return t;
    }

    /// The lemma on one token twice: it would say a token shares nothing with itself.
    pub fn apartSame(s: zv.BlockSet) usize {
        const pair = zv.BlockSet.apart(s, s);
        return pair.head.id;
    }
};
