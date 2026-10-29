//! A helper that appends to two lists, called under `try`: the first append has happened when the second fails (zls
//! `ast.nodesAtLoc`, whose `Context.append` this is).
const std = @import("std");
const Allocator = std.mem.Allocator;

const Context = struct {
    allocator: Allocator,
    nodes: std.ArrayList(u32) = .empty,
    locs: std.ArrayList(u32) = .empty,

    fn append(self: *Context, node: u32) error{OutOfMemory}!void {
        try self.nodes.append(self.allocator, node);
        try self.locs.append(self.allocator, node + 1);
    }
};

pub fn okTwoLists(allocator: Allocator, items: []const u32) !usize {
    var context: Context = .{ .allocator = allocator };
    defer context.nodes.deinit(allocator);
    defer context.locs.deinit(allocator);
    try context.nodes.ensureTotalCapacity(allocator, 32);
    for (items) |child| try context.append(child);
    return context.nodes.items.len;
}

// libvaxis `MouseHandler.updateMouse`: the old list is freed before the copy that can fail, and the caller frees it
// again when `update` fails (Debug with a failing allocator: segmentation fault in the second free; the real function reports the same way).
const Handler = struct {
    last: []u8,

    fn update(self: *Handler, gpa: Allocator) !void {
        gpa.free(self.last);
        self.last = try gpa.dupe(u8, "abc");
    }
};

pub fn badFreeThenDupeFails(gpa: Allocator) !void {
    var h: Handler = .{ .last = try gpa.dupe(u8, "x") };
    defer gpa.free(h.last);
    try h.update(gpa);
}
