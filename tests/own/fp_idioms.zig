//! Minimal reductions of the false positives zv-own reported on libvaxis / webzocket / rich_zig.
//! Every function here is correct code (the `test` block at the bottom runs them under std.testing.allocator).
//! Export + check: run_check.sh (WSL, patched compiler), then zv-own on the pack.
const std = @import("std");
const Allocator = std.mem.Allocator;

// ---- FP1: copy of a struct, one field overwritten with a fresh allocation (webzocket buffer.Provider.grow, libvaxis Loop._ttyRun)
pub const Buffer = struct { data: []u8, kind: u8 };
pub fn fp1GrowCopy(a: Allocator, buffer: Buffer, n: usize) !Buffer {
    var copy = buffer;
    copy.data = try a.realloc(buffer.data, n);
    return copy;
}

// ---- FP2: builder chain returning *Self (rich_zig Table.addColumn(..).addColumn(..))
pub const Table = struct {
    cols: std.ArrayList(u32) = .empty,
    a: Allocator,
    pub fn addColumn(self: *Table, c: u32) *Table {
        self.cols.append(self.a, c) catch {};
        return self;
    }
    pub fn deinit(self: *Table) void {
        self.cols.deinit(self.a);
    }
};
pub fn fp2Chain(a: Allocator) void {
    var t: Table = .{ .a = a };
    defer t.deinit();
    _ = t.addColumn(1).addColumn(2).addColumn(3);
}

// ---- FP3: callee appends to a field and returns a slice of it; the caller returns the callee's result (libvaxis widgets.terminal.Parser.parseReader)
pub const P = struct {
    buf: std.ArrayList(u8) = .empty,
    a: Allocator,
    fn inner(self: *P, b: u8) ![]const u8 {
        try self.buf.append(self.a, b);
        return self.buf.items;
    }
    pub fn outer(self: *P, b: u8) ![]const u8 {
        self.buf.clearRetainingCapacity();
        if (b > 10) return self.inner(b);
        return self.inner(b + 1);
    }
};

// ---- FP4: guarded free + set optional to null; later deinit is guarded the same way (webzocket Reader.done / Reader.deinit)
pub const R = struct {
    a: Allocator,
    held: ?[]u8 = null,
    pub fn done(self: *R) void {
        if (self.held) |h| {
            self.a.free(h);
            self.held = null;
        }
    }
    pub fn deinit(self: *R) void {
        if (self.held) |h| self.a.free(h);
    }
};
pub fn fp4(a: Allocator) !void {
    var r: R = .{ .a = a, .held = try a.alloc(u8, 4) };
    defer r.deinit();
    r.done();
}

// ---- FP5: cleanup loop over elements with a pointer capture (libvaxis widgets.terminal.Screen.init errdefer)
pub const Cell = struct { l: std.ArrayList(u8) = .empty, m: std.ArrayList(u8) = .empty };
pub fn fp5(a: Allocator, n: usize) ![]Cell {
    const buf = try a.alloc(Cell, n);
    var initialized: usize = 0;
    errdefer {
        for (buf[0..initialized]) |*cell| {
            cell.l.deinit(a);
            cell.m.deinit(a);
        }
        a.free(buf);
    }
    for (buf) |*c| {
        c.* = .{};
        try c.l.append(a, ' ');
        initialized += 1;
    }
    return buf;
}

// ---- FP6: allocate; on failure free and return a sentinel, else return the allocation; the caller returns the callee's result (libvaxis Parser.parse / parseOsc)
pub const Res = struct { text: ?[]u8 };
fn parseOsc(a: Allocator, ok: bool) !Res {
    const text = try a.alloc(u8, 8);
    if (!ok) {
        a.free(text);
        return .{ .text = null };
    }
    return .{ .text = text };
}
pub fn fp6(a: Allocator, ok: bool, sel: u8) !Res {
    switch (sel) {
        1 => return parseOsc(a, ok),
        else => return .{ .text = null },
    }
}

// ---- FP7: value read from an arena field that is NOT arena memory (child_allocator), used after arena.deinit() (libvaxis c_api GraphemeStore.compact)
pub fn fp7(parent: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(parent);
    const child = arena.child_allocator;
    const copies = try child.alloc(u8, 4);
    arena.deinit();
    child.free(copies);
}

// ---- FP8: re-initialize an object after deinit: `self.deinit(); self.* = next;` (libvaxis c_api GraphemeStore.compact)
pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    pub fn init(a: Allocator) Store {
        return .{ .arena = .init(a) };
    }
    pub fn deinit(self: *Store) void {
        self.arena.deinit();
    }
    pub fn compact(self: *Store) !void {
        var next = Store.init(self.arena.child_allocator);
        errdefer next.deinit();
        _ = try next.arena.allocator().alloc(u8, 3);
        self.deinit();
        self.* = next;
    }
};

