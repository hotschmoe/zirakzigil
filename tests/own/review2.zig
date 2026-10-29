//! The probes of the second adversarial review of zv-own (docs/reviews/own-2.md).
//! Each pub fn is one program: `bad*` is a real ownership bug, `ok*` is correct,
//! `ctrl*` is a bug the checker is expected to report.

const std = @import("std");
const zv = @import("zv");
const Allocator = std.mem.Allocator;

fn pqOrder(_: void, a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

const Pq = std.PriorityQueue(u32, void, pqOrder);
const Pdq = std.PriorityDequeue(u32, void, pqOrder);

const Doc = struct {
    title: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,
};

fn eatList(list: std.ArrayList(u8), gpa: Allocator) void {
    var local = list;
    local.deinit(gpa);
}

fn eatGen(comptime T: type, list: std.ArrayList(T), gpa: Allocator) void {
    var local = list;
    local.deinit(gpa);
}

fn eatDoc(doc: Doc, gpa: Allocator) void {
    var local = doc;
    local.title.deinit(gpa);
    local.body.deinit(gpa);
}

fn headerOf(list: *std.ArrayList(u8)) std.ArrayList(u8) {
    return list.*;
}

fn itemsOf(list: *std.ArrayList(u8)) []u8 {
    return list.items;
}

fn finishArena(arena: std.heap.ArenaAllocator) void {
    arena.deinit();
}

// --- controls: bugs the 0.17.13 model claims to see ---

pub fn ctrlUseAfterDeinit(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    try list.append(gpa, 7);
    list.deinit(gpa);
    return list.items[0];
}

pub fn ctrlDoubleDeinit(gpa: Allocator) !void {
    var list: std.ArrayList(u8) = .empty;
    try list.append(gpa, 1);
    list.deinit(gpa);
    list.deinit(gpa);
}

pub fn ctrlSliceAcrossGrow(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    const s = list.items;
    try list.ensureTotalCapacity(gpa, 4096);
    return s[0];
}

pub fn ctrlItemsHelper(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 3);
    const s = itemsOf(&list);
    try list.ensureTotalCapacity(gpa, 4096);
    return s[0];
}

pub fn ctrlArrayHashGetOrPut(gpa: Allocator) !u32 {
    var map: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    const gop = try map.getOrPut(gpa, 1);
    gop.value_ptr.* = 10;
    try map.ensureTotalCapacity(gpa, 4096);
    return gop.value_ptr.*;
}

pub fn ctrlPointerCopyFree(gpa: Allocator) !void {
    const p = try gpa.create(u32);
    const q = p;
    gpa.destroy(p);
    gpa.destroy(q);
}

pub fn ctrlLinearCopy() u64 {
    const Tok = zv.Linear(u64);
    const t = Tok.init(1);
    const copy = t;
    return t.consume() + copy.consume();
}

// --- by-value copies of owning containers ---

pub fn badCopyDeinit(gpa: Allocator) !void {
    var list: std.ArrayList(u8) = .empty;
    try list.append(gpa, 1);
    var copy = list;
    copy.deinit(gpa);
    list.deinit(gpa);
}

pub fn badCopyUseAfter(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    try list.append(gpa, 9);
    var copy = list;
    copy.deinit(gpa);
    return list.items[0];
}

pub fn badCopyUseOther(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    try list.append(gpa, 9);
    const kept = list.items;
    const copy = list;
    list.deinit(gpa);
    return copy.items[0] + kept[0];
}

pub fn badAssignDeinit(gpa: Allocator) !void {
    var a: std.ArrayList(u8) = .empty;
    var b: std.ArrayList(u8) = .empty;
    try a.append(gpa, 1);
    b = a;
    a.deinit(gpa);
    b.deinit(gpa);
}

pub fn badNestedCopy(gpa: Allocator) !void {
    var doc: Doc = .{};
    try doc.title.append(gpa, 't');
    try doc.body.append(gpa, 'b');
    var other = doc;
    doc.title.deinit(gpa);
    doc.body.deinit(gpa);
    other.title.deinit(gpa);
    other.body.deinit(gpa);
}

