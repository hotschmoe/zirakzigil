//! Overseer probes for zv-own 0.17.21. Each `pub fn` is one program; `bad*` is a Debug-confirmed fault,
//! `ok*` is correct. Mechanisms chosen to be outside the four adversarial rounds: globals, std calls on freed
//! memory, pointers laundered through *anyopaque, comptime function parameters, by-value derefs in callees,
//! @memcpy sources, std slice views (bytesAsSlice) without std bodies.
const std = @import("std");
const Allocator = std.mem.Allocator;

fn show(byte: u8) void {
    std.debug.print("byte {d}\n", .{byte});
    std.mem.doNotOptimizeAway(byte);
}

// 1. A global that holds a heap block; freed in one function, read in another.
var cache: []u8 = &.{};

fn fillCache(gpa: Allocator) !void {
    cache = try gpa.alloc(u8, 8);
    @memset(cache, 7);
}

fn dropCache(gpa: Allocator) void {
    gpa.free(cache);
}

fn readCache() u8 {
    return cache[0];
}

pub fn badGlobalDrop(gpa: Allocator) !void {
    try fillCache(gpa);
    dropCache(gpa);
    show(cache[0]);
}

pub fn badGlobalDropCallee(gpa: Allocator) !void {
    try fillCache(gpa);
    dropCache(gpa);
    show(readCache());
}

pub fn okGlobalRefill(gpa: Allocator) !void {
    try fillCache(gpa);
    dropCache(gpa);
    try fillCache(gpa);
    show(readCache());
    dropCache(gpa);
}

// 2. A freed slice handed to a std function that reads it (no user code reads it).
pub fn badStdEql(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 8);
    @memset(buf, 7);
    gpa.free(buf);
    const same = std.mem.eql(u8, buf, "\x07\x07\x07\x07\x07\x07\x07\x07");
    show(@intFromBool(same));
}

pub fn badStdIndexOf(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 8);
    @memset(buf, 7);
    buf[3] = 9;
    gpa.free(buf);
    const at = std.mem.indexOfScalar(u8, buf, 9) orelse 0;
    show(@intCast(at));
}

pub fn okStdEqlBefore(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 8);
    @memset(buf, 7);
    const same = std.mem.eql(u8, buf, "\x07\x07\x07\x07\x07\x07\x07\x07");
    gpa.free(buf);
    show(@intFromBool(same));
}

// 3. A std view over the block (bytesAsSlice) kept across the free.
pub fn badBytesAsSlice(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 8);
    @memset(buf, 7);
    const words = std.mem.bytesAsSlice(u16, buf);
    gpa.free(buf);
    show(@truncate(words[0]));
}

// 4. @memcpy from a freed block.
pub fn badMemcpySrc(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 8);
    @memset(buf, 7);
    var out: [8]u8 = undefined;
    gpa.free(buf);
    @memcpy(out[0..8], buf[0..8]);
    show(out[0]);
}

// 5. A pointer laundered through *anyopaque (the userdata idiom).
const Node = struct { v: u8, next: ?*Node = null };

pub fn badAnyopaque(gpa: Allocator) !void {
    const node = try gpa.create(Node);
    node.* = .{ .v = 7 };
    const ctx: *anyopaque = @ptrCast(node);
    gpa.destroy(node);
    const back: *Node = @ptrCast(@alignCast(ctx));
    show(back.v);
}

pub fn okAnyopaque(gpa: Allocator) !void {
    const node = try gpa.create(Node);
    node.* = .{ .v = 7 };
    const ctx: *anyopaque = @ptrCast(node);
    const back: *Node = @ptrCast(@alignCast(ctx));
    show(back.v);
    gpa.destroy(node);
}

// 6. A free performed by a callee received as a comptime function parameter (a direct call after instantiation).
fn dropImpl(gpa: Allocator, buf: []u8) void {
    gpa.free(buf);
}

fn apply(comptime f: fn (Allocator, []u8) void, gpa: Allocator, buf: []u8) void {
    f(gpa, buf);
}

pub fn badComptimeFn(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 8);
    @memset(buf, 7);
    apply(dropImpl, gpa, buf);
    show(buf[0]);
}

