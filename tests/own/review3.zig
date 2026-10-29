//! Round-3 probes for zv-own 0.17.15. Each pub fn is one program.
//! `ctrl*` should be reported. `bad*` is a real bug. `ok*` is correct.

const std = @import("std");
const zv = @import("zv");

const Allocator = std.mem.Allocator;
const List = std.ArrayList(u8);
const Tok = zv.Linear(u64);
const Pool = zv.Pool(u32, 8, struct {});

/// Loop bounds live here so each allocating loop is one AIR site, not an unrolled straight line.
var iterations: usize = 1;

fn show(byte: u8) void {
    std.debug.print("byte {d}\n", .{byte});
    std.mem.doNotOptimizeAway(byte);
}

// --- controls the identity model is supposed to catch ---

pub fn ctrlDoubleFree(gpa: Allocator) !void {
    const p = try gpa.alloc(u8, 8);
    gpa.free(p);
    gpa.free(p);
}

pub fn ctrlUseAfterFree(gpa: Allocator) !void {
    const p = try gpa.alloc(u8, 8);
    @memset(p, 1);
    gpa.free(p);
    show(p[0]);
}

pub fn ctrlGuardForgotNull(gpa: Allocator) !void {
    const x: ?[]u8 = try gpa.alloc(u8, 8);
    @memset(x.?, 1);
    if (x) |p| gpa.free(p);
    if (x) |p| show(p[0]);
}

pub fn ctrlCopyDeinit(gpa: Allocator) !void {
    var list: List = .empty;
    try list.append(gpa, 1);
    var copy = list;
    copy.deinit(gpa);
    show(list.items[0]);
}

pub fn ctrlReinitFromCopy(gpa: Allocator) !void {
    var list: List = .empty;
    try list.append(gpa, 1);
    const copy = list;
    list.deinit(gpa);
    list = copy;
    show(list.items[0]);
}

pub fn ctrlLinearCopy() u64 {
    const t = Tok.init(1);
    const c = t;
    _ = t.consume();
    return c.consume();
}

pub fn ctrlPoolCopy() u32 {
    var pool: Pool = .{};
    const h = pool.alloc(5) catch unreachable;
    const c = h;
    pool.free(h);
    return pool.get(c).*;
}

pub fn okGuard(gpa: Allocator) !void {
    var x: ?[]u8 = try gpa.alloc(u8, 8);
    if (x) |p| {
        gpa.free(p);
        x = null;
    }
    if (x) |p| gpa.free(p);
}

pub fn okShrink(gpa: Allocator) !void {
    var list: List = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    try list.append(gpa, 2);
    const s = list.items;
    list.shrinkRetainingCapacity(1);
    show(s[0]);
}

// --- success-path writes treated as certain on the caller's error path ---

fn install(slot: *[]u8, next: []u8, ok: bool) !void {
    if (!ok) return error.Rejected;
    slot.* = next;
}

pub fn badInstallCatch(gpa: Allocator) !void {
    var slot = try gpa.alloc(u8, 8);
    @memset(slot, 1);
    const old = slot;
    const next = try gpa.alloc(u8, 8);
    @memset(next, 2);
    install(&slot, next, false) catch {
        gpa.free(slot);
        gpa.free(old);
        gpa.free(next);
        return;
    };
    unreachable;
}

/// Correct: install did not commit, so both buffers are still owned here.
pub fn okInstallCleanup(gpa: Allocator) !void {
    var slot = try gpa.alloc(u8, 8);
    @memset(slot, 1);
    errdefer gpa.free(slot);
    const next = try gpa.alloc(u8, 8);
    @memset(next, 2);
    errdefer gpa.free(next);
    try install(&slot, next, false);
}

fn installOrDrop(gpa: Allocator, slot: *[]u8, next: []u8, ok: bool) !void {
    if (!ok) {
        gpa.free(slot.*);
        return error.Rejected;
    }
    slot.* = next;
}

