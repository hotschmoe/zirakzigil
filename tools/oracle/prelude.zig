//! The fixed library every generated program draws on. It is the head of each batch file, verbatim.
//! Every read of heap memory goes through rd/rdb/rdp/rdn/nextOf, which stop at a byte that the tracking
//! allocator poisoned (0xAA). Live data never holds 0xAA: fill writes 1..90, literals are ASCII.

const std = @import("std");
const zv = @import("zv");

const Allocator = std.mem.Allocator;

const Tok = zv.Linear(u64);
const STok = zv.Linear([]u8);
const PoolT = zv.Pool(u64, 4, struct {});

const poison: u8 = 0xAA;
const poison_word: usize = 0xAAAA_AAAA_AAAA_AAAA;

fn fill(s: []u8, from: usize) void {
    for (s[from..], from..) |*b, i| b.* = @intCast(i % 90 + 1);
}

fn mk(a: Allocator, n: usize) ![]u8 {
    const s = try a.alloc(u8, n);
    fill(s, 0);
    return s;
}

fn rd(s: []const u8) u32 {
    var t: u32 = 0;
    for (s) |b| {
        if (b == poison) @panic("oracle: read of freed memory");
        t +%= b;
    }
    return t;
}

fn rdb(p: *const u8) u8 {
    if (p.* == poison) @panic("oracle: read of freed memory");
    return p.*;
}

fn rdp(p: *const []u8) u32 {
    if (p.len == poison_word) @panic("oracle: read of freed memory");
    return rd(p.*);
}

fn mayFail(c: bool) !void {
    if (c) return error.Boom;
}

const Node = struct { val: u8, next: ?*Node };

fn mkNode(a: Allocator, val: u8, next: ?*Node) !*Node {
    const n = try a.create(Node);
    n.* = .{ .val = val, .next = next };
    return n;
}

fn rdn(n: *const Node) u8 {
    if (n.val == poison) @panic("oracle: read of freed memory");
    return n.val;
}

fn nextOf(n: *const Node) ?*Node {
    _ = rdn(n);
    return n.next;
}

const Rec = struct {
    name: []u8,
    vals: []u8,

    fn init(a: Allocator, n: usize) !Rec {
        const name = try mk(a, n);
        errdefer a.free(name);
        const vals = try mk(a, n + 1);
        return .{ .name = name, .vals = vals };
    }

    fn deinit(self: *Rec, a: Allocator) void {
        a.free(self.name);
        a.free(self.vals);
    }

    fn sum(self: *const Rec) u32 {
        return rd(self.name) +% rd(self.vals);
    }
};

fn dropRec(a: Allocator, r: Rec) void {
    a.free(r.name);
    a.free(r.vals);
}

const Bag = struct {
    items: std.ArrayList(u8) = .empty,

    fn add(self: *Bag, a: Allocator, x: u8) !void {
        try self.items.append(a, x);
    }

    fn view(self: *const Bag) []const u8 {
        return self.items.items;
    }

    fn take(self: *Bag, a: Allocator) ![]u8 {
        return self.items.toOwnedSlice(a);
    }

    fn deinit(self: *Bag, a: Allocator) void {
        self.items.deinit(a);
    }
};

const U = union(enum) { owned: []u8, borrowed: []const u8, none };

fn dropU(a: Allocator, u: U) void {
    switch (u) {
        .owned => |s| a.free(s),
        .borrowed, .none => {},
    }
}

fn dropAnyU(a: Allocator, u: U) void {
    switch (u) {
        .owned => |s| a.free(s),
        .borrowed => |s| a.free(@constCast(s)),
        .none => {},
    }
}

fn rdU(u: U) u32 {
    return switch (u) {
        .owned => |s| rd(s),
        .borrowed => |s| rd(s),
        .none => 0,
    };
}

var g_slice: []u8 = &.{};
var g_opt: ?[]u8 = null;

fn stash(s: []u8) void {
    g_slice = s;
}

fn dropStash(a: Allocator) void {
    a.free(g_slice);
    g_slice = &.{};
}

fn dropStashKeep(a: Allocator) void {
    a.free(g_slice);
}

fn consume(a: Allocator, s: []u8) void {
    a.free(s);
}

fn noop(a: Allocator, s: []u8) void {
    _ = a;
    _ = s;
}

const FreeFn = *const fn (Allocator, []u8) void;
const Handler = struct { release: FreeFn };

fn freeRef(a: Allocator, p: *[]u8) void {
    a.free(p.*);
    p.* = &.{};
}

fn freeKeep(a: Allocator, p: *[]u8) void {
    a.free(p.*);
}

fn freeBoth(a: Allocator, p: *[]u8, q: *[]u8) void {
    a.free(p.*);
    a.free(q.*);
}

fn freeIf(a: Allocator, s: []u8, c: bool) void {
    if (c) a.free(s);
}

fn swapIn(a: Allocator, p: *[]u8) !void {
    const n = try mk(a, 6);
    a.free(p.*);
    p.* = n;
}

fn takeOpt(a: Allocator, o: *?[]u8) void {
    if (o.*) |s| {
        a.free(s);
        o.* = null;
    }
}

fn keepOpt(a: Allocator, o: *?[]u8) void {
    if (o.*) |s| a.free(s);
}

fn dropOpt(a: Allocator, o: ?[]u8) void {
    if (o) |s| a.free(s);
}

fn rdOpt(o: ?[]const u8) u32 {
    return if (o) |s| rd(s) else 0;
}

fn ident(s: []u8) []u8 {
    return s;
}

fn inner(s: []u8) []u8 {
    return s[1 .. s.len - 1];
}

fn sinkTok(t: Tok) u64 {
    return t.consume();
}

fn lookTok(t: *const Tok) u64 {
    return t.borrow().*;
}

var static_buf = [_]u8{ 'a', 'b', 'c' };
