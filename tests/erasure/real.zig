//! examples/freelist.zig, the version with the proof, behind the same entry points as plain.zig.

const freelist = @import("freelist");

pub const FreeList = freelist.FreeList;
pub const Block = freelist.Block;

export fn freelist_alloc(self: *FreeList, out: *?Block) void {
    out.* = self.alloc();
}

export fn freelist_free(self: *FreeList, idx: u32) void {
    self.free(.{ .idx = idx, .off = @as(usize, idx) << freelist.block_shift, .perm = .{} });
}
