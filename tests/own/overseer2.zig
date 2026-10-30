//! Overseer probes, set 2: how wide are the two silent classes of set 1 (frees through globals, frees of a
//! by-value optional parameter)?
const std = @import("std");
const Allocator = std.mem.Allocator;

fn show(byte: u8) void {
    std.debug.print("byte {d}\n", .{byte});
    std.mem.doNotOptimizeAway(byte);
}

// A. Optional by value, variants.
const Node = struct { v: u8 };

fn destroyOpt(gpa: Allocator, n: ?*Node) void {
    if (n) |p| gpa.destroy(p);
}

pub fn badOptionalPtrCallee(gpa: Allocator) !void {
    const n = try gpa.create(Node);
    n.* = .{ .v = 7 };
    destroyOpt(gpa, n);
    show(n.v);
}

const OptHolder = struct { data: ?[]u8 };

fn dropHolder(gpa: Allocator, h: OptHolder) void {
    if (h.data) |d| gpa.free(d);
}

pub fn badOptionalFieldByValue(gpa: Allocator) !void {
    const h: OptHolder = .{ .data = try gpa.alloc(u8, 8) };
    @memset(h.data.?, 7);
    dropHolder(gpa, h);
    show(h.data.?[0]);
}

fn dropOptPtr(gpa: Allocator, o: *?[]u8) void {
    if (o.*) |b| gpa.free(b);
}

pub fn ctrlOptionalThroughPtr(gpa: Allocator) !void {
    var o: ?[]u8 = try gpa.alloc(u8, 8);
    @memset(o.?, 7);
    dropOptPtr(gpa, &o);
    show(o.?[0]);
}

fn dropOptOrElse(gpa: Allocator, o: ?[]u8) void {
    const b = o orelse return;
    gpa.free(b);
}

pub fn badOptionalOrelse(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 8);
    @memset(buf, 7);
    dropOptOrElse(gpa, buf);
    show(buf[0]);
}

fn dropOptUnwrap(gpa: Allocator, o: ?[]u8) void {
    gpa.free(o.?);
}

pub fn ctrlOptionalUnwrap(gpa: Allocator) !void {
    const buf = try gpa.alloc(u8, 8);
    @memset(buf, 7);
    dropOptUnwrap(gpa, buf);
    show(buf[0]);
}

// B. Globals, variants.
const State = struct {
    buf: []u8 = &.{},
    list: std.ArrayList(u8) = .empty,

    fn deinit(self: *State, gpa: Allocator) void {
        gpa.free(self.buf);
        self.list.deinit(gpa);
        self.* = .{};
    }
};

var state: State = .{};

pub fn badGlobalStructDeinit(gpa: Allocator) !void {
    state.buf = try gpa.alloc(u8, 8);
    @memset(state.buf, 7);
    const keep = state.buf;
    state.deinit(gpa);
    show(keep[0]);
}

var glist: std.ArrayList(u8) = .empty;

pub fn badGlobalListGrow(gpa: Allocator) !void {
    defer glist.deinit(gpa);
    try glist.append(gpa, 7);
    const items = glist.items;
    try glist.appendNTimes(gpa, 1, 4096);
    show(items[0]);
}

pub fn badGlobalListDeinit(gpa: Allocator) !void {
    try glist.append(gpa, 7);
    const items = glist.items;
    glist.deinit(gpa);
    glist = .empty;
    show(items[0]);
}

const Entry = struct { name: []const u8, f: *const fn (Allocator) anyerror!void };
const entries = [_]Entry{
    .{ .name = "badOptionalPtrCallee", .f = badOptionalPtrCallee },
    .{ .name = "badOptionalFieldByValue", .f = badOptionalFieldByValue },
    .{ .name = "ctrlOptionalThroughPtr", .f = ctrlOptionalThroughPtr },
    .{ .name = "badOptionalOrelse", .f = badOptionalOrelse },
    .{ .name = "ctrlOptionalUnwrap", .f = ctrlOptionalUnwrap },
    .{ .name = "badGlobalStructDeinit", .f = badGlobalStructDeinit },
    .{ .name = "badGlobalListGrow", .f = badGlobalListGrow },
    .{ .name = "badGlobalListDeinit", .f = badGlobalListDeinit },
};

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(std.heap.page_allocator) catch return;
    if (args.len < 2) return;
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
