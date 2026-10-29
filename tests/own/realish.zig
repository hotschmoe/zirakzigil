//! A small allocator-heavy program written without the checker in mind: a lexer and parser for a tiny
//! configuration language, an interning symbol table, an LRU cache over indices, a buffered writer, and a
//! free-list of nodes. Every function is correct; tests/own/realish.expect pins them all clean, so a new
//! false positive on code like this fails the suite.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TokenKind = enum { ident, number, string, equals, lbrace, rbrace, newline, eof };

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: u32,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src };
    }

    fn peek(self: *const Lexer) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    pub fn next(self: *Lexer) Token {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\r') self.pos += 1 else break;
        }
        const start = self.pos;
        const c = self.peek() orelse return .{ .kind = .eof, .text = "", .line = self.line };
        self.pos += 1;
        switch (c) {
            '=' => return .{ .kind = .equals, .text = self.src[start..self.pos], .line = self.line },
            '{' => return .{ .kind = .lbrace, .text = self.src[start..self.pos], .line = self.line },
            '}' => return .{ .kind = .rbrace, .text = self.src[start..self.pos], .line = self.line },
            '\n' => {
                const t: Token = .{ .kind = .newline, .text = self.src[start..self.pos], .line = self.line };
                self.line += 1;
                return t;
            },
            '"' => {
                while (self.peek()) |d| {
                    self.pos += 1;
                    if (d == '"') break;
                }
                return .{ .kind = .string, .text = self.src[start + 1 .. self.pos -| 1], .line = self.line };
            },
            else => {
                while (self.peek()) |d| {
                    if (std.ascii.isAlphanumeric(d) or d == '_' or d == '.') self.pos += 1 else break;
                }
                const text = self.src[start..self.pos];
                const kind: TokenKind = if (std.ascii.isDigit(c)) .number else .ident;
                return .{ .kind = kind, .text = text, .line = self.line };
            },
        }
    }
};

pub const Value = union(enum) {
    number: i64,
    string: []const u8,
    table: *Table,
};

pub const Entry = struct { key: []const u8, value: Value };

pub const Table = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Table, gpa: Allocator) void {
        for (self.entries.items) |e| switch (e.value) {
            .table => |t| {
                t.deinit(gpa);
                gpa.destroy(t);
            },
            .string => |s| gpa.free(s),
            .number => {},
        };
        for (self.entries.items) |e| gpa.free(e.key);
        self.entries.deinit(gpa);
    }

    pub fn find(self: *const Table, key: []const u8) ?*const Value {
        for (self.entries.items) |*e| if (std.mem.eql(u8, e.key, key)) return &e.value;
        return null;
    }

    pub fn put(self: *Table, gpa: Allocator, key: []const u8, value: Value) !void {
        const owned = try gpa.dupe(u8, key);
        errdefer gpa.free(owned);
        try self.entries.append(gpa, .{ .key = owned, .value = value });
    }
};

pub const ParseError = error{ OutOfMemory, Unexpected, BadNumber };

pub const Parser = struct {
    lexer: Lexer,
    current: Token,

    pub fn init(src: []const u8) Parser {
        var lexer = Lexer.init(src);
        const first = lexer.next();
        return .{ .lexer = lexer, .current = first };
    }

    fn advance(self: *Parser) Token {
        const t = self.current;
        self.current = self.lexer.next();
        return t;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.current.kind == .newline) _ = self.advance();
    }

    pub fn parseTable(self: *Parser, gpa: Allocator, top: bool) ParseError!*Table {
        const table = try gpa.create(Table);
        table.* = .{};
        errdefer {
            table.deinit(gpa);
            gpa.destroy(table);
        }
        while (true) {
            self.skipNewlines();
            switch (self.current.kind) {
                .eof => if (top) break else return error.Unexpected,
                .rbrace => if (top) return error.Unexpected else break,
                .ident => {
                    const key = self.advance();
                    if (self.advance().kind != .equals) return error.Unexpected;
                    const value = try self.parseValue(gpa);
                    errdefer freeValue(gpa, value);
                    try table.put(gpa, key.text, value);
                },
                else => return error.Unexpected,
            }
        }
        if (!top) _ = self.advance();
        return table;
    }

    fn parseValue(self: *Parser, gpa: Allocator) ParseError!Value {
        const t = self.advance();
        switch (t.kind) {
            .number => return .{ .number = std.fmt.parseInt(i64, t.text, 10) catch return error.BadNumber },
            .string => return .{ .string = try gpa.dupe(u8, t.text) },
            .lbrace => return .{ .table = try self.parseTable(gpa, false) },
            else => return error.Unexpected,
        }
    }
};