// ---- FP9: toOwnedSlice then the deferred deinit of the (now empty) writer (libvaxis Vaxis.zig test "render: no output when no changes")
pub fn fp9(a: Allocator) !void {
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();
    try w.writer.writeAll("x");
    const out = try w.toOwnedSlice();
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

// ---- FP10: callback with a userdata pointer to a local context (libvaxis vxfw ListView.draw / ScrollView.draw)
pub const Builder = struct {
    userdata: *const anyopaque,
    buildFn: *const fn (*const anyopaque, usize) ?*const u32,
};
const Slice = struct {
    items: []const u32,
    fn build(p: *const anyopaque, i: usize) ?*const u32 {
        const s: *const Slice = @ptrCast(@alignCast(p));
        if (i >= s.items.len) return null;
        return &s.items[i];
    }
};
fn drawBuilder(b: Builder) ?*const u32 {
    return b.buildFn(b.userdata, 0);
}
pub fn fp10(items: []const u32) ?*const u32 {
    const s: Slice = .{ .items = items };
    return drawBuilder(.{ .userdata = &s, .buildFn = Slice.build });
}

// ---- FP11: spawn a thread per iteration with a freshly allocated argument; errdefer frees it; outer errdefer joins the earlier ones (webzocket ThreadPool.init)
fn worker(a: Allocator, buf: []u8) void {
    a.free(buf);
}
pub fn fp11(a: Allocator, threads: []std.Thread) !void {
    var started: usize = 0;
    errdefer for (0..started) |i| threads[i].join();
    for (0..threads.len) |i| {
        const buffer = try a.alloc(u8, 16);
        errdefer a.free(buffer);
        threads[i] = try std.Thread.spawn(.{}, worker, .{ a, buffer });
        started += 1;
    }
}

// ---- FP12: a struct returned from a method of `self`, then another field's container is mutated (rich_zig Console.writeLine, libvaxis Terminal._run)
pub const Console = struct {
    a: Allocator,
    cap: ?std.ArrayList(u8) = null,
    scratch: []u8,
    const W = struct { buf: []u8, n: usize = 0 };
    fn getWriter(self: *Console) W {
        return .{ .buf = self.scratch };
    }
    pub fn writeLine(self: *Console) !void {
        var w = self.getWriter();
        w.n += 1;
        if (self.cap) |*c| try c.append(self.a, '\n');
        w.n += 1;
        w.buf[0] = 1;
    }
};

// ---- FP13: helper taking a slice of a growing list, returning a struct that has a slice field copied from another arg (rich_zig ansi.fromAnsi / applySgr)
pub const Style = struct { n: u16 = 0, link: ?[]const u8 = null };
fn applySgr(base: Style, params: []const u16) Style {
    var s = base;
    for (params) |p| s.n +%= p;
    return s;
}
pub fn fp13(a: Allocator, input: []const u8) !u16 {
    var cur: Style = .{};
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        var params: std.ArrayList(u16) = .empty;
        defer params.deinit(a);
        try params.append(a, input[i]);
        try params.append(a, 1);
        cur = applySgr(cur, params.items);
    }
    return cur.n;
}


// ---- FP2b: the same chain, two levels like rich_zig's Table.addColumn -> withColumn
pub const Table2 = struct {
    cols: std.ArrayList(u32) = .empty,
    a: Allocator,
    pub fn withColumn(self: *Table2, c: u32) *Table2 {
        self.cols.append(self.a, c) catch {};
        return self;
    }
    pub fn addColumn(self: *Table2, c: u32) *Table2 {
        return self.withColumn(c + 1);
    }
    pub fn deinit(self: *Table2) void {
        self.cols.deinit(self.a);
    }
};
pub fn fp2bChain(a: Allocator) void {
    var t: Table2 = .{ .a = a };
    defer t.deinit();
    _ = t.addColumn(1).addColumn(2).addColumn(3);
}

// ---- FP4b: webzocket's shape: the optional holds a struct with a buffer and a provider pointer; done() deinit-s and nulls it
pub const Prov = struct { a: Allocator };
pub const Wr = struct {
    buf: []u8,
    provider: *Prov,
    pub fn deinit(self: *Wr) void {
        self.provider.a.free(self.buf);
    }
};
pub const Rd = struct {
    wr: ?Wr = null,
    pos: usize = 0,
    pub fn done(self: *Rd) void {
        if (self.wr) |*w| {
            w.deinit();
            self.wr = null;
        }
    }
    pub fn deinit(self: *Rd) void {
        if (self.wr) |*w| w.deinit();
    }
    pub fn isEmpty(self: *const Rd) bool {
        return self.pos == 0;
    }
};
pub fn fp4b(a: Allocator) !void {
    var prov: Prov = .{ .a = a };
    var rd: Rd = .{ .wr = .{ .buf = try a.alloc(u8, 4), .provider = &prov } };
    defer rd.deinit();
    rd.done();
    _ = rd.isEmpty();
}

test "chains and guarded frees" {
    const a = std.testing.allocator;
    fp2bChain(a);
    try fp4b(a);
}

test "all of the above are correct" {
    const a = std.testing.allocator;
    {
        const b = try a.alloc(u8, 2);
        const g = try fp1GrowCopy(a, .{ .data = b, .kind = 0 }, 5);
        a.free(g.data);
    }
    fp2Chain(a);
    {
        var p: P = .{ .a = a };
        defer p.buf.deinit(a);
        _ = try p.outer(3);
    }
    try fp4(a);
    {
        const c = try fp5(a, 3);
        for (c) |*x| {
            x.l.deinit(a);
            x.m.deinit(a);
        }
        a.free(c);
    }
    {
        const r = try fp6(a, true, 1);
        if (r.text) |t| a.free(t);
    }
    try fp7(a);
    {
        var s = Store.init(a);
        defer s.deinit();
        try s.compact();
    }
    try fp9(a);
    _ = fp10(&.{ 1, 2 });
    {
        var buf: [1]u8 = .{0};
        var c: Console = .{ .a = a, .cap = .empty, .scratch = &buf };
        defer c.cap.?.deinit(a);
        try c.writeLine();
    }
    try std.testing.expectEqual(@as(u16, 0), 0 * try fp13(a, "ab"));
    {
        var ts: [2]std.Thread = undefined;
        try fp11(a, &ts);
        for (&ts) |*t| t.join();
    }
}
