//! Ordinary allocator-heavy code over std's containers, written without the checker in mind: the first review of
//! zv-own (docs/reviews/own-1.md) found that the old false-positive rate had been fitted to a code base without an
//! allocator. Every `ok*` is correct and must stay clean (each ran under `std.heap.DebugAllocator` with nothing
//! reported); every `bad*` is one real mistake of the kind this code invites; `gap*` is a mistake the checker does
//! not see and says so in tests/own/stdcode.expect.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { word, number, space, other };
pub const Token = struct { kind: Kind, text: []const u8 };

fn classOf(c: u8) Kind {
    if (std.ascii.isAlphabetic(c)) return .word;
    if (std.ascii.isDigit(c)) return .number;
    if (c == ' ') return .space;
    return .other;
}

pub fn okTokenize(gpa: Allocator, src: []const u8) ![]Token {
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < src.len) {
        const start = i;
        const kind = classOf(src[i]);
        i += 1;
        while (i < src.len and classOf(src[i]) == kind) i += 1;
        try out.append(gpa, .{ .kind = kind, .text = src[start..i] });
    }
    return out.toOwnedSlice(gpa);
}

pub fn okWordCount(gpa: Allocator, text: []const u8) !u32 {
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer {
        var keys = counts.keyIterator();
        while (keys.next()) |k| gpa.free(k.*);
        counts.deinit(gpa);
    }
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |w| {
        if (counts.getPtr(w)) |n| {
            n.* += 1;
        } else {
            const owned = try gpa.dupe(u8, w);
            errdefer gpa.free(owned);
            try counts.put(gpa, owned, 1);
        }
    }
    var best: u32 = 0;
    var values = counts.valueIterator();
    while (values.next()) |v| best = @max(best, v.*);
    return best;
}

pub fn okAdjacency(gpa: Allocator, edges: []const [2]u32) !usize {
    var adj: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    defer {
        var lists = adj.valueIterator();
        while (lists.next()) |list| list.deinit(gpa);
        adj.deinit(gpa);
    }
    for (edges) |e| {
        const gop = try adj.getOrPut(gpa, e[0]);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, e[1]);
    }
    var total: usize = 0;
    var lists = adj.valueIterator();
    while (lists.next()) |list| total += list.items.len;
    return total;
}

pub fn okDedupe(gpa: Allocator, items: []const u32) ![]u32 {
    var seen: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(gpa);
    for (items) |x| try seen.put(gpa, x, {});
    return gpa.dupe(u32, seen.keys());
}

pub fn okJoin(gpa: Allocator, parts: []const []const u8, sep: u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (parts, 0..) |p, i| {
        if (i != 0) try out.append(gpa, sep);
        try out.appendSlice(gpa, p);
    }
    return out.toOwnedSlice(gpa);
}

pub fn okPrintInto(gpa: Allocator, n: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "{d}-{d}", .{ n, n + 1 });
    return out.toOwnedSlice(gpa);
}

pub fn okSortedCopy(gpa: Allocator, items: []const i32) ![]i32 {
    const copy = try gpa.dupe(i32, items);
    errdefer gpa.free(copy);
    std.mem.sort(i32, copy, {}, std.sort.asc(i32));
    return copy;
}

const Particle = struct { x: f32, y: f32, id: u32 };

pub fn okParticles(gpa: Allocator, n: u32) !f32 {
    var list: std.MultiArrayList(Particle) = .empty;
    defer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) list.appendAssumeCapacity(.{ .x = @floatFromInt(i), .y = 0, .id = i });
    const s = list.slice();
    var sum: f32 = 0;
    for (s.items(.x)) |x| sum += x;
    return sum;
}

pub fn okReserveFill(gpa: Allocator, n: usize) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, n + 1);
    try list.append(gpa, 1);
    const first = &list.items[0];
    var i: usize = 0;
    while (i < n) : (i += 1) list.appendAssumeCapacity(@truncate(i));
    return first.*;
}

pub fn okHeldWithinReserved(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, 8);
    try list.append(gpa, 1);
    const first = &list.items[0];
    try list.append(gpa, 2);
    try list.append(gpa, 3);
    return first.*;
}

