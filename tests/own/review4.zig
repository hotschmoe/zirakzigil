//! Round-4 probes for zv-own 0.17.18 (tag / flag ownership, deinit, soft kills).
//! Each `pub fn` is one program. Run: probe.exe NAME
//! `ctrl*` should be reported. `ok*` is correct. `bad*` is a Debug-confirmed bug.

const std = @import("std");

const Allocator = std.mem.Allocator;

const Kind = enum { borrowed, owned };

const Buf = struct {
    data: []u8,
    kind: Kind,

    fn deinit(self: *Buf, gpa: Allocator) void {
        if (self.kind == .owned) gpa.free(self.data);
        self.* = undefined;
    }
};

fn show(byte: u8) void {
    std.debug.print("byte {d}\n", .{byte});
    std.mem.doNotOptimizeAway(byte);
}

fn release(buf: Buf, gpa: Allocator) void {
    if (buf.kind == .owned) gpa.free(buf.data);
}

fn give(fail: bool) !void {
    if (fail) return error.Failed;
}

/// Take ownership, then on the success path hand it back. The failing `try` leaves `.owned`.
fn armTry(buf: *Buf, fail: bool) !void {
    buf.kind = .owned;
    try give(fail);
    buf.kind = .borrowed;
}

fn armError(buf: *Buf, fail: bool) !void {
    buf.kind = .owned;
    if (fail) return error.Failed;
    buf.kind = .borrowed;
}

fn armLocal(buf: *Buf, fail: bool) !void {
    if (!fail) {
        buf.kind = .borrowed;
        return;
    }
    buf.kind = .owned;
    const err: anyerror!void = error.Failed;
    return err;
}

fn armErrOnly(buf: *Buf, fail: bool) !void {
    if (!fail) return;
    buf.kind = .owned;
    return error.Failed;
}

fn armErrOnlyLocal(buf: *Buf, fail: bool) !void {
    if (!fail) return;
    buf.kind = .owned;
    const err: anyerror!void = error.Failed;
    return err;
}

fn setKind(buf: *Buf, kind: Kind) void {
    buf.kind = kind;
}

fn freeIfLen(buf: *Buf, gpa: Allocator) void {
    if (buf.kind == .owned and buf.data.len > 0) gpa.free(buf.data);
}

fn releaseMutated(buf: Buf, gpa: Allocator) void {
    var local = buf;
    local.kind = .owned;
    if (local.kind == .owned) gpa.free(local.data);
}

const SetFn = *const fn (*Buf) void;

fn setOwned(b: *Buf) void {
    b.kind = .owned;
}

fn callFlip(f: SetFn, b: *Buf) void {
    f(b);
}

fn box(gpa: Allocator) ![]u8 {
    const p = try gpa.alloc(u8, 8);
    @memset(p, 7);
    return p;
}

var iterations: usize = 4;

fn use(data: []u8, gpa: Allocator) void {
    show(data[0]);
    gpa.free(data);
}

// --- controls: a known tag, a free, a use. These must be findings. ---

pub fn ctrlOwnedUse(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    const buf = Buf{ .data = data, .kind = .owned };
    release(buf, gpa);
    use(data, gpa);
}

pub fn okBorrowedUse(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    const buf = Buf{ .data = data, .kind = .borrowed };
    release(buf, gpa);
    use(data, gpa);
}

pub fn ctrlInlineOwned(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    buf.kind = .owned;
    if (buf.kind == .owned) gpa.free(buf.data);
    use(data, gpa);
}

pub fn ctrlFieldPtr(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    const p: *Kind = &buf.kind;
    p.* = .owned;
    if (buf.kind == .owned) gpa.free(buf.data);
    use(data, gpa);
}

pub fn ctrlAtomicStore(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    @atomicStore(Kind, &buf.kind, .owned, .seq_cst);
    release(buf, gpa);
    use(data, gpa);
}

pub fn ctrlDeinit(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .owned };
    buf.deinit(gpa);
    use(data, gpa);
}

pub fn okDeinitBorrowed(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    buf.deinit(gpa);
    use(data, gpa);
}

pub fn ctrlMutateCopy(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    const buf = Buf{ .data = data, .kind = .borrowed };
    releaseMutated(buf, gpa);
    use(data, gpa);
}

pub fn ctrlList(gpa: Allocator) anyerror!void {
    var list: std.ArrayList(u8) = .empty;
    try list.append(gpa, 7);
    const items = list.items;
    list.deinit(gpa);
    show(items[0]);
    gpa.free(items);
}

pub fn ctrlReinit(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .owned };
    release(buf, gpa);
    buf = Buf{ .data = data, .kind = .borrowed };
    show(buf.data[0]);
    gpa.free(data);
}

pub fn ctrlGuardCopy(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    const slot: ?[]u8 = data;
    var copy = slot;
    if (copy) |p| {
        gpa.free(p);
        copy = null;
    }
    if (slot) |p| show(p[0]);
    gpa.free(data);
}

