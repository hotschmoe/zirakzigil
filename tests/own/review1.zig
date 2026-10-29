//! The probes of the first adversarial review of zv-own (docs/reviews/own-1.md). Each `pub fn` is one case. `bad*`
//! are ownership bugs the checker reported clean (Debug and `std.heap.DebugAllocator` confirmed each of them);
//! `fp*` are correct programs it reported as bugs; `ctrl*` are controls; `limit*` were documented gaps.
//! `badIteratorAfterGrow` and `okPutAssumeCapacity` are correct and must stay clean. `ctrlGetPtrThenPut` is correct
//! only because a hash map's first allocation has spare slots, which is std's growth policy and not a rule the
//! checker models: it is pinned as a known false positive.

const std = @import("std");
const zv = @import("zv");

const Allocator = std.mem.Allocator;
const Tok = zv.Linear(u64);
pub const Pool = zv.Pool(u32, 8, struct {});

const Box = struct {
    list: std.ArrayList(u64),
};

const Point = struct { x: u32, y: u32 };

noinline fn freeRec(gpa: Allocator, buf: []u8, n: u32) void {
    if (n == 0) {
        gpa.free(buf);
        return;
    }
    freeRec(gpa, buf, n - 1);
}

noinline fn freeHandleRec(pool: *Pool, h: Pool.Handle, n: u32) void {
    if (n == 0) {
        pool.free(h);
        return;
    }
    freeHandleRec(pool, h, n - 1);
}

noinline fn boxList(lp: *std.ArrayList(u64)) *std.ArrayList(u64) {
    const parent: *Box = @fieldParentPtr("list", lp);
    return &parent.list;
}

// --- controls: the checker should flag these ---

pub fn ctrlUseAfterFree(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 8);
    buf[0] = 7;
    gpa.free(buf);
    return buf[0];
}

pub fn ctrlGetPtrThenPut(gpa: Allocator) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, 1, 10);
    const p = map.getPtr(1).?;
    try map.put(gpa, 2, 20);
    return p.*;
}

pub fn ctrlSwitchLeak(c: bool) u64 {
    const t = Tok.init(1);
    switch (c) {
        true => return t.consume(),
        false => return 0,
    }
}

// --- false negatives: returned container pointers that also invalidate ---

pub fn badAddOne(gpa: Allocator) !u64 {
    var list: std.ArrayList(u64) = .empty;
    defer list.deinit(gpa);
    const p = try list.addOne(gpa);
    p.* = 0x42;
    try list.ensureTotalCapacity(gpa, 10_000);
    list.items[0] = 0x99;
    return p.*;
}

pub fn badAddManyAsSlice(gpa: Allocator) !u64 {
    var list: std.ArrayList(u64) = .empty;
    defer list.deinit(gpa);
    const s = try list.addManyAsSlice(gpa, 1);
    s[0] = 0x42;
    try list.ensureTotalCapacity(gpa, 10_000);
    list.items[0] = 0x99;
    return s[0];
}

pub fn badGetOrPutThenGrow(gpa: Allocator) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    const gop = try map.getOrPut(gpa, 1);
    gop.value_ptr.* = 10;
    try map.ensureTotalCapacity(gpa, 10_000);
    map.getPtr(1).?.* = 99;
    return gop.value_ptr.*;
}

pub fn badIteratorAfterGrow(gpa: Allocator) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, 1, 10);
    var it = map.iterator();
    try map.ensureTotalCapacity(gpa, 10_000);
    map.getPtr(1).?.* = 99;
    const e = it.next().?;
    return e.value_ptr.*;
}

pub fn badKeyIteratorAfterGrow(gpa: Allocator) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, 1, 10);
    var it = map.keyIterator();
    try map.ensureTotalCapacity(gpa, 10_000);
    return it.next().?.*;
}

pub fn badMultiSliceAfterGrow(gpa: Allocator) !u32 {
    var list: std.MultiArrayList(Point) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, .{ .x = 7, .y = 8 });
    const s = list.slice();
    try list.ensureTotalCapacity(gpa, 10_000);
    list.items(.x)[0] = 0x99;
    return s.items(.x)[0];
}

pub fn badFieldParentPtr(gpa: Allocator) !u64 {
    var box = Box{ .list = .empty };
    defer box.list.deinit(gpa);
    try box.list.append(gpa, 0x42);
    const p = &box.list.items[0];
    try boxList(&box.list).ensureTotalCapacity(gpa, 10_000);
    box.list.items[0] = 0x99;
    return p.*;
}

// --- instruction / summary holes ---

pub fn badAtomicLoad(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 8);
    buf[0] = 9;
    const p: *u8 = &buf[0];
    gpa.free(buf);
    return @atomicLoad(u8, p, .seq_cst);
}

pub fn badAtomicRmw(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 8);
    buf[0] = 9;
    const p: *u8 = &buf[0];
    gpa.free(buf);
    return @atomicRmw(u8, p, .Add, 1, .seq_cst);
}

