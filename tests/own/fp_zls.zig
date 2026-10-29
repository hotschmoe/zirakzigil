// Minimal correct programs distilled from the zls findings. Each function is memory safe (see the comment).
const std = @import("std");

const Handle = struct { name: []const u8 };
const Binding = struct { handle: *Handle, n: u32 };

// FP-A: value (with a pointer field) copied out of a hash-map slot, then the map grows.
pub const Cache = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(u32, ?Binding) = .empty,

    pub fn resolve(c: *Cache, key: u32, h: *Handle) !?Binding {
        const gop = try c.map.getOrPut(c.gpa, key);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = null;
        const b: Binding = .{ .handle = h, .n = key };
        c.map.getPtr(key).?.* = b;
        return b;
    }

    // `a.handle` points at a Handle owned by the caller, not into `map`; the second resolve may rehash `map`.
    pub fn resolveTwice(c: *Cache, h: *Handle) !usize {
        const a = (try c.resolve(1, h)) orelse return 0;
        const b = (try c.resolve(2, h)) orelse return 0;
        return a.handle.name.len + b.n;
    }
};

// FP-B: std.process.run-style result: two slices from two allocations, both freed by the caller.
pub const Out = struct { stdout: []u8, stderr: []u8 };
fn run(gpa: std.mem.Allocator) !Out {
    const o = try gpa.dupe(u8, "out");
    errdefer gpa.free(o);
    const e = try gpa.dupe(u8, "err");
    return .{ .stdout = o, .stderr = e };
}
pub fn runAndFree(gpa: std.mem.Allocator) !usize {
    const r = try run(gpa);
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    return r.stdout.len + r.stderr.len;
}

// FP-C: a by-value struct of owned slices freed field by field.
pub const Pieces = struct {
    a: []const u8,
    b: []const u8,
    pub fn deinit(p: Pieces, gpa: std.mem.Allocator) void {
        gpa.free(p.a);
        gpa.free(p.b);
    }
};

// FP-D: two results of the same allocating helper; one is freed, the other returned.
fn make(gpa: std.mem.Allocator, n: usize) !Pieces {
    const a = try gpa.alloc(u8, n);
    errdefer gpa.free(a);
    return .{ .a = a, .b = try gpa.alloc(u8, n) };
}
pub fn pickLonger(gpa: std.mem.Allocator, n: usize) !Pieces {
    const p1 = try make(gpa, n);
    errdefer p1.deinit(gpa);
    const p2 = try make(gpa, n + 1);
    errdefer p2.deinit(gpa);
    if (p1.a.len > p2.a.len) {
        p2.deinit(gpa);
        return p1;
    } else {
        p1.deinit(gpa);
        return p2;
    }
}

// FP-E: Writer.Allocating handed over to an ArrayList (toArrayList resets the writer), both deinit'ed in defers.
pub fn render(gpa: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, 16);
    defer aw.deinit();
    try aw.writer.writeAll("hello");
    var buffer = aw.toArrayList();
    defer buffer.deinit(gpa);
    buffer.clearRetainingCapacity();
    buffer.appendSliceAssumeCapacity("world");
    return try buffer.toOwnedSlice(gpa);
}

// FP-F: a list declared inside the loop whose items are handed out (arena) every iteration.
pub fn perIteration(arena: std.mem.Allocator, out: *std.ArrayList([]const u8), n: usize) !void {
    for (0..n) |i| {
        var tags: std.ArrayList(u8) = .empty;
        if (i % 2 == 0) try tags.append(arena, 'x');
        try out.append(arena, if (tags.items.len != 0) tags.items else "");
    }
}

// FP-G: `x.* = undefined` poisoning of a field after deinit through an alias.
pub const Lazy = struct {
    value: ?std.ArrayList(u8) = null,
    pub fn deinit(lazy: *Lazy, gpa: std.mem.Allocator) void {
        const v: *std.ArrayList(u8) = if (lazy.value) |*v| v else return;
        v.deinit(gpa);
        lazy.value = undefined;
    }
};

// FP-H: result of a pop from a map is freed; the container itself stays in use.
pub const Queue = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    names: std.ArrayList([]u8) = .empty,
    pub fn drain(q: *Queue, io: std.Io) !void {
        while (true) {
            try q.mutex.lock(io);
            defer q.mutex.unlock(io);
            const name = q.names.pop() orelse break;
            defer q.gpa.free(name);
            _ = name.len;
        }
    }
};
