//! Ownership that depends on a tag: reductions of webzocket's `Buffer`/`Provider`/`Reader` and of rich_zig's `Text`
//! (their verdicts on the real functions are in docs/reviews/own-3.md), and the same shapes with the bug in them.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Buffer = struct {
    data: []u8,
    type: Type,

    const Type = enum { static, pooled, dynamic };
};

pub const Pool = struct {
    buffers: [][]u8,
    available: usize,
    allocator: Allocator,

    pub fn release(self: *Pool, buffer: []u8) void {
        const available = self.available;
        if (available == self.buffers.len) {
            self.allocator.free(buffer);
            return;
        }
        self.buffers[available] = buffer;
        self.available = available + 1;
    }
};

pub const Provider = struct {
    pool: Pool,
    allocator: Allocator,
    pool_buffer_size: usize,
    max_buffer_size: usize,

    pub fn alloc(self: *Provider, size: usize) !Buffer {
        if (size > self.max_buffer_size) return error.TooLarge;
        return .{ .type = .dynamic, .data = try self.allocator.alloc(u8, size) };
    }

    pub fn grow(self: *Provider, buffer: Buffer, current_size: usize, new_size: usize) !Buffer {
        if (new_size > self.max_buffer_size) return error.TooLarge;
        if (buffer.type == .dynamic) {
            var copy = buffer;
            copy.data = try self.allocator.realloc(buffer.data, new_size);
            return copy;
        }
        defer self.release(buffer);
        const new_buffer = try self.alloc(new_size);
        @memcpy(new_buffer.data[0..current_size], buffer.data[0..current_size]);
        return new_buffer;
    }

    pub fn free(self: *Provider, buffer: Buffer) void {
        switch (buffer.type) {
            .pooled => {
                var copy = buffer.data;
                copy.len = self.pool_buffer_size;
                self.pool.release(copy);
            },
            .static => self.allocator.free(buffer.data),
            .dynamic => self.allocator.free(buffer.data),
        }
    }

    pub fn release(self: *Provider, buffer: Buffer) void {
        switch (buffer.type) {
            .static => {},
            .pooled => {
                var copy = buffer.data;
                copy.len = self.pool_buffer_size;
                self.pool.release(copy);
            },
            .dynamic => self.allocator.free(buffer.data),
        }
    }
};

pub const Reader = struct {
    buf: Buffer,
    static: []u8,
    pos: usize,
    start: usize,
    provider: *Provider,

    pub fn init(static: []u8, provider: *Provider) Reader {
        return .{ .pos = 0, .start = 0, .buf = .{ .type = .static, .data = static }, .static = static, .provider = provider };
    }

    pub fn deinit(self: *Reader) void {
        if (self.usingLargeBuffer()) self.provider.release(self.buf);
    }

    pub fn done(self: *Reader) void {
        self.restoreStatic();
    }

    fn restoreStatic(self: *Reader) void {
        if (self.usingLargeBuffer()) {
            self.provider.release(self.buf);
            self.buf = .{ .type = .static, .data = self.static };
            return;
        }
        if (self.start > self.static.len / 2) {
            const data_len = self.pos - self.start;
            std.mem.copyForwards(u8, self.static[0..data_len], self.static[self.start..self.pos]);
            self.pos = data_len;
            self.start = 0;
        }
    }

    pub fn grow(self: *Reader, size: usize) !void {
        const bigger = try self.provider.grow(self.buf, self.pos, size);
        self.buf = bigger;
    }

    inline fn usingLargeBuffer(self: *const Reader) bool {
        return self.buf.type != .static;
    }
};

// A static buffer grown and released: the caller frees the memory it gave, once.
pub fn okStaticGrow(gpa: Allocator, provider: *Provider) !void {
    var buf1 = Buffer{ .type = .static, .data = try gpa.alloc(u8, 15) };
    defer gpa.free(buf1.data);
    @memcpy(buf1.data[0..6], "hello2");
    const buf2 = try provider.grow(buf1, 6, 21);
    defer provider.free(buf2);
    buf1.data[0] = 0;
}

