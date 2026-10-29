//! One-line mutations of tests/own/realish.zig: the mistakes people actually make in code like it. Each
//! function is the original with the edit named in its comment; tests/own/realish_bugs.expect pins the verdict.

const std = @import("std");
const base = @import("realish.zig");
const Allocator = std.mem.Allocator;
const Table = base.Table;
const Value = base.Value;
const Parser = base.Parser;

/// render, with the inner buffer freed once too often.
pub fn badRenderDoubleFree(gpa: Allocator, table: *const Table) ![]u8 {
    var out: base.Out = .{};
    errdefer out.deinit(gpa);
    for (table.entries.items) |e| switch (e.value) {
        .table => |t| {
            const inner = try base.render(gpa, t, 1);
            defer gpa.free(inner);
            try out.print(gpa, "{s}", .{inner});
            gpa.free(inner);
        },
        else => {},
    };
    return out.takeOwned(gpa);
}

/// Out.print, appending after the text was freed.
pub fn badPrintAfterFree(out: *base.Out, gpa: Allocator, n: u32) !void {
    const text = try std.fmt.allocPrint(gpa, "{d}", .{n});
    gpa.free(text);
    try out.bytes.appendSlice(gpa, text);
}

/// loadAndRender, rendering the table after it was destroyed.
pub fn badRenderAfterDestroy(gpa: Allocator, src: []const u8) ![]u8 {
    var parser = Parser.init(src);
    const table = try parser.parseTable(gpa, true);
    table.deinit(gpa);
    gpa.destroy(table);
    return base.render(gpa, table, 0);
}

/// Table.find followed by put: the pointer into the entries is stale after the append.
pub fn badFindThenPut(table: *Table, gpa: Allocator, key: []const u8) !i64 {
    const existing = table.find(key) orelse return 0;
    try table.put(gpa, "other", .{ .number = 1 });
    return switch (existing.*) {
        .number => |n| n,
        else => 0,
    };
}

/// lookupPath, returning a pointer to a local copy of the value.
pub fn badLookupReturnsLocal(table: *const Table, key: []const u8) ?*const Value {
    const found = table.find(key) orelse return null;
    var copy = found.*;
    _ = &copy;
    return same(&copy);
}

fn same(v: *const Value) *const Value {
    return v;
}

/// internAll, handing back the canonical pointer after the interner was torn down. The pointer comes out of a
/// hash map slot the checker does not follow: a gap, pinned as clean.
pub fn gapInternedAfterDeinit(gpa: Allocator, name: []const u8) !u8 {
    var interner = base.Interner.init(gpa);
    const canonical = try interner.intern(gpa, name);
    interner.deinit(gpa);
    return canonical[0];
}

/// Table.put, freeing the key that the entry now owns. What a container holds is not followed: a gap.
pub fn gapPutFreesOwnedKey(self: *Table, gpa: Allocator, key: []const u8, value: Value) !u8 {
    const owned = try gpa.dupe(u8, key);
    try self.entries.append(gpa, .{ .key = owned, .value = value });
    gpa.free(owned);
    return self.entries.items[self.entries.items.len - 1].key[0];
}

/// The cache pointer outliving a put that evicts: the slot is reused.
pub fn okLruPointerWithinCall() u32 {
    var cache: base.Lru(u32, 2) = .{};
    cache.put(1, 10);
    const hit = cache.get(1) orelse return 0;
    return hit.*;
}

/// Parser.parseTable, the temporary table never freed on the error path (a leak the debug allocator finds,
/// not this checker: pinned clean so the boundary is visible).
pub fn gapLeakOnErrorPath(gpa: Allocator, src: []const u8) !usize {
    var parser = Parser.init(src);
    const table = try parser.parseTable(gpa, true);
    if (table.entries.items.len == 0) return error.Unexpected;
    table.deinit(gpa);
    gpa.destroy(table);
    return 1;
}