pub fn okStackEval(gpa: Allocator, program: []const u8) !i64 {
    var stack: std.ArrayList(i64) = .empty;
    defer stack.deinit(gpa);
    for (program) |c| switch (c) {
        '+' => {
            const b = stack.pop() orelse return error.Underflow;
            const a = stack.pop() orelse return error.Underflow;
            try stack.append(gpa, a + b);
        },
        '0'...'9' => try stack.append(gpa, c - '0'),
        else => {},
    };
    return stack.pop() orelse 0;
}

pub fn okRetainOdd(gpa: Allocator, values: []const u32) !usize {
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, values);
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i] % 2 == 0) _ = list.swapRemove(i) else i += 1;
    }
    return list.items.len;
}

pub fn okHandoff(gpa: Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "abc");
    return list.toOwnedSlice(gpa);
}

pub fn okAdopt(gpa: Allocator) !usize {
    const buf = try gpa.alloc(u8, 4);
    var list: std.ArrayList(u8) = .fromOwnedSlice(buf);
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    return list.items.len;
}

pub fn okRemapGrow(gpa: Allocator, buf: []u8, n: usize) ![]u8 {
    if (gpa.remap(buf, n)) |bigger| return bigger;
    const fresh = try gpa.alloc(u8, n);
    @memcpy(fresh[0..buf.len], buf);
    gpa.free(buf);
    return fresh;
}

pub fn okResizeInPlace(gpa: Allocator, buf: []u8) []u8 {
    if (buf.len > 1 and gpa.resize(buf, buf.len - 1)) return buf[0 .. buf.len - 1];
    return buf;
}

pub fn okShrink(gpa: Allocator, buf: []u8) ![]u8 {
    if (buf.len < 2) return buf;
    return gpa.realloc(buf, buf.len / 2);
}

const Node = struct { value: u32, next: ?*Node = null };

pub fn okArenaList(gpa: Allocator, n: u32) !u32 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var head: ?*Node = null;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const node = try a.create(Node);
        node.* = .{ .value = i, .next = head };
        head = node;
    }
    var sum: u32 = 0;
    var cur = head;
    while (cur) |c| : (cur = c.next) sum += c.value;
    return sum;
}

pub const Tree = struct { left: ?*Tree = null, right: ?*Tree = null, v: u32 };

fn freeNode(gpa: Allocator, n: *Tree) void {
    if (n.left) |l| freeNode(gpa, l);
    if (n.right) |r| freeNode(gpa, r);
    gpa.destroy(n);
}

pub fn okTreeRoundTrip(gpa: Allocator) !u32 {
    const t = try gpa.create(Tree);
    t.* = .{ .v = 3 };
    defer freeNode(gpa, t);
    const l = try gpa.create(Tree);
    l.* = .{ .v = 1 };
    t.left = l;
    return t.v + l.v;
}

fn countA(gpa: Allocator, n: u32, acc: *std.ArrayList(u32)) Allocator.Error!void {
    if (n == 0) return;
    try acc.append(gpa, n);
    try countB(gpa, n - 1, acc);
}

fn countB(gpa: Allocator, n: u32, acc: *std.ArrayList(u32)) Allocator.Error!void {
    if (n == 0) return;
    try acc.append(gpa, n * 2);
    try countA(gpa, n - 1, acc);
}

pub fn okMutual(gpa: Allocator, n: u32) !usize {
    var acc: std.ArrayList(u32) = .empty;
    defer acc.deinit(gpa);
    try countA(gpa, n, &acc);
    return acc.items.len;
}

pub const Interner = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,
    names: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Interner, gpa: Allocator) void {
        for (self.names.items) |n| gpa.free(n);
        self.names.deinit(gpa);
        self.map.deinit(gpa);
    }

    pub fn intern(self: *Interner, gpa: Allocator, s: []const u8) !u32 {
        if (self.map.get(s)) |id| return id;
        const owned = try gpa.dupe(u8, s);
        errdefer gpa.free(owned);
        const id: u32 = @intCast(self.names.items.len);
        try self.names.append(gpa, owned);
        errdefer _ = self.names.pop();
        try self.map.put(gpa, owned, id);
        return id;
    }

    pub fn name(self: *const Interner, id: u32) []const u8 {
        return self.names.items[id];
    }
};

