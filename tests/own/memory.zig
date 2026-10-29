//! Memory cases for zv-own: allocations, containers, arenas, stack slots, pool handles. Each `pub fn` is one
//! case; tests/own/memory.expect pins its verdict. `ok*` are correct and must be clean, `bad*` carry the
//! mistake in their name, `adv*` are adversarial attempts to slip a mistake past the checker.

const std = @import("std");
const zv = @import("zv");

const Allocator = std.mem.Allocator;
const List = std.ArrayList(u8);
const Pool = zv.Pool(u32, 8, struct {});

fn useByte(b: u8) void {
    std.mem.doNotOptimizeAway(b);
}

fn useSlice(s: []const u8) void {
    std.mem.doNotOptimizeAway(s.ptr);
}

// Allocations.

pub fn okAllocFree(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 16);
    defer gpa.free(buf);
    buf[0] = 1;
    useByte(buf[0]);
}

pub fn okAllocReturn(gpa: Allocator) ![]u8 {
    const buf = try gpa.alloc(u8, 16);
    buf[0] = 1;
    return buf;
}

pub fn okDupeReturn(gpa: Allocator, s: []const u8) ![]u8 {
    return gpa.dupe(u8, s);
}

pub fn okRealloc(gpa: Allocator) !void {
    var buf = try gpa.alloc(u8, 4);
    buf = try gpa.realloc(buf, 8);
    buf[7] = 1;
    gpa.free(buf);
}

pub fn okFreeEachBranch(gpa: Allocator, c: bool) !void {
    const buf = try gpa.alloc(u8, 4);
    if (c) {
        gpa.free(buf);
    } else {
        buf[0] = 1;
        gpa.free(buf);
    }
}

pub fn okFreeThenFresh(gpa: Allocator) !void {
    var buf = try gpa.alloc(u8, 4);
    gpa.free(buf);
    buf = try gpa.alloc(u8, 4);
    buf[0] = 1;
    gpa.free(buf);
}

pub fn badDoubleFree(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 16);
    gpa.free(buf);
    gpa.free(buf);
}

pub fn badUseAfterFree(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 16);
    buf[0] = 7;
    gpa.free(buf);
    return buf[0];
}

pub fn badUseAfterFreeSlice(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 16);
    const rest = buf[4..];
    gpa.free(buf);
    return rest[0];
}

pub fn badFreeThenReturn(gpa: Allocator) ![]u8 {
    const buf = try gpa.alloc(u8, 16);
    gpa.free(buf);
    return buf;
}

pub fn badDeferFreeThenReturn(gpa: Allocator) ![]u8 {
    const buf = try gpa.alloc(u8, 16);
    defer gpa.free(buf);
    return buf;
}

pub fn badReallocStale(gpa: Allocator) !u8 {
    var buf = try gpa.alloc(u8, 4);
    const old = buf;
    buf = try gpa.realloc(buf, 64);
    defer gpa.free(buf);
    return old[0];
}

pub fn badFreeInBranchThenUse(gpa: Allocator, c: bool) !u8 {
    const buf = try gpa.alloc(u8, 4);
    if (c) gpa.free(buf);
    return buf[0];
}

pub fn badFreeInLoop(gpa: Allocator, n: u32) !void {
    const buf = try gpa.alloc(u8, 4);
    var i: u32 = 0;
    while (i < n) : (i += 1) gpa.free(buf);
}

// Containers.

pub fn okAppendThenIndex(gpa: Allocator) !u8 {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    try list.append(gpa, 2);
    return list.items[0];
}

pub fn okValueCopyAcrossAppend(gpa: Allocator) !u8 {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    const first = list.items[0];
    try list.append(gpa, 2);
    return first;
}

pub fn okReloadEachRound(gpa: Allocator, n: u32) !void {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 0);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const p = &list.items[0];
        p.* += 1;
        try list.append(gpa, 1);
    }
}

pub fn okToOwnedSlice(gpa: Allocator) ![]u8 {
    var list: List = .empty;
    errdefer list.deinit(gpa);
    try list.append(gpa, 1);
    return list.toOwnedSlice(gpa);
}