pub fn badInsert(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "abc");
    try list.shrinkAndFreePrecise(gpa, 3);
    const p = &list.items[2];
    try list.insert(gpa, 0, 'Z');
    list.items[2] = 0x99;
    return p.*;
}

pub fn badLabeledLeak(c: bool) u64 {
    const t = Tok.init(1);
    blk: {
        if (c) break :blk;
        return t.consume();
    }
    return 0;
}

pub fn badTryLeak() !u64 {
    const t = Tok.init(1);
    try fail();
    return t.consume();
}

fn fail() error{Nope}!void {
    return error.Nope;
}

pub fn badErrdeferLeak(gpa: Allocator) !u64 {
    const t = Tok.init(1);
    errdefer _ = t.consume();
    const buf = try gpa.alloc(u8, 4);
    gpa.free(buf);
    return 0;
}

pub fn okDeferConsume() u64 {
    const t = Tok.init(1);
    defer _ = t.consume();
    return 0;
}

pub fn badFreeSubslice(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 32);
    const sub = buf[1..];
    gpa.free(sub);
    gpa.free(buf);
}

pub fn badFromOwnedSlice(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 8);
    var list: std.ArrayList(u8) = .fromOwnedSlice(buf);
    list.deinit(gpa);
    gpa.free(buf);
}

pub fn badComptimeSkipConsume() u64 {
    const t = Tok.init(1);
    if (false) return t.consume();
    return 0;
}

pub fn fpComptimeDeadDouble() u64 {
    const t = Tok.init(1);
    if (true) return t.consume();
    return t.consume() + t.consume();
}

pub fn fpToOwnedAssert(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 3);
    try list.shrinkAndFreePrecise(gpa, 1);
    const p = &list.items[0];
    const owned = list.toOwnedSliceAssert();
    const v = p.*;
    gpa.free(owned);
    return v;
}

pub fn badRecFree(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 8);
    buf[0] = 9;
    freeRec(gpa, buf, 3);
    return buf[0];
}

pub fn badRecPool(pool: *Pool) !u32 {
    const h = try pool.alloc(1);
    freeHandleRec(pool, h, 3);
    return pool.get(h).*;
}

pub fn badLinearInList(gpa: Allocator) !usize {
    zv.resetLedger();
    var list: std.ArrayList(Tok) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, Tok.init(1));
    return zv.leakedTokens();
}

pub fn badLinearBytes() u64 {
    var t = Tok.init(1);
    var u: Tok = undefined;
    @memcpy(std.mem.asBytes(&u), std.mem.asBytes(&t));
    return t.consume() + u.consume();
}

// --- documented-limit probes (missing Allocator methods) ---

pub fn limitResizeZero(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 32);
    buf[0] = 9;
    _ = gpa.resize(buf, 0);
    return buf[0];
}

pub fn limitRemapZero(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 32);
    buf[0] = 9;
    _ = gpa.remap(buf, 0);
    return buf[0];
}

// --- correct code the allow-list may reject ---

pub fn fpPopKeepsFirst(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "hello");
    const p = &list.items[0];
    _ = list.pop();
    return p.*;
}

pub fn fpShrinkKeepsFirst(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "hello");
    const p = &list.items[0];
    list.shrinkRetainingCapacity(2);
    return p.*;
}

pub fn fpExpandToCapacity(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 7);
    try list.ensureTotalCapacity(gpa, 32);
    const p = &list.items[0];
    list.expandToCapacity();
    return p.*;
}

pub fn fpEnsureNoGrow(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, 32);
    list.appendAssumeCapacity(7);
    const p = &list.items[0];
    try list.ensureTotalCapacity(gpa, 32);
    return p.*;
}

pub fn fpLockPointers(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 5);
    const p = &list.items[0];
    list.lockPointers();
    const v = p.*;
    list.unlockPointers();
    return v;
}

pub fn fpGetOrPutAssume(gpa: Allocator) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.ensureTotalCapacity(gpa, 8);
    map.putAssumeCapacity(1, 10);
    const p = map.getPtr(1).?;
    _ = map.getOrPutAssumeCapacity(2);
    return p.*;
}

pub fn fpPutAfterEnsure(gpa: Allocator) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.ensureTotalCapacity(gpa, 8);
    try map.put(gpa, 1, 10);
    const p = map.getPtr(1).?;
    try map.put(gpa, 2, 20);
    return p.*;
}

pub fn okPutAssumeCapacity(gpa: Allocator) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.ensureTotalCapacity(gpa, 8);
    map.putAssumeCapacity(1, 10);
    const p = map.getPtr(1).?;
    map.putAssumeCapacity(2, 20);
    return p.*;
}

pub fn okIfOptional(c: bool) u64 {
    const t: ?Tok = if (c) Tok.init(1) else null;
    if (t) |v| return v.consume();
    return 0;
}