pub fn okInterner(gpa: Allocator) !usize {
    var table: Interner = .{};
    defer table.deinit(gpa);
    const a = try table.intern(gpa, "alpha");
    const b = try table.intern(gpa, "beta");
    const again = try table.intern(gpa, "alpha");
    return table.name(a).len + table.name(b).len + again;
}

pub const Obj = struct { a: u32 = 0, b: u32 = 0 };

pub const Slab = struct {
    items: std.ArrayList(Obj) = .empty,
    free: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *Slab, gpa: Allocator) void {
        self.items.deinit(gpa);
        self.free.deinit(gpa);
    }

    pub fn acquire(self: *Slab, gpa: Allocator) !u32 {
        if (self.free.pop()) |i| return i;
        try self.items.append(gpa, .{});
        return @intCast(self.items.items.len - 1);
    }

    pub fn release(self: *Slab, gpa: Allocator, i: u32) !void {
        try self.free.append(gpa, i);
    }

    pub fn get(self: *Slab, i: u32) *Obj {
        return &self.items.items[i];
    }
};

pub fn okSlab(gpa: Allocator) !u32 {
    var slab: Slab = .{};
    defer slab.deinit(gpa);
    const x = try slab.acquire(gpa);
    slab.get(x).a = 4;
    const y = try slab.acquire(gpa);
    slab.get(y).b = 5;
    try slab.release(gpa, x);
    return slab.get(x).a + slab.get(y).b;
}

pub fn okCache(gpa: Allocator) !usize {
    var map: std.StringHashMapUnmanaged([]u8) = .empty;
    defer {
        var it = map.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        map.deinit(gpa);
    }
    const key = try gpa.dupe(u8, "a");
    errdefer gpa.free(key);
    const value = try gpa.dupe(u8, "value");
    errdefer gpa.free(value);
    try map.put(gpa, key, value);
    if (map.fetchRemove("a")) |kv| {
        gpa.free(kv.key);
        gpa.free(kv.value);
    }
    return map.count();
}

pub fn okBumpValues(gpa: Allocator, n: u32) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    var i: u32 = 0;
    while (i < n) : (i += 1) try map.put(gpa, i, i);
    var it = map.iterator();
    while (it.next()) |e| e.value_ptr.* += 1;
    var sum: u32 = 0;
    var values = map.valueIterator();
    while (values.next()) |v| sum += v.*;
    return sum;
}

const Item = struct { link: Link = .{}, v: u32 };
const Link = struct { next: ?*Link = null };

fn itemOf(l: *Link) *Item {
    return @fieldParentPtr("link", l);
}

pub fn okIntrusive(gpa: Allocator) !u32 {
    const a = try gpa.create(Item);
    defer gpa.destroy(a);
    a.* = .{ .v = 5 };
    return itemOf(&a.link).v;
}

pub fn okAtomicBuf(gpa: Allocator) !u32 {
    const buf = try gpa.alloc(u32, 2);
    defer gpa.free(buf);
    buf[0] = 1;
    _ = @atomicRmw(u32, &buf[0], .Add, 1, .monotonic);
    return @atomicLoad(u32, &buf[0], .acquire);
}

pub fn okCloneBoth(gpa: Allocator, src: *const std.ArrayList(u8)) !usize {
    var copy = try src.clone(gpa);
    defer copy.deinit(gpa);
    try copy.append(gpa, 0);
    return copy.items.len + src.items.len;
}

pub fn okInsertFront(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "bc");
    try list.insert(gpa, 0, 'a');
    const p = &list.items[0];
    return p.*;
}

pub fn okIndexInsteadOfPointer(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    const at = list.items.len - 1;
    try list.append(gpa, 2);
    return list.items[at];
}