fn freeValue(gpa: Allocator, v: Value) void {
    switch (v) {
        .string => |s| gpa.free(s),
        .table => |t| {
            t.deinit(gpa);
            gpa.destroy(t);
        },
        .number => {},
    }
}

/// Interns strings: equal text, one allocation.
pub const Interner = struct {
    map: std.StringHashMapUnmanaged(void) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator) Interner {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Interner, gpa: Allocator) void {
        self.map.deinit(gpa);
        self.arena.deinit();
    }

    pub fn intern(self: *Interner, gpa: Allocator, text: []const u8) ![]const u8 {
        const gop = try self.map.getOrPut(gpa, text);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.arena.allocator().dupe(u8, text);
        }
        return gop.key_ptr.*;
    }
};

/// A fixed-capacity cache that evicts the entry used longest ago.
pub fn Lru(comptime V: type, comptime capacity: usize) type {
    return struct {
        keys: [capacity]u32 = undefined,
        values: [capacity]V = undefined,
        stamp: [capacity]u64 = @splat(0),
        used: [capacity]bool = @splat(false),
        clock: u64 = 0,

        const Self = @This();

        pub fn get(self: *Self, key: u32) ?*V {
            for (0..capacity) |i| {
                if (self.used[i] and self.keys[i] == key) {
                    self.clock += 1;
                    self.stamp[i] = self.clock;
                    return &self.values[i];
                }
            }
            return null;
        }

        pub fn put(self: *Self, key: u32, value: V) void {
            var victim: usize = 0;
            for (0..capacity) |i| {
                if (!self.used[i]) {
                    victim = i;
                    break;
                }
                if (self.stamp[i] < self.stamp[victim]) victim = i;
            }
            self.clock += 1;
            self.keys[victim] = key;
            self.values[victim] = value;
            self.stamp[victim] = self.clock;
            self.used[victim] = true;
        }
    };
}

pub const Out = struct {
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Out, gpa: Allocator) void {
        self.bytes.deinit(gpa);
    }

    pub fn print(self: *Out, gpa: Allocator, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(gpa, fmt, args);
        defer gpa.free(text);
        try self.bytes.appendSlice(gpa, text);
    }

    pub fn takeOwned(self: *Out, gpa: Allocator) ![]u8 {
        return self.bytes.toOwnedSlice(gpa);
    }
};

pub fn render(gpa: Allocator, table: *const Table, depth: usize) ![]u8 {
    var out: Out = .{};
    errdefer out.deinit(gpa);
    for (table.entries.items) |e| {
        try out.bytes.appendNTimes(gpa, ' ', depth * 2);
        try out.print(gpa, "{s} = ", .{e.key});
        switch (e.value) {
            .number => |n| try out.print(gpa, "{d}\n", .{n}),
            .string => |s| try out.print(gpa, "\"{s}\"\n", .{s}),
            .table => |t| {
                const inner = try render(gpa, t, depth + 1);
                defer gpa.free(inner);
                try out.print(gpa, "{{\n{s}}}\n", .{inner});
            },
        }
    }
    return out.takeOwned(gpa);
}

pub fn lookupPath(table: *const Table, path: []const u8) ?*const Value {
    var current = table;
    var it = std.mem.splitScalar(u8, path, '.');
    var found: ?*const Value = null;
    while (it.next()) |part| {
        found = current.find(part) orelse return null;
        switch (found.?.*) {
            .table => |t| current = t,
            else => {},
        }
    }
    return found;
}

pub fn countEntries(table: *const Table) usize {
    var n: usize = 0;
    for (table.entries.items) |e| {
        n += 1;
        switch (e.value) {
            .table => |t| n += countEntries(t),
            else => {},
        }
    }
    return n;
}

pub fn loadAndRender(gpa: Allocator, src: []const u8) ![]u8 {
    var parser = Parser.init(src);
    const table = try parser.parseTable(gpa, true);
    defer {
        table.deinit(gpa);
        gpa.destroy(table);
    }
    return render(gpa, table, 0);
}

pub fn internAll(gpa: Allocator, names: []const []const u8) !usize {
    var interner = Interner.init(gpa);
    defer interner.deinit(gpa);
    var distinct: usize = 0;
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(gpa);
    for (names) |name| {
        const canonical = try interner.intern(gpa, name);
        var fresh = true;
        for (seen.items) |s| if (s.ptr == canonical.ptr) {
            fresh = false;
        };
        if (fresh) {
            try seen.append(gpa, canonical);
            distinct += 1;
        }
    }
    return distinct;
}

pub fn cacheDemo() u32 {
    var cache: Lru(u32, 4) = .{};
    var i: u32 = 0;
    while (i < 10) : (i += 1) cache.put(i, i * i);
    const hit = cache.get(9) orelse return 0;
    return hit.*;
}