pub fn badEatByValue(gpa: Allocator) !void {
    var list: std.ArrayList(u8) = .empty;
    try list.append(gpa, 1);
    eatList(list, gpa);
    list.deinit(gpa);
}

pub fn badEatGeneric(gpa: Allocator) !void {
    var list: std.ArrayList(u32) = .empty;
    try list.append(gpa, 1);
    eatGen(u32, list, gpa);
    list.deinit(gpa);
}

pub fn badEatDoc(gpa: Allocator) !void {
    var doc: Doc = .{};
    try doc.title.append(gpa, 1);
    try doc.body.append(gpa, 2);
    eatDoc(doc, gpa);
    doc.title.deinit(gpa);
    doc.body.deinit(gpa);
}

pub fn badHeaderHelper(gpa: Allocator) !void {
    var list: std.ArrayList(u8) = .empty;
    try list.append(gpa, 1);
    var copy = headerOf(&list);
    copy.deinit(gpa);
    list.deinit(gpa);
}

pub fn badErrdeferCopy(gpa: Allocator) !void {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.append(gpa, 1);
    var copy = list;
    errdefer copy.deinit(gpa);
    return error.Boom;
}

pub fn badHashCopy(gpa: Allocator) !void {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    try map.put(gpa, 1, 2);
    var copy = map;
    copy.deinit(gpa);
    map.deinit(gpa);
}

pub fn badArrayHashCopy(gpa: Allocator) !void {
    var map: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty;
    try map.put(gpa, 1, 2);
    var copy = map;
    copy.deinit(gpa);
    map.deinit(gpa);
}

pub fn badMultiCopy(gpa: Allocator) !void {
    const P = struct { a: u32, b: u32 };
    var list: std.MultiArrayList(P) = .empty;
    try list.append(gpa, .{ .a = 1, .b = 2 });
    var copy = list;
    copy.deinit(gpa);
    list.deinit(gpa);
}

pub fn badDequeCopy(gpa: Allocator) !void {
    var d: std.Deque(u8) = .empty;
    try d.pushBack(gpa, 1);
    var copy = d;
    copy.deinit(gpa);
    d.deinit(gpa);
}

pub fn badPqCopy(gpa: Allocator) !void {
    var pq: Pq = .empty;
    try pq.push(gpa, 1);
    var copy = pq;
    copy.deinit(gpa);
    pq.deinit(gpa);
}

pub fn badPdqCopy(gpa: Allocator) !void {
    var q: Pdq = .empty;
    try q.push(gpa, 1);
    var copy = q;
    copy.deinit(gpa);
    q.deinit(gpa);
}

pub fn badManagedCopy(gpa: Allocator) !void {
    var list: std.array_list.Managed(u8) = .init(gpa);
    try list.append(1);
    var copy = list;
    copy.deinit();
    list.deinit();
}

pub fn badManagedHashCopy(gpa: Allocator) !void {
    var map = std.AutoHashMap(u32, u32).init(gpa);
    try map.put(1, 2);
    var copy = map;
    copy.deinit();
    map.deinit();
}

pub fn badArraySlotCopy(gpa: Allocator) !void {
    var lists: [2]std.ArrayList(u8) = .{ .empty, .empty };
    try lists[0].append(gpa, 1);
    lists[1] = lists[0];
    lists[0].deinit(gpa);
    lists[1].deinit(gpa);
}

pub fn badOptionalCopy(gpa: Allocator) !void {
    var list: std.ArrayList(u8) = .empty;
    try list.append(gpa, 1);
    var slot: ?std.ArrayList(u8) = list;
    slot.?.deinit(gpa);
    list.deinit(gpa);
}

// --- fromOwnedSlice: the original slice is a second name for the buffer ---

