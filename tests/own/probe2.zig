const std = @import("std");

pub fn dangling(gpa: std.mem.Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    const first = &list.items[0];
    try list.append(gpa, 2);
    return first.*;
}


pub fn arena(gpa: std.mem.Allocator) ![]u8 {
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
    const buf = try a.allocator().alloc(u8, 16);
    return buf;
}

pub fn doubleFree(gpa: std.mem.Allocator) !void {
    const buf = try gpa.alloc(u8, 16);
    gpa.free(buf);
    gpa.free(buf);
}

fn firstOf(s: []u8) []u8 {
    return s[0..1];
}

pub fn retLocal() []u8 {
    var buf: [8]u8 = undefined;
    return firstOf(&buf);
}

pub fn stash(out: *[]u8) void {
    var buf: [8]u8 = undefined;
    out.* = buf[0..4];
}