// A reader over a static buffer: `done` gives nothing back, the buffer is the caller's.
pub fn okReaderDone(gpa: Allocator, provider: *Provider) !usize {
    const static = try gpa.alloc(u8, 64);
    defer gpa.free(static);
    var reader = Reader.init(static, provider);
    defer reader.deinit();
    reader.pos = 3;
    reader.done();
    reader.done();
    return static[0] + reader.static.len;
}

// The same reader, grown into a dynamic buffer by `grow`: the static buffer is still the caller's.
pub fn okReaderGrow(gpa: Allocator, provider: *Provider) !usize {
    const static = try gpa.alloc(u8, 64);
    defer gpa.free(static);
    var reader = Reader.init(static, provider);
    defer reader.deinit();
    try reader.grow(128);
    reader.done();
    return static[0];
}

// A dynamic buffer released and then read: the tag says it was freed.
pub fn badDynamicRelease(provider: *Provider) !u8 {
    const buf = try provider.alloc(16);
    provider.release(buf);
    return buf.data[0];
}

// The static buffer freed through `free`, which frees `.static` too: the caller frees it again.
pub fn badStaticFreeTwice(gpa: Allocator, provider: *Provider) !void {
    const buf = Buffer{ .type = .static, .data = try gpa.alloc(u8, 15) };
    provider.free(buf);
    gpa.free(buf.data);
}

// `restoreStatic` released the buffer the reader holds: its tag is not static, so it ends the buffer.
pub fn badReaderDynamic(provider: *Provider, static: []u8) !u8 {
    var reader = Reader.init(static, provider);
    reader.buf = try provider.alloc(16);
    const kept = reader.buf.data;
    reader.done();
    return kept[0];
}

pub const Text = struct {
    plain: []const u8,
    allocator: Allocator,
    owns_plain: bool = false,

    pub fn fromOwned(allocator: Allocator, s: []const u8) !Text {
        return .{ .plain = try allocator.dupe(u8, s), .allocator = allocator, .owns_plain = true };
    }

    pub fn deinit(self: *Text) void {
        if (self.owns_plain and self.plain.len > 0) self.allocator.free(@constCast(self.plain));
        self.* = undefined;
    }

    pub fn slice(self: Text, start: usize, end: usize) Text {
        const actual_end = @min(end, self.plain.len);
        return .{ .plain = self.plain[@min(start, actual_end)..actual_end], .allocator = self.allocator, .owns_plain = false };
    }

    pub fn render(self: Text, gpa: Allocator) ![]u8 {
        return gpa.dupe(u8, self.plain);
    }
};

pub fn okSliceLines(gpa: Allocator, txt: Text) !usize {
    var n: usize = 0;
    for (txt.plain, 0..) |c, idx| {
        if (c == '\n') {
            var line = txt.slice(0, idx);
            defer line.deinit();
            const out = try line.render(gpa);
            defer gpa.free(out);
            n += out.len;
        }
    }
    return n + txt.plain.len;
}

pub fn okOwnedDeinit(gpa: Allocator) !void {
    var t = try Text.fromOwned(gpa, "abc");
    defer t.deinit();
    const out = try t.render(gpa);
    gpa.free(out);
}

// The owner freed and then its slice read.
pub fn badOwnedUse(gpa: Allocator) !u8 {
    var t = try Text.fromOwned(gpa, "abc");
    const view = t.slice(0, 2);
    t.deinit();
    return view.plain[0];
}

// A slice that owns nothing is deinitialized, and the owner read afterwards.
pub fn okSliceThenOwner(gpa: Allocator) !u8 {
    var t = try Text.fromOwned(gpa, "abc");
    defer t.deinit();
    var view = t.slice(0, 2);
    view.deinit();
    return t.plain[0];
}
