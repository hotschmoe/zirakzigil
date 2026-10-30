//! The free list of examples/freelist.zig written without any ghost code, contracts or tokens. tools/check_erasure.sh
//! compiles it and the real one in ReleaseFast without ghost code and requires the machine code of the entry points
//! to be the same: what the proof costs a production build is nothing.

pub const slots = 8;
pub const block_shift = 6;
pub const nil: u32 = slots;

pub const Block = struct { idx: u32, off: usize };

pub const FreeList = struct {
    cap: usize,
    nfree: u32,
    used: u32,
    head: u32,
    links: [slots]u32,

    pub fn alloc(self: *FreeList) ?Block {
        if (self.nfree == 0) return null;
        const idx = self.head;
        self.head = self.links[idx];
        self.nfree -= 1;
        self.used += 1;
        return .{ .idx = idx, .off = @as(usize, idx) << block_shift };
    }

    pub fn free(self: *FreeList, blk: Block) void {
        self.links[blk.idx] = self.head;
        self.head = blk.idx;
        self.nfree += 1;
        self.used -= 1;
    }
};

export fn freelist_alloc(self: *FreeList, out: *?Block) void {
    out.* = self.alloc();
}

export fn freelist_free(self: *FreeList, idx: u32) void {
    self.free(.{ .idx = idx, .off = @as(usize, idx) << block_shift });
}