// 7. A struct passed by value to a callee that reads through its slice field, after the caller freed it.
const Holder = struct { data: []u8 };

fn inspect(h: Holder) u8 {
    return h.data[0];
}

pub fn badByValueDeref(gpa: Allocator) !void {
    const h: Holder = .{ .data = try gpa.alloc(u8, 8) };
    @memset(h.data, 7);
    gpa.free(h.data);
    show(inspect(h));
}

// 8. The same through a pointer-to-struct callee (control: the summary's derefs should catch it).
fn inspectPtr(h: *const Holder) u8 {
    return h.data[0];
}

pub fn badByPtrDeref(gpa: Allocator) !void {
    var h: Holder = .{ .data = try gpa.alloc(u8, 8) };
    @memset(h.data, 7);
    gpa.free(h.data);
    show(inspectPtr(&h));
}

// 9. A free whose pointer argument comes through an optional unwrapped in a callee (`?[]u8` by value).
fn dropOpt(gpa: Allocator, o: ?[]u8) void {
    if (o) |b| gpa.free(b);
}

pub fn badOptionalCallee(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 8);
    @memset(buf, 7);
    dropOpt(gpa, buf);
    show(buf[0]);
}

// 10. Control: plain use after free in one function.
pub fn ctrlUseAfterFree(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 8);
    @memset(buf, 7);
    gpa.free(buf);
    show(buf[0]);
}

// 11. A freed slice stored in a struct returned by value from a helper, read by the caller.
fn makeThenDrop(gpa: Allocator) !Holder {
    const buf = try gpa.alloc(u8, 8);
    @memset(buf, 7);
    const h: Holder = .{ .data = buf };
    gpa.free(buf);
    return h;
}

pub fn badReturnedGone(gpa: Allocator) !void {
    const h = try makeThenDrop(gpa);
    show(h.data[0]);
}

// 12. Free inside a callee reached through a field of a by-value struct copy (aliasing by copy).
const Owner = struct {
    data: []u8,
    fn drop(self: Owner, gpa: Allocator) void {
        gpa.free(self.data);
    }
};

pub fn badCopyDrop(gpa: Allocator) !void {
    const o: Owner = .{ .data = try gpa.alloc(u8, 8) };
    @memset(o.data, 7);
    const c = o;
    c.drop(gpa);
    show(o.data[0]);
}

const Entry = struct { name: []const u8, f: *const fn (Allocator) anyerror!void };
const entries = [_]Entry{
    .{ .name = "badGlobalDrop", .f = badGlobalDrop },
    .{ .name = "badGlobalDropCallee", .f = badGlobalDropCallee },
    .{ .name = "okGlobalRefill", .f = okGlobalRefill },
    .{ .name = "badStdEql", .f = badStdEql },
    .{ .name = "badStdIndexOf", .f = badStdIndexOf },
    .{ .name = "okStdEqlBefore", .f = okStdEqlBefore },
    .{ .name = "badBytesAsSlice", .f = badBytesAsSlice },
    .{ .name = "badMemcpySrc", .f = badMemcpySrc },
    .{ .name = "badAnyopaque", .f = badAnyopaque },
    .{ .name = "okAnyopaque", .f = okAnyopaque },
    .{ .name = "badComptimeFn", .f = badComptimeFn },
    .{ .name = "badByValueDeref", .f = badByValueDeref },
    .{ .name = "badByPtrDeref", .f = badByPtrDeref },
    .{ .name = "badOptionalCallee", .f = badOptionalCallee },
    .{ .name = "ctrlUseAfterFree", .f = ctrlUseAfterFree },
    .{ .name = "badReturnedGone", .f = badReturnedGone },
    .{ .name = "badCopyDrop", .f = badCopyDrop },
};

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(std.heap.page_allocator) catch return;
    if (args.len < 2) {
        std.debug.print("usage: ov NAME\n", .{});
        return;
    }
    const name = args[1];
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();
    std.debug.print("RUN {s}\n", .{name});
    for (entries) |e| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        e.f(gpa) catch |err| {
            std.debug.print("returned error.{s}\n", .{@errorName(err)});
            return;
        };
        std.debug.print("returned 0\n", .{});
        return;
    }
    std.debug.print("unknown {s}\n", .{name});
}