pub fn badInstallOrDrop(gpa: Allocator) !void {
    var slot = try gpa.alloc(u8, 8);
    @memset(slot, 0x11);
    const next = try gpa.alloc(u8, 8);
    @memset(next, 0x22);
    installOrDrop(gpa, &slot, next, false) catch {
        const q = try gpa.alloc(u8, 8);
        @memset(q, 0x33);
        show(slot[0]);
        slot[0] = 0x44;
        show(q[0]);
        gpa.free(q);
        gpa.free(next);
        return;
    };
    unreachable;
}

fn installList(slot: *List, next: List, ok: bool) !void {
    if (!ok) return error.Rejected;
    slot.* = next;
}

pub fn badInstallList(gpa: Allocator) !void {
    var slot: List = .empty;
    try slot.append(gpa, 1);
    var saved = slot;
    var next: List = .empty;
    try next.append(gpa, 2);
    installList(&slot, next, false) catch {
        slot.deinit(gpa);
        saved.deinit(gpa);
        next.deinit(gpa);
        return;
    };
    unreachable;
}

/// Frees the caller's buffer on every path, installs the replacement only on success.
fn replaceOrFree(gpa: Allocator, slot: *[]u8, src: []const u8, ok: bool) !void {
    if (!ok) {
        gpa.free(slot.*);
        slot.* = &.{};
        return error.Rejected;
    }
    const copy = try gpa.dupe(u8, src);
    gpa.free(slot.*);
    slot.* = copy;
}

pub fn badReplaceOrFree(gpa: Allocator) !void {
    var slot = try gpa.alloc(u8, 8);
    @memset(slot, 0x11);
    replaceOrFree(gpa, &slot, "abcdefgh", false) catch {
        show(slot[0]);
        return;
    };
    unreachable;
}

// --- one site, several live blocks: the older names are one summary ---

fn box(gpa: Allocator) ![]u8 {
    const p = try gpa.alloc(u8, 4);
    @memset(p, 7);
    return p;
}

pub fn badKeepFirst(gpa: Allocator) !void {
    var first: []u8 = &.{};
    var i: usize = 0;
    iterations = 4;
    while (i < iterations) : (i += 1) {
        const p = try box(gpa);
        if (i == 0) first = p;
    }
    gpa.free(first);
    show(first[0]);
    gpa.free(first);
}

pub fn badLoopLast(gpa: Allocator) !void {
    var p: []u8 = &.{};
    var i: usize = 0;
    iterations = 1;
    while (i < iterations) : (i += 1) {
        p = try gpa.alloc(u8, 8);
        @memset(p, 9);
    }
    gpa.free(p);
    show(p[0]);
}

pub fn badPrevBuf(gpa: Allocator) !void {
    var prev: []u8 = try gpa.alloc(u8, 4);
    @memset(prev, 3);
    var i: usize = 0;
    iterations = 3;
    while (i < iterations) : (i += 1) {
        const cur = try gpa.alloc(u8, 4);
        @memset(cur, 4);
        prev = cur;
    }
    gpa.free(prev);
    show(prev[0]);
    gpa.free(prev);
}

pub fn badVarIndex(gpa: Allocator) !void {
    iterations = 3;
    const bufs = try gpa.alloc([]u8, iterations);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        bufs[i] = try gpa.alloc(u8, 4);
        @memset(bufs[i], 5);
    }
    i = 0;
    while (i < iterations) : (i += 1) gpa.free(bufs[i]);
    show(bufs[0][0]);
    gpa.free(bufs[0]);
    gpa.free(bufs);
}

pub fn okFreeEach(gpa: Allocator) !void {
    iterations = 3;
    const bufs = try gpa.alloc([]u8, iterations);
    defer gpa.free(bufs);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        bufs[i] = try gpa.alloc(u8, 4);
        @memset(bufs[i], 5);
    }
    i = 0;
    while (i < iterations) : (i += 1) gpa.free(bufs[i]);
}

pub fn badConstIndex(gpa: Allocator) !void {
    var bufs: [3][]u8 = .{ &.{}, &.{}, &.{} };
    var i: usize = 0;
    iterations = 3;
    while (i < iterations) : (i += 1) {
        bufs[i] = try gpa.alloc(u8, 4);
        @memset(bufs[i], 6);
    }
    gpa.free(bufs[0]);
    show(bufs[0][0]);
    gpa.free(bufs[0]);
    gpa.free(bufs[1]);
    gpa.free(bufs[2]);
}