// --- the tag is changed by a write the checker does not treat as a new enum constant ---

pub fn badMemsetKind(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    @memset(@as(*[1]u8, @ptrCast(&buf.kind)), @intFromEnum(Kind.owned));
    release(buf, gpa);
    use(data, gpa);
}

pub fn badByteStore(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    const p: *u8 = @ptrCast(&buf.kind);
    p.* = @intFromEnum(Kind.owned);
    if (buf.kind == .owned) gpa.free(buf.data);
    use(data, gpa);
}

pub fn badAtomicRmw(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    _ = @atomicRmw(Kind, &buf.kind, .Xchg, .owned, .seq_cst);
    release(buf, gpa);
    use(data, gpa);
}

pub fn badCmpxchg(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    _ = @cmpxchgStrong(Kind, &buf.kind, .borrowed, .owned, .seq_cst, .seq_cst);
    release(buf, gpa);
    use(data, gpa);
}

// --- a callee writes the tag; the value on the error path is the success path's constant ---

pub fn badArmTry(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    armTry(&buf, true) catch {
        release(buf, gpa);
        use(data, gpa);
        return;
    };
}

pub fn badArmFromTrue(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .owned };
    armError(&buf, true) catch {
        release(buf, gpa);
        use(data, gpa);
        return;
    };
}

pub fn badArmLocal(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    armLocal(&buf, true) catch {
        release(buf, gpa);
        use(data, gpa);
        return;
    };
}

pub fn badErrOnly(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    armErrOnly(&buf, true) catch {
        release(buf, gpa);
        use(data, gpa);
        return;
    };
}

pub fn badErrOnlyLocal(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    armErrOnlyLocal(&buf, true) catch {
        release(buf, gpa);
        use(data, gpa);
        return;
    };
}

pub fn badDeinitArm(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .owned };
    armTry(&buf, true) catch {
        buf.deinit(gpa);
        use(data, gpa);
        return;
    };
}

pub fn okArmSuccess(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    try armTry(&buf, false);
    release(buf, gpa);
    use(data, gpa);
}

// --- the tag is a constant at the call and unknown inside the callee ---

pub fn badSetKind(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    setKind(&buf, .owned);
    release(buf, gpa);
    use(data, gpa);
}

pub fn badFnPtr(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    callFlip(&setOwned, &buf);
    release(buf, gpa);
    use(data, gpa);
}

pub fn badLoopRelease(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    var i: usize = 0;
    while (i < iterations) : (i += 1) buf.kind = .owned;
    release(buf, gpa);
    use(data, gpa);
}

pub fn ctrlLoopInline(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .borrowed };
    var i: usize = 0;
    while (i < iterations) : (i += 1) buf.kind = .owned;
    if (buf.kind == .owned) gpa.free(buf.data);
    use(data, gpa);
}

pub fn badAndLen(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var buf = Buf{ .data = data, .kind = .owned };
    freeIfLen(&buf, gpa);
    use(data, gpa);
}

pub fn badSoftParam(gpa: Allocator, kind: Kind) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    const buf = Buf{ .data = data, .kind = kind };
    release(buf, gpa);
    use(data, gpa);
}

// --- deinit frees one field; a union tag moves the pointer to the other variant ---

const Slot = union(enum) {
    none,
    buf: []u8,
};

fn freeSlot(u: Slot, gpa: Allocator) void {
    switch (u) {
        .buf => |p| gpa.free(p),
        .none => {},
    }
}

pub fn badUnionAssign(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var u: Slot = .{ .none = {} };
    u = .{ .buf = data };
    freeSlot(u, gpa);
    use(data, gpa);
}

pub fn badUnionField(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var u: Slot = .{ .none = {} };
    u.buf = data;
    freeSlot(u, gpa);
    use(data, gpa);
}

pub fn okUnionNone(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    const u: Slot = .{ .none = {} };
    freeSlot(u, gpa);
    use(data, gpa);
}

pub fn okUnionKeep(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var u: Slot = .{ .buf = data };
    u = .{ .none = {} };
    freeSlot(u, gpa);
    use(data, gpa);
}

pub fn badOptionalSet(gpa: Allocator) anyerror!void {
    const data = try gpa.alloc(u8, 8);
    @memset(data, 7);
    var slot: ?[]u8 = undefined;
    slot.? = data;
    if (slot) |p| gpa.free(p);
    use(data, gpa);
}

// --- round-3 shapes, as variants ---

pub fn badOnlyIndex(gpa: Allocator) anyerror!void {
    var bufs: [2][]u8 = undefined;
    bufs[0] = try gpa.alloc(u8, 8);
    bufs[1] = try gpa.alloc(u8, 8);
    @memset(bufs[0], 7);
    @memset(bufs[1], 7);
    gpa.free(bufs[0]);
    show(bufs[0][0]);
    gpa.free(bufs[0]);
    gpa.free(bufs[1]);
}