pub fn badAdoptFreeUse(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 8);
    buf[0] = 4;
    const list: std.ArrayList(u8) = .fromOwnedSlice(buf);
    gpa.free(buf);
    return list.items[0];
}

pub fn badAdoptFreeThenDeinit(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 8);
    var list: std.ArrayList(u8) = .fromOwnedSlice(buf);
    gpa.free(buf);
    list.deinit(gpa);
}

pub fn badAdoptGrowUse(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 8);
    buf[0] = 4;
    var list: std.ArrayList(u8) = .fromOwnedSlice(buf);
    try list.ensureTotalCapacity(gpa, 4096);
    return buf[0];
}

pub fn badAdoptGrowFree(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 8);
    var list: std.ArrayList(u8) = .fromOwnedSlice(buf);
    try list.ensureTotalCapacity(gpa, 4096);
    gpa.free(buf);
    list.deinit(gpa);
}

pub fn badAdoptSelfSlice(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "hello");
    try list.appendSlice(gpa, list.items);
    return list.items[0];
}

// --- room tracking vs structures that move elements without reallocating ---

pub fn badPqSift(gpa: Allocator) !u32 {
    var pq: Pq = .empty;
    defer pq.deinit(gpa);
    try pq.ensureTotalCapacity(gpa, 8);
    try pq.push(gpa, 5);
    const p = &pq.items[0];
    try pq.push(gpa, 1);
    return p.*;
}

pub fn badPdqSift(gpa: Allocator) !u32 {
    var q: Pdq = .empty;
    defer q.deinit(gpa);
    try q.ensureTotalCapacity(gpa, 8);
    try q.push(gpa, 5);
    const p = &q.items[0];
    try q.push(gpa, 1);
    return p.*;
}

pub fn badPqPopMoves(gpa: Allocator) !u32 {
    var pq: Pq = .empty;
    defer pq.deinit(gpa);
    try pq.push(gpa, 1);
    try pq.push(gpa, 2);
    try pq.push(gpa, 3);
    const p = &pq.items[1];
    _ = pq.pop();
    return p.*;
}

// --- stack buffer handed to a container the model treats as a value ---

pub fn badInitBufferReturn(gpa: Allocator) !u8 {
    _ = gpa;
    var mem: [8]u8 = @splat(0x5A);
    var list: std.ArrayList(u8) = .initBuffer(&mem);
    list.appendAssumeCapacity(0x5A);
    const p = &list.items[0];
    return p.*;
}

pub fn badInitBufferEscape() *const u8 {
    var mem: [8]u8 = @splat(0x5A);
    var list: std.ArrayList(u8) = .initBuffer(&mem);
    list.appendAssumeCapacity(0x5A);
    return &list.items[0];
}

pub fn badDequeInitBuffer() *const u8 {
    var mem: [8]u8 = @splat(0x5A);
    var d: std.Deque(u8) = .initBuffer(&mem);
    d.pushBackAssumeCapacity(0x5A);
    return d.frontPtr().?;
}

// --- arena copied by value ---

pub fn badArenaCopyUse(gpa: Allocator) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const buf = try arena.allocator().alloc(u8, 8);
    buf[0] = 6;
    var copy = arena;
    copy.deinit();
    return buf[0];
}

pub fn badArenaCopyDeinit(gpa: Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    _ = try arena.allocator().alloc(u8, 32);
    var copy = arena;
    arena.deinit();
    copy.deinit();
}

pub fn badArenaByValue(gpa: Allocator) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const buf = try arena.allocator().alloc(u8, 8);
    buf[0] = 6;
    finishArena(arena);
    return buf[0];
}

// --- atomic store is not a store ---

var published: ?*u8 = null;

pub fn readPublished() u8 {
    return published.?.*;
}

pub fn badAtomicStoreFree(gpa: Allocator) !u8 {
    const buf = try gpa.alloc(u8, 8);
    buf[0] = 9;
    @atomicStore(?*u8, &published, &buf[0], .seq_cst);
    gpa.free(buf);
    return published.?.*;
}