// --- callee frees only on the error path (by-value parameter) ---

fn ownOrFree(gpa: Allocator, p: []u8, ok: bool) ![]u8 {
    if (!ok) {
        gpa.free(p);
        return error.Rejected;
    }
    return p;
}

pub fn badOwnOrFree(gpa: Allocator) !void {
    const p = try gpa.alloc(u8, 4);
    @memset(p, 8);
    const q = ownOrFree(gpa, p, false) catch {
        show(p[0]);
        return;
    };
    show(q[0]);
    gpa.free(q);
}

// --- container growth that happens, then the function returns an error ---

fn ensureThenFail(list: *List, gpa: Allocator) !void {
    try list.ensureTotalCapacity(gpa, 32);
    return error.Fail;
}

pub fn badEnsureThenFail(gpa: Allocator) !void {
    var list: List = .empty;
    try list.append(gpa, 1);
    const items = list.items;
    ensureThenFail(&list, gpa) catch {
        show(items[0]);
        list.deinit(gpa);
        return;
    };
    unreachable;
}

fn appendThenFail(list: *List, gpa: Allocator) !void {
    try list.append(gpa, 2);
    return error.Fail;
}

pub fn badAppendThenFail(gpa: Allocator) !void {
    var list: List = .empty;
    try list.ensureTotalCapacity(gpa, 1);
    try list.append(gpa, 1);
    const items = list.items;
    appendThenFail(&list, gpa) catch {
        show(items[0]);
        list.deinit(gpa);
        return;
    };
    unreachable;
}

/// Unknown reserve, then an append that really grows. Documented soft growth.
pub fn badSoftAppend(gpa: Allocator) !void {
    var list: List = .empty;
    defer list.deinit(gpa);
    iterations = 1;
    try list.ensureTotalCapacity(gpa, iterations);
    try list.append(gpa, 1);
    const items = list.items;
    try list.append(gpa, 2);
    try list.append(gpa, 3);
    try list.append(gpa, 4);
    try list.append(gpa, 5);
    show(items[0]);
}

pub fn badClearThenUse(gpa: Allocator) !void {
    var list: List = .empty;
    try list.append(gpa, 1);
    const items = list.items;
    list.clearAndFree(gpa);
    show(items[0]);
}

// --- two parameters, different types, one object ---

fn dropAndRead(gpa: Allocator, list: *List, items: []u8) void {
    list.deinit(gpa);
    show(items[0]);
}

pub fn badDropAndRead(gpa: Allocator) !void {
    var list: List = .empty;
    try list.append(gpa, 1);
    dropAndRead(gpa, &list, list.items);
}

// --- union, re-init, recursion, pool reuse, linear leak ---

const Box = union(enum) { heap: []u8, stack: []u8 };

pub fn badUnionFree(gpa: Allocator) !void {
    const u: Box = .{ .heap = try gpa.alloc(u8, 4) };
    @memset(u.heap, 4);
    gpa.free(u.heap);
    show(u.heap[0]);
}

pub fn okUnionRetag(gpa: Allocator) !void {
    var buf: [4]u8 = .{ 1, 2, 3, 4 };
    var u: Box = .{ .heap = try gpa.alloc(u8, 4) };
    gpa.free(u.heap);
    u = .{ .stack = &buf };
    show(u.stack[0]);
}

fn recFree(gpa: Allocator, p: []u8, n: usize) void {
    if (n == 0) {
        gpa.free(p);
        return;
    }
    recFree(gpa, p, n - 1);
}

pub fn badRecFree(gpa: Allocator) !void {
    const p = try gpa.alloc(u8, 4);
    @memset(p, 8);
    recFree(gpa, p, 2);
    show(p[0]);
}

pub fn badPoolReuse() u32 {
    var pool: Pool = .{};
    const h = pool.alloc(5) catch unreachable;
    pool.free(h);
    const h2 = pool.alloc(9) catch unreachable;
    std.mem.doNotOptimizeAway(h2);
    return pool.get(h).*;
}

pub fn badLinearLeak() u64 {
    var a = Tok.init(1);
    a = Tok.init(2);
    const v = a.consume();
    std.debug.print("leaked {d}\n", .{zv.leakedTokens()});
    return v;
}