pub fn okNoGrowWhileHeld(gpa: Allocator) !u8 {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, 8);
    try list.append(gpa, 1);
    const p = &list.items[0];
    list.appendAssumeCapacity(2);
    return p.*;
}

pub fn badDanglingAfterAppend(gpa: Allocator) !u8 {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    const first = &list.items[0];
    try list.append(gpa, 2);
    return first.*;
}

pub fn badDanglingSlice(gpa: Allocator) !u8 {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    const all = list.items;
    try list.appendSlice(gpa, "more");
    return all[0];
}

pub fn badUseAfterDeinit(gpa: Allocator) !usize {
    var list: List = .empty;
    try list.append(gpa, 1);
    list.deinit(gpa);
    return list.items.len;
}

pub fn badPointerAfterDeinit(gpa: Allocator) !u8 {
    var list: List = .empty;
    try list.append(gpa, 1);
    const p = &list.items[0];
    list.deinit(gpa);
    return p.*;
}

pub fn badReturnItemsAfterDeinit(gpa: Allocator) ![]u8 {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    return list.items;
}

pub fn badLoopHeldPointer(gpa: Allocator, n: u32) !u8 {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 0);
    const p = &list.items[0];
    var i: u32 = 0;
    while (i < n) : (i += 1) try list.append(gpa, 1);
    return p.*;
}

pub fn badParamListInvalidated(list: *List, gpa: Allocator) !u8 {
    const p = &list.items[0];
    try list.append(gpa, 1);
    return p.*;
}

pub fn badOrderedRemove(gpa: Allocator) !u8 {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "abc");
    const last = &list.items[2];
    _ = list.orderedRemove(0);
    return last.*;
}

pub fn badMapPointerAfterPut(gpa: Allocator) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, 1, 10);
    const v = map.getPtr(1).?;
    try map.put(gpa, 2, 20);
    return v.*;
}

pub fn okMapValueAcrossPut(gpa: Allocator) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, 1, 10);
    const v = map.getPtr(1).?.*;
    try map.put(gpa, 2, 20);
    return v;
}

// Arenas.

pub fn okArenaScope(gpa: Allocator) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const buf = try arena.allocator().alloc(u8, 16);
    buf[0] = 3;
    return buf[0];
}

pub fn okArenaCopyOut(gpa: Allocator) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const tmp = try arena.allocator().alloc(u8, 16);
    tmp[0] = 3;
    return gpa.dupe(u8, tmp);
}

pub fn okArenaResetLoop(gpa: Allocator, n: u32) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const buf = try arena.allocator().alloc(u8, 16);
        buf[0] = 1;
    }
}

pub fn badArenaEscape(gpa: Allocator) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    return arena.allocator().alloc(u8, 16);
}

pub fn badArenaUseAfterDeinit(gpa: Allocator) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const buf = try arena.allocator().alloc(u8, 16);
    arena.deinit();
    return buf[0];
}

pub fn badArenaAllocatorAfterDeinit(gpa: Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const a = arena.allocator();
    arena.deinit();
    _ = try a.alloc(u8, 16);
}

pub fn badArenaResetStale(gpa: Allocator) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const buf = try arena.allocator().alloc(u8, 16);
    _ = arena.reset(.retain_capacity);
    return buf[0];
}

pub fn badArenaListEscapes(gpa: Allocator) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var list: List = .empty;
    try list.appendSlice(a, "text");
    return list.items;
}

// Stack slots.

fn firstOf(s: []u8) []u8 {
    return s[0..1];
}

fn tail(s: []u8) []u8 {
    return s[1..];
}

pub fn okReturnParamSlice(s: []u8) []u8 {
    return tail(s);
}

pub fn okLocalUse() u8 {
    var buf: [8]u8 = undefined;
    buf[0] = 1;
    const head = firstOf(&buf);
    return head[0];
}

pub fn okLocalPointerWithinCall() u8 {
    var x: u8 = 5;
    const p = &x;
    p.* += 1;
    return x;
}

