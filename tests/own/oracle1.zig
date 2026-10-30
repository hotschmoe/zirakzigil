//! Silent misses the differential oracle found (docs/reviews/oracle-1.md), and the regression of heap node chains
//! that 0.17.15 introduced (a zv-own of 0.17.13 found them). Each `bad*` faults in Debug on the poisoning allocator the
//! oracle uses; `ok*` are the same shapes done right.
const std = @import("std");
const Allocator = std.mem.Allocator;

const poison: u8 = 0xAA;

fn rd(s: []const u8) u32 {
    var t: u32 = 0;
    for (s) |b| {
        if (b == poison) @panic("read of freed memory");
        t +%= b;
    }
    return t;
}

fn mk(a: Allocator, n: usize) ![]u8 {
    const s = try a.alloc(u8, n);
    for (s, 0..) |*b, i| b.* = @intCast(i % 90 + 1);
    return s;
}

// 1. Chains of heap nodes.

const Node = struct { val: u8, next: ?*Node };

fn mkNode(a: Allocator, val: u8, next: ?*Node) !*Node {
    const n = try a.create(Node);
    n.* = .{ .val = val, .next = next };
    return n;
}

fn rdn(n: *const Node) u8 {
    if (n.val == poison) @panic("read of freed memory");
    return n.val;
}

fn nextOf(n: *const Node) ?*Node {
    return n.next;
}

fn nextOfChecked(n: *const Node) ?*Node {
    _ = rdn(n);
    return n.next;
}

pub fn badDestroyWalk(a: Allocator) !void {
    const n1 = try mkNode(a, 7, null);
    const n2 = try mkNode(a, 8, n1);
    var cur: ?*Node = n2;
    while (cur) |c| {
        a.destroy(c);
        cur = nextOf(c);
    }
}

pub fn badDestroyWalkChecked(a: Allocator) !void {
    const n1 = try mkNode(a, 7, null);
    const n2 = try mkNode(a, 8, n1);
    var cur: ?*Node = n2;
    while (cur) |c| {
        a.destroy(c);
        cur = nextOfChecked(c);
    }
}

pub fn okDestroyWalk(a: Allocator) !void {
    const n1 = try mkNode(a, 7, null);
    const n2 = try mkNode(a, 8, n1);
    var cur: ?*Node = n2;
    while (cur) |c| {
        const next = nextOfChecked(c);
        a.destroy(c);
        cur = next;
    }
}

pub fn badWalkThenDestroy(a: Allocator) !void {
    const n1 = try mkNode(a, 7, null);
    const n2 = try mkNode(a, 8, n1);
    var cur: ?*Node = n2;
    while (cur) |c| {
        const next = nextOfChecked(c);
        a.destroy(c);
        cur = next;
    }
    a.destroy(n1);
}

pub fn badDestroyThenReadNext(a: Allocator) !void {
    const n1 = try mkNode(a, 7, null);
    const n2 = try mkNode(a, 8, n1);
    a.destroy(n1);
    _ = rdn(n2.next.?);
    a.destroy(n2);
}

pub fn okDestroyOrder(a: Allocator) !void {
    const n1 = try mkNode(a, 7, null);
    const n2 = try mkNode(a, 8, n1);
    _ = rdn(n2.next.?);
    a.destroy(n2);
    a.destroy(n1);
}

// 2. A global that still holds a freed block.

var g_slice: []u8 = &.{};

fn stash(s: []u8) void {
    g_slice = s;
}

pub fn badStashFree(a: Allocator) !void {
    const v = try mk(a, 8);
    stash(v);
    a.free(v);
    _ = rd(g_slice);
}

pub fn badStashFreeInline(a: Allocator) !void {
    const v = try mk(a, 8);
    g_slice = v;
    a.free(v);
    _ = rd(g_slice);
}

pub fn okStashRead(a: Allocator) !void {
    const v = try mk(a, 8);
    stash(v);
    _ = rd(g_slice);
    a.free(v);
    g_slice = &.{};
}

// 3. A free of something that is not the start of an allocation.

pub fn badFreeSubslice(a: Allocator) !void {
    const v = try mk(a, 8);
    const w = v[1..];
    a.free(w);
}

pub fn badFreeTail(a: Allocator) !void {
    const v = try mk(a, 8);
    a.free(v[2..]);
}

pub fn okFreePrefix(a: Allocator) !void {
    const v = try mk(a, 8);
    _ = rd(v[1..]);
    a.free(v);
}

// 4. Functions whose only open item is an assumption.

fn plus(x: u32) u32 {
    return x +% 1;
}

pub fn okIndirectNoPointers(f: *const fn (u32) u32) u32 {
    return f(3);
}

fn consume(a: Allocator, s: []u8) void {
    a.free(s);
}

pub fn badIndirectFree(a: Allocator, f: *const fn (Allocator, []u8) void) !void {
    const v = try mk(a, 8);
    f(a, v);
    _ = rd(v);
}

pub fn okViaPointer(a: Allocator) !void {
    const v = try mk(a, 8);
    const f: *const fn (Allocator, []u8) void = &consume;
    f(a, v);
    _ = plus(1);
}

pub fn okOutsideCall(a: Allocator) !u32 {
    const v = try mk(a, 8);
    defer a.free(v);
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{rd(v)}) catch return 0;
    return @intCast(s.len);
}