pub fn badArenaReset(gpa: Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const p = try arena.allocator().alloc(u8, 8);
    @memset(p, 1);
    var copy = arena;
    _ = copy.reset(.free_all);
    show(p[0]);
    arena.deinit();
}

const Buf = struct { owned: bool, data: []u8 };

fn release(gpa: Allocator, b: *Buf) void {
    if (b.owned) gpa.free(b.data);
    b.owned = false;
}

pub fn badRelease(gpa: Allocator) !void {
    const data = try gpa.alloc(u8, 4);
    @memset(data, 6);
    var b = Buf{ .owned = true, .data = data };
    release(gpa, &b);
    show(b.data[0]);
}

pub fn badHandoff(gpa: Allocator) !void {
    var a = try gpa.alloc(u8, 4);
    @memset(a, 11);
    var b: []u8 = &.{};
    handoff(gpa, &a, &b);
    const c = try gpa.alloc(u8, 4);
    @memset(c, 22);
    show(b[0]);
    b[0] = 23;
    show(c[0]);
    gpa.free(c);
}

fn handoff(gpa: Allocator, src: *[]u8, dst: *[]u8) void {
    dst.* = src.*;
    gpa.free(src.*);
}

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(std.heap.page_allocator) catch return;
    if (args.len < 2) {
        std.debug.print("usage: probe NAME\n", .{});
        return;
    }
    const name = args[1];
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();
    std.debug.print("RUN {s}\n", .{name});
    const r = dispatch(gpa, name) catch |e| {
        std.debug.print("returned error.{s}\n", .{@errorName(e)});
        return;
    };
    std.debug.print("returned {d}\n", .{r});
}

fn dispatch(gpa: Allocator, name: []const u8) !u64 {
    if (std.mem.eql(u8, name, "ctrlDoubleFree")) {
        try ctrlDoubleFree(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "ctrlUseAfterFree")) {
        try ctrlUseAfterFree(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "ctrlGuardForgotNull")) {
        try ctrlGuardForgotNull(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "ctrlCopyDeinit")) {
        try ctrlCopyDeinit(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "ctrlReinitFromCopy")) {
        try ctrlReinitFromCopy(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "ctrlLinearCopy")) return ctrlLinearCopy();
    if (std.mem.eql(u8, name, "ctrlPoolCopy")) return ctrlPoolCopy();
    if (std.mem.eql(u8, name, "okGuard")) {
        try okGuard(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "okShrink")) {
        try okShrink(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badInstallCatch")) {
        try badInstallCatch(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "okInstallCleanup")) {
        try okInstallCleanup(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badInstallOrDrop")) {
        try badInstallOrDrop(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badInstallList")) {
        try badInstallList(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badReplaceOrFree")) {
        try badReplaceOrFree(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badKeepFirst")) {
        try badKeepFirst(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badLoopLast")) {
        try badLoopLast(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badPrevBuf")) {
        try badPrevBuf(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badVarIndex")) {
        try badVarIndex(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "okFreeEach")) {
        try okFreeEach(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badConstIndex")) {
        try badConstIndex(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badOwnOrFree")) {
        try badOwnOrFree(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badEnsureThenFail")) {
        try badEnsureThenFail(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badAppendThenFail")) {
        try badAppendThenFail(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badSoftAppend")) {
        try badSoftAppend(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badClearThenUse")) {
        try badClearThenUse(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badDropAndRead")) {
        try badDropAndRead(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badUnionFree")) {
        try badUnionFree(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "okUnionRetag")) {
        try okUnionRetag(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badRecFree")) {
        try badRecFree(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badPoolReuse")) return badPoolReuse();
    if (std.mem.eql(u8, name, "badLinearLeak")) return badLinearLeak();
    if (std.mem.eql(u8, name, "badArenaReset")) {
        try badArenaReset(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badRelease")) {
        try badRelease(gpa);
        return 0;
    }
    if (std.mem.eql(u8, name, "badHandoff")) {
        try badHandoff(gpa);
        return 0;
    }
    std.debug.print("unknown {s}\n", .{name});
    return 0;
}
