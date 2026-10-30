//! Ground truth. A program is run against a tracking allocator that never reuses a block: a freed block is
//! poisoned with 0xAA and kept, so a later read through a stale pointer (which the generated code does only via
//! the rd* helpers) sees the poison, and a free of anything that is not a live block start is caught at the
//! free. The backing allocator is std.heap.DebugAllocator. resize and remap always refuse, so every growth moves
//! and the old block is poisoned: the contract of Allocator allows exactly that, and it makes "stale if the
//! container had no room" deterministic. Every program runs for selv 0..3, and then once per allocation with that
//! allocation failing (std.testing.FailingAllocator), so error paths run.
//! Exit codes: 0 clean, 3 memory fault (message "oracle: ..." or a zv.* ledger panic), 4 any other panic.

const std = @import("std");
const zv = @import("zv");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    name: []const u8,
    run: *const fn (Allocator, u8) anyerror!void,
};

const poison: u8 = 0xAA;

const Block = struct { ptr: [*]u8, len: usize, live: bool };

const Tracker = struct {
    backing: Allocator,
    blocks: std.ArrayList(Block) = .empty,

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn allocator(t: *Tracker) Allocator {
        return .{ .ptr = t, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const t: *Tracker = @ptrCast(@alignCast(ctx));
        const p = t.backing.rawAlloc(len, alignment, ra) orelse return null;
        t.blocks.append(std.heap.page_allocator, .{ .ptr = p, .len = len, .live = true }) catch return null;
        return p;
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const t: *Tracker = @ptrCast(@alignCast(ctx));
        for (t.blocks.items) |*b| {
            if (b.ptr != memory.ptr) continue;
            if (!b.live) @panic("oracle: double free");
            if (b.len != memory.len) @panic("oracle: invalid free (length differs from the allocation)");
            b.live = false;
            @memset(memory, poison);
            return;
        }
        @panic("oracle: invalid free (not a block)");
    }
};

var debug: std.heap.DebugAllocator(.{}) = .init;

fn runOnce(entry: Entry, sel: u8, fail_index: usize) usize {
    zv.resetLedger();
    var failing = std.testing.FailingAllocator.init(debug.allocator(), .{ .fail_index = fail_index });
    var tracker: Tracker = .{ .backing = failing.allocator() };
    entry.run(tracker.allocator(), sel) catch {};
    if (zv.leakedTokens() != 0) @panic("zv.Linear: a token was never consumed");
    return failing.alloc_index;
}

pub fn onPanic(msg: []const u8, _: ?usize) noreturn {
    if (std.mem.startsWith(u8, msg, "oracle: ") or std.mem.startsWith(u8, msg, "zv.")) {
        std.debug.print("FAULT {s}\n", .{msg});
        std.process.exit(3);
    }
    std.debug.print("PANIC {s}\n", .{msg});
    std.process.exit(4);
}

pub fn main(init: std.process.Init, table: []const Entry) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    const entry = table[try std.fmt.parseInt(usize, args[1], 10)];
    for (0..4) |sel| {
        const allocs = runOnce(entry, @intCast(sel), std.math.maxInt(usize));
        for (0..allocs) |fail_index| _ = runOnce(entry, @intCast(sel), fail_index);
    }
    std.debug.print("OK\n", .{});
}
