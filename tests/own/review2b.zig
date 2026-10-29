//! Second-wave probes. Ordinary allocator code the 0.17.13 model is likely to miss.
//! `bad*` is a real bug, `ok*` is correct, `ctrl*` should be reported.

const std = @import("std");
const Allocator = std.mem.Allocator;

fn freeBoth(a: *std.ArrayList(u8), b: *std.ArrayList(u8), gpa: Allocator) void {
    a.deinit(gpa);
    b.deinit(gpa);
}

fn sliceOf(a: *[8]u8) []u8 {
    return a;
}

fn stolen(gpa: Allocator) !std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    return list;
}

fn deinitCopy(list: *std.ArrayList(u8), gpa: Allocator) void {
    var copy = list.*;
    copy.deinit(gpa);
}

// Room says "no realloc", but insert still slides every later element.
pub fn badInsertWithin(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, 8);
    try list.append(gpa, 1);
    try list.append(gpa, 2);
    const p = &list.items[1];
    try list.insert(gpa, 0, 9);
    return p.*;
}

pub fn badInsertAssume(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, 8);
    try list.append(gpa, 1);
    try list.append(gpa, 2);
    const p = &list.items[1];
    list.insertAssumeCapacity(0, 9);
    return p.*;
}

// swapRemove invalidates a pointer to the last element even when nothing is reallocated.
pub fn badLastAfterSwap(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, 8);
    try list.append(gpa, 1);
    try list.append(gpa, 2);
    try list.append(gpa, 3);
    const p = &list.items[2];
    _ = list.swapRemove(0);
    return p.*;
}

pub fn badOrderedRemoveShift(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, 8);
    try list.append(gpa, 1);
    try list.append(gpa, 2);
    try list.append(gpa, 3);
    const p = &list.items[1];
    _ = list.orderedRemove(0);
    return p.*;
}

pub fn badMultiShift(gpa: Allocator) !u32 {
    const P = struct { a: u32 };
    var list: std.MultiArrayList(P) = .empty;
    defer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, 8);
    try list.append(gpa, .{ .a = 1 });
    try list.append(gpa, .{ .a = 2 });
    const p = &list.items(.a)[1];
    try list.insert(gpa, 0, .{ .a = 9 });
    return p.*;
}

pub fn badArrayHashShift(gpa: Allocator) !u32 {
    var map: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.ensureTotalCapacity(gpa, 8);
    try map.put(gpa, 1, 10);
    try map.put(gpa, 2, 20);
    try map.put(gpa, 3, 30);
    const p = map.getPtr(3).?;
    _ = map.swapRemove(1);
    return p.*;
}

pub fn badBufPrint() []const u8 {
    var buf: [16]u8 = @splat(0);
    return std.fmt.bufPrint(&buf, "hi", .{}) catch unreachable;
}

pub fn badSliceRet() []u8 {
    var mem: [8]u8 = @splat(0x5A);
    return sliceOf(&mem);
}

pub fn badFieldRet() *u8 {
    var x: u8 = 0x5A;
    const box = .{ .p = &x };
    return box.p;
}

pub fn badFieldStoreRet() *u8 {
    var x: u8 = 0x5A;
    var box: struct { p: *u8 } = undefined;
    box.p = &x;
    return box.p;
}

pub fn badAliasParams(gpa: Allocator) !void {
    var list: std.ArrayList(u8) = .empty;
    try list.append(gpa, 1);
    freeBoth(&list, &list, gpa);
}

pub fn badDerefCopy(gpa: Allocator) !void {
    var list: std.ArrayList(u8) = .empty;
    try list.append(gpa, 1);
    deinitCopy(&list, gpa);
    list.deinit(gpa);
}

pub fn badDeferReturn(gpa: Allocator) !void {
    var list = try stolen(gpa);
    list.deinit(gpa);
}

const Box = struct { list: std.ArrayList(u8) = .empty };

pub fn badFieldCopy(gpa: Allocator) !void {
    var box: Box = .{};
    try box.list.append(gpa, 1);
    var other: Box = .{ .list = box.list };
    box.list.deinit(gpa);
    other.list.deinit(gpa);
}

pub fn badLoopStale(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 7);
    var p: *u8 = &list.items[0];
    var n: usize = 16;
    while (n <= 4096) : (n *= 8) {
        p = &list.items[0];
        try list.ensureTotalCapacity(gpa, n);
    }
    return p.*;
}

pub fn badReallocUse(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 8);
    buf[0] = 4;
    const bigger = try gpa.realloc(buf, 4096);
    defer gpa.free(bigger);
    return buf[0];
}

pub fn badOptionalDestroy(gpa: Allocator) !void {
    const p = try gpa.create(u32);
    p.* = 1;
    const q: ?*u32 = p;
    gpa.destroy(q.?);
    gpa.destroy(p);
}

pub fn badPoolUse(gpa: Allocator) !u32 {
    var pool: std.heap.MemoryPool(u32) = .empty;
    const p = try pool.create(gpa);
    p.* = 7;
    pool.deinit(gpa);
    return p.*;
}

pub fn badPoolCopy(gpa: Allocator) !void {
    var pool: std.heap.MemoryPool(u32) = .empty;
    _ = try pool.create(gpa);
    var copy = pool;
    copy.deinit(gpa);
    pool.deinit(gpa);
}

pub fn badPoolCopyUse(gpa: Allocator) !u32 {
    var pool: std.heap.MemoryPool(u32) = .empty;
    const p = try pool.create(gpa);
    p.* = 7;
    var copy = pool;
    copy.deinit(gpa);
    return p.*;
}

pub fn badArenaResetCopy(gpa: Allocator) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const buf = try arena.allocator().alloc(u8, 8);
    buf[0] = 6;
    var copy = arena;
    _ = copy.reset(.free_all);
    return buf[0];
}

pub fn badDequeReuse(gpa: Allocator) !u8 {
    var d: std.Deque(u8) = .empty;
    defer d.deinit(gpa);
    try d.ensureTotalCapacity(gpa, 4);
    try d.pushBack(gpa, 1);
    const p = d.frontPtr().?;
    _ = d.popFront();
    try d.pushBack(gpa, 9);
    try d.pushBack(gpa, 8);
    try d.pushBack(gpa, 7);
    try d.pushBack(gpa, 6);
    return p.*;
}

pub fn ctrlStoreOut(out: *?*u8) void {
    var x: u8 = 0x41;
    out.* = &x;
}

pub fn ctrlStoreThenFree(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 8);
    buf[0] = 9;
    const slot: ?*u8 = &buf[0];
    gpa.free(buf);
    return slot.?.*;
}

pub fn ctrlArenaReset(gpa: Allocator) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const buf = try arena.allocator().alloc(u8, 8);
    buf[0] = 6;
    _ = arena.reset(.free_all);
    return buf[0];
}

pub fn ctrlHashGrow(gpa: Allocator) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, 1, 10);
    const p = map.getPtr(1).?;
    try map.ensureTotalCapacity(gpa, 4096);
    return p.*;
}

pub fn okRoomAppend(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, 8);
    try list.append(gpa, 1);
    const p = &list.items[0];
    try list.append(gpa, 2);
    return p.*;
}

pub fn okHashWithin(gpa: Allocator) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.ensureTotalCapacity(gpa, 16);
    try map.put(gpa, 1, 10);
    const p = map.getPtr(1).?;
    try map.put(gpa, 2, 20);
    return p.*;
}