pub fn badReturnLocalSlice() []u8 {
    var buf: [8]u8 = undefined;
    return firstOf(&buf);
}

pub fn badStashLocalSlice(out: *[]u8) void {
    var buf: [8]u8 = undefined;
    out.* = buf[0..4];
}

pub fn badReturnFbaAllocation() ![]u8 {
    var buf: [64]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    return fba.allocator().alloc(u8, 8);
}

pub fn badAppendLocalPointer(list: *std.ArrayList(*u8), gpa: Allocator) !void {
    var x: u8 = 1;
    try list.append(gpa, &x);
}

pub fn okAppendLocalPointerToLocalList(gpa: Allocator) !void {
    var x: u8 = 1;
    var list: std.ArrayList(*u8) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, &x);
    list.items[0].* += 1;
}

// Pool handles.

pub fn okPoolUse(pool: *Pool) !u32 {
    const h = try pool.alloc(5);
    const v = pool.get(h).*;
    pool.free(h);
    return v;
}

pub fn badPoolStaleHandle(pool: *Pool) !u32 {
    const h = try pool.alloc(5);
    pool.free(h);
    return pool.get(h).*;
}

pub fn badPoolDoubleFree(pool: *Pool) !void {
    const h = try pool.alloc(5);
    pool.free(h);
    pool.free(h);
}

pub fn badPoolPointerAfterFree(pool: *Pool) !u32 {
    const h = try pool.alloc(5);
    const p = pool.get(h);
    pool.free(h);
    return p.*;
}

pub fn okPoolPointerOtherHandle(pool: *Pool) !u32 {
    const a = try pool.alloc(5);
    const b = try pool.alloc(6);
    const p = pool.get(a);
    pool.free(b);
    const v = p.*;
    pool.free(a);
    return v;
}

// Across calls.

fn drop(gpa: Allocator, buf: []u8) void {
    gpa.free(buf);
}

fn grow(list: *List, gpa: Allocator) !void {
    try list.append(gpa, 0);
}

fn peek(list: *List) *u8 {
    return &list.items[0];
}

pub fn badHelperFrees(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 4);
    drop(gpa, buf);
    return buf[0];
}

pub fn badHelperDoubleFree(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 4);
    drop(gpa, buf);
    gpa.free(buf);
}

pub fn badHelperInvalidates(gpa: Allocator) !u8 {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    const p = &list.items[0];
    try grow(&list, gpa);
    return p.*;
}

pub fn badReturnedPointerInvalidated(gpa: Allocator) !u8 {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    const p = peek(&list);
    try list.append(gpa, 2);
    return p.*;
}

pub fn okHelperReads(gpa: Allocator) !u8 {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    const p = peek(&list);
    return p.*;
}

// Adversarial.

const Wrapper = struct { data: []u8 };

pub fn advAliasThroughStruct(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 4);
    const w: Wrapper = .{ .data = buf };
    gpa.free(buf);
    return w.data[0];
}

pub fn advAliasThroughVar(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 4);
    var keep: []u8 = undefined;
    keep = buf;
    gpa.free(buf);
    return keep[0];
}

pub fn advAliasThroughOptional(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 4);
    const o: ?[]u8 = buf;
    gpa.free(buf);
    return o.?[0];
}

pub fn advFreeViaAlias(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 4);
    const other = buf;
    gpa.free(buf);
    gpa.free(other);
}

pub fn advFreeParamThenUse(gpa: Allocator, buf: []u8) u8 {
    gpa.free(buf);
    return buf[0];
}

pub fn advThroughMemcpy(gpa: Allocator, dst: []u8) !void {
    const buf = try gpa.alloc(u8, 4);
    defer gpa.free(buf);
    @memcpy(dst[0..4], buf);
}

pub fn advIndirectCall(f: *const fn () void) void {
    f();
}

pub fn advUnrelatedFreeKeepsPointer(gpa: Allocator) !u8 {
    const a = try gpa.alloc(u8, 4);
    defer gpa.free(a);
    const b = try gpa.alloc(u8, 4);
    gpa.free(b);
    return a[0];
}
