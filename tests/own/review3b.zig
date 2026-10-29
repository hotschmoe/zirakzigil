//! Round-3 follow-ups. Each pub fn is one program.
const std = @import("std");

const Allocator = std.mem.Allocator;
const List = std.ArrayList(u8);

var iterations: usize = 1;
var index: usize = 0;

fn show(byte: u8) void {
    std.debug.print("byte {d}\n", .{byte});
    std.mem.doNotOptimizeAway(byte);
}

fn smash() void {
    var buf: [128]u8 = undefined;
    @memset(&buf, 0x5A);
    std.mem.doNotOptimizeAway(&buf);
}

// --- escape of a pointer to a local ---

fn stash(out: *[]u8) void {
    var buf: [4]u8 = .{ 1, 2, 3, 4 };
    out.* = &buf;
}

pub fn badEscapeOut() u8 {
    var slot: []u8 = &.{};
    stash(&slot);
    smash();
    const b = slot[0];
    show(b);
    return b;
}

// --- cross-type and same-slice aliasing. Allocator-first is the Zig idiom. ---

fn freeOther(gpa: Allocator, a: []u8, b: []u8) void {
    gpa.free(a);
    show(b[0]);
}

pub fn badAliasGpaFirst(gpa: Allocator) !void {
    const p = try gpa.alloc(u8, 4);
    @memset(p, 9);
    freeOther(gpa, p, p);
}

fn freeOtherFirst(a: []u8, b: []u8, gpa: Allocator) void {
    gpa.free(a);
    show(b[0]);
}

pub fn badAliasSliceFirst(gpa: Allocator) !void {
    const p = try gpa.alloc(u8, 4);
    @memset(p, 9);
    freeOtherFirst(p, p, gpa);
}

fn dropListFirst(list: *List, items: []u8, gpa: Allocator) void {
    list.deinit(gpa);
    show(items[0]);
}

pub fn badDropListFirst(gpa: Allocator) !void {
    var list: List = .empty;
    try list.append(gpa, 1);
    dropListFirst(&list, list.items, gpa);
}

// --- one element of a loop-built set, freed through the same runtime index ---

pub fn badSavedElem(gpa: Allocator) !void {
    iterations = 4;
    const bufs = try gpa.alloc([]u8, iterations);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        bufs[i] = try gpa.alloc(u8, 4);
        @memset(bufs[i], 7);
    }
    index = 0;
    const saved = bufs[index];
    gpa.free(saved);
    show(saved[0]);
    gpa.free(saved);
    gpa.free(bufs);
}

// --- copy, then the guarded free-and-null of the optional ---

pub fn badCopyThenGuard(gpa: Allocator) !void {
    var x: ?[]u8 = try gpa.alloc(u8, 4);
    @memset(x.?, 3);
    const p = x.?;
    if (x) |q| {
        gpa.free(q);
        x = null;
    }
    show(p[0]);
}

// --- did the container actually move? ---

pub fn diagEnsure(gpa: Allocator) !void {
    var list: List = .empty;
    try list.append(gpa, 1);
    const before = list.items.ptr;
    const cap0 = list.capacity;
    try list.ensureTotalCapacity(gpa, 32);
    std.debug.print("ensure cap {d}->{d} moved {}\n", .{ cap0, list.capacity, before != list.items.ptr });
    if (before != list.items.ptr) std.debug.print("old {d}\n", .{before[0]});
    list.deinit(gpa);
}

pub fn diagAppend(gpa: Allocator) !void {
    var list: List = .empty;
    try list.ensureTotalCapacity(gpa, 1);
    try list.append(gpa, 1);
    const before = list.items.ptr;
    const cap0 = list.capacity;
    try list.append(gpa, 2);
    std.debug.print("append cap {d}->{d} moved {}\n", .{ cap0, list.capacity, before != list.items.ptr });
    if (before != list.items.ptr) std.debug.print("old {d}\n", .{before[0]});
    list.deinit(gpa);
}

/// Unknown reserve, then enough appends to force a new buffer. The early items pointer is stale.
pub fn badGrowPast(gpa: Allocator) !void {
    var list: List = .empty;
    defer list.deinit(gpa);
    iterations = 1;
    try list.ensureTotalCapacity(gpa, iterations);
    try list.append(gpa, 1);
    const items = list.items;
    const before = items.ptr;
    const blocker = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(blocker);
    @memset(blocker, 0xAB);
    try list.ensureTotalCapacity(gpa, 200_000);
    const moved = before != list.items.ptr;
    std.debug.print("growpast cap {d} moved {}\n", .{ list.capacity, moved });
    show(items[0]);
}

/// Constant reserve, no earlier unread size: this growth is one the checker can see.
pub fn badGrowPlain(gpa: Allocator) !void {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    const items = list.items;
    const before = items.ptr;
    const blocker = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(blocker);
    @memset(blocker, 0xAB);
    try list.ensureTotalCapacity(gpa, 200_000);
    const moved = before != list.items.ptr;
    std.debug.print("growplain cap {d} moved {}\n", .{ list.capacity, moved });
    show(items[0]);
}

/// The first reserve of a runtime size is the one that moves the buffer.
pub fn badDynamicGrow(gpa: Allocator) !void {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    const items = list.items;
    const before = items.ptr;
    const blocker = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(blocker);
    @memset(blocker, 0xAB);
    iterations = 200_000;
    try list.ensureTotalCapacity(gpa, iterations);
    const moved = before != list.items.ptr;
    std.debug.print("dyngrow cap {d} moved {}\n", .{ list.capacity, moved });
    show(items[0]);
}

pub fn diagSoft(gpa: Allocator) !void {
    var list: List = .empty;
    iterations = 1;
    try list.ensureTotalCapacity(gpa, iterations);
    try list.append(gpa, 1);
    const before = list.items.ptr;
    const cap0 = list.capacity;
    try list.append(gpa, 2);
    try list.append(gpa, 3);
    try list.append(gpa, 4);
    try list.append(gpa, 5);
    std.debug.print("soft cap {d}->{d} moved {} byte {d}\n", .{ cap0, list.capacity, before != list.items.ptr, before[0] });
    list.deinit(gpa);
}

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(std.heap.page_allocator) catch return;
    if (args.len < 2) return;
    const name = args[1];
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();
    std.debug.print("RUN {s}\n", .{name});
    if (std.mem.eql(u8, name, "badEscapeOut")) {
        _ = badEscapeOut();
        return;
    }
    const r = dispatch(gpa, name) catch |e| {
        std.debug.print("returned error.{s}\n", .{@errorName(e)});
        return;
    };
    std.debug.print("returned {d}\n", .{r});
}

fn dispatch(gpa: Allocator, name: []const u8) !u64 {
    if (std.mem.eql(u8, name, "badAliasGpaFirst")) {
        try badAliasGpaFirst(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badAliasSliceFirst")) {
        try badAliasSliceFirst(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badDropListFirst")) {
        try badDropListFirst(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badSavedElem")) {
        try badSavedElem(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badCopyThenGuard")) {
        try badCopyThenGuard(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "diagEnsure")) {
        try diagEnsure(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "diagAppend")) {
        try diagAppend(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "diagSoft")) {
        try diagSoft(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badGrowPast")) {
        try badGrowPast(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badGrowPlain")) {
        try badGrowPlain(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badDynamicGrow")) {
        try badDynamicGrow(gpa);
        return 0;
    }
    std.debug.print("unknown {s}\n", .{name});
    return 0;
}