pub fn badKeepFirst(gpa: Allocator) anyerror!void {
    var kept: []u8 = &.{};
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const p = try box(gpa);
        if (i == 0) kept = p;
    }
    gpa.free(kept);
    show(kept[0]);
    gpa.free(kept);
}

fn takeOrFree(p: []u8, gpa: Allocator, ok: bool) !void {
    if (!ok) {
        gpa.free(p);
        return error.Rejected;
    }
}

pub fn badOwnOrFree(gpa: Allocator) anyerror!void {
    const p = try gpa.alloc(u8, 8);
    @memset(p, 7);
    takeOrFree(p, gpa, false) catch {
        show(p[0]);
        gpa.free(p);
        return;
    };
}

fn install(slot: *[]u8, next: []u8, ok: bool) !void {
    if (!ok) return error.Rejected;
    slot.* = next;
}

pub fn badInstallOrDrop(gpa: Allocator) anyerror!void {
    var slot = try gpa.alloc(u8, 8);
    @memset(slot, 0x11);
    const next = try gpa.alloc(u8, 8);
    @memset(next, 0x33);
    install(&slot, next, false) catch {
        show(slot[0]);
        gpa.free(slot);
        gpa.free(next);
        return;
    };
}

pub fn okInstallCleanup(gpa: Allocator) anyerror!void {
    var slot = try gpa.alloc(u8, 8);
    errdefer gpa.free(slot);
    const next = try gpa.alloc(u8, 8);
    errdefer gpa.free(next);
    try install(&slot, next, false);
    gpa.free(slot);
    gpa.free(next);
}

const Entry = struct {
    name: []const u8,
    f: *const fn (Allocator) anyerror!void,
};

const entries = [_]Entry{
    .{ .name = "ctrlOwnedUse", .f = ctrlOwnedUse },
    .{ .name = "okBorrowedUse", .f = okBorrowedUse },
    .{ .name = "ctrlInlineOwned", .f = ctrlInlineOwned },
    .{ .name = "ctrlFieldPtr", .f = ctrlFieldPtr },
    .{ .name = "ctrlAtomicStore", .f = ctrlAtomicStore },
    .{ .name = "ctrlDeinit", .f = ctrlDeinit },
    .{ .name = "okDeinitBorrowed", .f = okDeinitBorrowed },
    .{ .name = "ctrlMutateCopy", .f = ctrlMutateCopy },
    .{ .name = "ctrlList", .f = ctrlList },
    .{ .name = "ctrlReinit", .f = ctrlReinit },
    .{ .name = "ctrlGuardCopy", .f = ctrlGuardCopy },
    .{ .name = "badMemsetKind", .f = badMemsetKind },
    .{ .name = "badByteStore", .f = badByteStore },
    .{ .name = "badAtomicRmw", .f = badAtomicRmw },
    .{ .name = "badCmpxchg", .f = badCmpxchg },
    .{ .name = "badArmTry", .f = badArmTry },
    .{ .name = "badArmFromTrue", .f = badArmFromTrue },
    .{ .name = "badArmLocal", .f = badArmLocal },
    .{ .name = "badErrOnly", .f = badErrOnly },
    .{ .name = "badErrOnlyLocal", .f = badErrOnlyLocal },
    .{ .name = "badDeinitArm", .f = badDeinitArm },
    .{ .name = "okArmSuccess", .f = okArmSuccess },
    .{ .name = "badSetKind", .f = badSetKind },
    .{ .name = "badFnPtr", .f = badFnPtr },
    .{ .name = "badLoopRelease", .f = badLoopRelease },
    .{ .name = "ctrlLoopInline", .f = ctrlLoopInline },
    .{ .name = "badAndLen", .f = badAndLen },
    .{ .name = "badUnionAssign", .f = badUnionAssign },
    .{ .name = "badUnionField", .f = badUnionField },
    .{ .name = "okUnionNone", .f = okUnionNone },
    .{ .name = "okUnionKeep", .f = okUnionKeep },
    .{ .name = "badOptionalSet", .f = badOptionalSet },
    .{ .name = "badOnlyIndex", .f = badOnlyIndex },
    .{ .name = "badKeepFirst", .f = badKeepFirst },
    .{ .name = "badOwnOrFree", .f = badOwnOrFree },
    .{ .name = "badInstallOrDrop", .f = badInstallOrDrop },
    .{ .name = "okInstallCleanup", .f = okInstallCleanup },
};

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
    if (std.mem.eql(u8, name, "badSoftParam")) {
        const r = badSoftParam(gpa, .owned) catch |e| {
            std.debug.print("returned error.{s}\n", .{@errorName(e)});
            return;
        };
        _ = r;
        std.debug.print("returned 0\n", .{});
        return;
    }
    for (entries) |e| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        const r = e.f(gpa) catch |err| {
            std.debug.print("returned error.{s}\n", .{@errorName(err)});
            return;
        };
        _ = r;
        std.debug.print("returned 0\n", .{});
        return;
    }
    std.debug.print("unknown {s}\n", .{name});
}