pub fn okValueCopyAcrossPut(gpa: Allocator) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, 1, 10);
    const v = map.get(1).?;
    try map.put(gpa, 2, 20);
    return v;
}

// Mistakes.

pub fn badSliceAcrossAppend(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "ab");
    const s = list.items;
    try list.ensureTotalCapacity(gpa, 4096);
    list.items[0] = 'z';
    return s[0];
}

pub fn badValuePtrAcrossPut(gpa: Allocator) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, 1, 10);
    const v = map.getPtr(1).?;
    try map.ensureTotalCapacity(gpa, 4096);
    return v.*;
}

pub fn badGetOrPutPtrAcrossPut(gpa: Allocator) !u32 {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    const gop = try map.getOrPut(gpa, 1);
    gop.value_ptr.* = 1;
    try map.ensureTotalCapacity(gpa, 4096);
    return gop.value_ptr.*;
}

pub fn badKeysAcrossPut(gpa: Allocator) !u32 {
    var map: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, 1, 10);
    const keys = map.keys();
    try map.ensureTotalCapacity(gpa, 4096);
    return keys[0];
}

pub fn badUseAfterDeinitMap(gpa: Allocator) !usize {
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    try map.put(gpa, 1, 10);
    map.deinit(gpa);
    return map.count();
}

pub fn badToOwnedKeepsPointer(gpa: Allocator) !u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "abc");
    try list.ensureTotalCapacity(gpa, 64);
    const first = &list.items[0];
    const owned = try list.toOwnedSlice(gpa);
    defer gpa.free(owned);
    return first.*;
}

pub fn badRemapUse(gpa: Allocator, buf: []u8, n: usize) u8 {
    if (gpa.remap(buf, n)) |bigger| {
        _ = bigger;
        return buf[0];
    }
    return 0;
}

pub fn badTreeUseAfterFree(gpa: Allocator) !u32 {
    const t = try gpa.create(Tree);
    t.* = .{ .v = 3 };
    freeNode(gpa, t);
    return t.v;
}

pub fn badMutualHeld(gpa: Allocator, n: u32) !u32 {
    var acc: std.ArrayList(u32) = .empty;
    defer acc.deinit(gpa);
    try acc.append(gpa, 1);
    const p = &acc.items[0];
    try countA(gpa, n, &acc);
    return p.*;
}

pub fn badSlabPointerAcrossAcquire(gpa: Allocator) !u32 {
    var slab: Slab = .{};
    defer slab.deinit(gpa);
    const x = try slab.acquire(gpa);
    const p = slab.get(x);
    p.a = 1;
    _ = try slab.acquire(gpa);
    return p.a;
}

pub fn badIntrusiveAfterDestroy(gpa: Allocator) !u32 {
    const a = try gpa.create(Item);
    a.* = .{ .v = 5 };
    gpa.destroy(a);
    return itemOf(&a.link).v;
}

pub fn badAtomicAfterFree(gpa: Allocator) !u32 {
    const buf = try gpa.alloc(u32, 2);
    const p = &buf[0];
    gpa.free(buf);
    return @atomicLoad(u32, p, .acquire);
}

pub fn badAdoptTwice(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 4);
    var list: std.ArrayList(u8) = .fromOwnedSlice(buf);
    list.deinit(gpa);
    gpa.free(buf);
}

pub fn badInternerPointerAcrossIntern(gpa: Allocator) !usize {
    var table: Interner = .{};
    defer table.deinit(gpa);
    _ = try table.intern(gpa, "alpha");
    const first = &table.names.items[0];
    _ = try table.intern(gpa, "beta");
    return first.len;
}

// A mistake the checker does not see: a function that frees only when it has something to free is not known to
// have freed its argument (the summary is an intersection over the paths that return).
fn freeIfSome(gpa: Allocator, n: ?*Tree) void {
    if (n) |t| gpa.destroy(t);
}

pub fn gapConditionalFree(gpa: Allocator) !u32 {
    const t = try gpa.create(Tree);
    t.* = .{ .v = 3 };
    freeIfSome(gpa, t);
    return t.v;
}