pub fn badAtomicStoreEscape() u8 {
    var x: u8 = 0x41;
    @atomicStore(?*u8, &published, &x, .seq_cst);
    return published.?.*;
}

pub fn badAtomicStoreOut(out: *?*u8) void {
    var x: u8 = 0x41;
    @atomicStore(?*u8, out, &x, .seq_cst);
}

// --- deque is outside the container table ---

pub fn badDequePtrAcrossGrow(gpa: Allocator) !u8 {
    var d: std.Deque(u8) = .empty;
    defer d.deinit(gpa);
    try d.pushBack(gpa, 1);
    const p = d.frontPtr().?;
    try d.ensureTotalCapacity(gpa, 4096);
    return p.*;
}

pub fn badDequeSameDeinit(gpa: Allocator) !void {
    var d: std.Deque(u8) = .empty;
    try d.pushBack(gpa, 1);
    d.deinit(gpa);
    d.deinit(gpa);
}

// --- correct code, possible false positives ---

pub fn okCloneDeinit(gpa: Allocator) !usize {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "abc");
    var copy = try list.clone(gpa);
    defer copy.deinit(gpa);
    return list.items.len + copy.items.len;
}

pub fn okManualSwap(gpa: Allocator) !usize {
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try a.appendSlice(gpa, "aa");
    try b.appendSlice(gpa, "bbbb");
    const tmp = a;
    a = b;
    b = tmp;
    return a.items.len * 10 + b.items.len;
}

pub fn okInitCapacityHold(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = try .initCapacity(gpa, 8);
    defer list.deinit(gpa);
    try list.append(gpa, 7);
    const p = &list.items[0];
    try list.append(gpa, 8);
    return p.*;
}

pub fn okAppendSliceWithin(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, 64);
    try list.append(gpa, 1);
    const p = &list.items[0];
    try list.appendSlice(gpa, "ok");
    return p.*;
}

pub fn okDynamicEnsure(gpa: Allocator, n: usize) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, n);
    try list.append(gpa, 1);
    const p = &list.items[0];
    if (n > 2) try list.append(gpa, 2);
    return p.*;
}

pub fn okDequeWithin(gpa: Allocator) !u8 {
    var d: std.Deque(u8) = try .initCapacity(gpa, 8);
    defer d.deinit(gpa);
    try d.pushBack(gpa, 4);
    const p = d.frontPtr().?;
    try d.pushBack(gpa, 5);
    return p.*;
}

pub fn okPqWithinNoSift(gpa: Allocator) !u32 {
    var pq: Pq = .empty;
    defer pq.deinit(gpa);
    try pq.ensureTotalCapacity(gpa, 8);
    try pq.push(gpa, 1);
    const p = &pq.items[0];
    try pq.push(gpa, 2);
    return p.*;
}

pub fn okToOwnedThenEmptyDeinit(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    try list.append(gpa, 3);
    const owned = try list.toOwnedSlice(gpa);
    defer gpa.free(owned);
    list.deinit(gpa);
    return owned[0];
}

pub fn okMultiToOwned(gpa: Allocator) !u32 {
    const P = struct { a: u32 };
    var list: std.MultiArrayList(P) = .empty;
    try list.append(gpa, .{ .a = 5 });
    var s = list.toOwnedSlice();
    list.deinit(gpa);
    defer s.deinit(gpa);
    return s.items(.a)[0];
}

const Brand = struct {};
const Set = zv.Slots(u32, Brand);

pub fn okSlotsDoubleCancel() !void {
    var storage: [4]Set.Slot = @splat(.empty);
    var set: Set = .init(&storage);
    const h = try set.insert(7);
    set.free(h) catch {};
    set.free(h) catch {};
}

pub fn okMemSwap(gpa: Allocator) !usize {
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try a.appendSlice(gpa, "aa");
    try b.appendSlice(gpa, "bbbb");
    std.mem.swap(std.ArrayList(u8), &a, &b);
    return a.items.len * 10 + b.items.len;
}
