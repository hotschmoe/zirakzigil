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
