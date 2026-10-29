//! Labeled switch loops (`continue :sw`), the shape of every modern tokenizer and parser, and a few idioms next to them
//! that the second validation found reported: freeing through an arena's allocator, a result of an indirect call.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Token = struct { kind: u8, start: usize, end: usize };

pub fn okTokenize(gpa: Allocator, src: []const u8) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(gpa);
    var i: usize = 0;
    var start: usize = 0;
    sw: switch (@as(u8, if (src.len == 0) 0 else src[0])) {
        0 => {},
        'a'...'z' => {
            i += 1;
            if (i < src.len) continue :sw src[i];
            try tokens.append(gpa, .{ .kind = 1, .start = start, .end = i });
        },
        ' ' => {
            try tokens.append(gpa, .{ .kind = 1, .start = start, .end = i });
            i += 1;
            start = i;
            if (i < src.len) continue :sw src[i];
        },
        else => {
            i += 1;
            if (i < src.len) continue :sw src[i];
        },
    }
    return tokens.toOwnedSlice(gpa);
}

pub fn badTokenizeStale(gpa: Allocator, src: []const u8) !u8 {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(gpa);
    try tokens.append(gpa, .{ .kind = 0, .start = 0, .end = 0 });
    const first = &tokens.items[0];
    var i: usize = 0;
    sw: switch (@as(u8, if (src.len == 0) 0 else src[0])) {
        0 => {},
        else => {
            i += 1;
            try tokens.append(gpa, .{ .kind = 1, .start = i, .end = i });
            if (i < src.len) continue :sw src[i];
        },
    }
    return first.kind;
}

pub fn badFreeInSwitchLoop(gpa: Allocator, src: []const u8) !void {
    const buf = try gpa.alloc(u8, 8);
    var i: usize = 0;
    sw: switch (@as(u8, if (src.len == 0) 0 else src[0])) {
        0 => {},
        else => {
            gpa.free(buf);
            i += 1;
            if (i < src.len) continue :sw src[i];
        },
    }
}

pub fn okFreeThroughArena(gpa: Allocator) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const x = try a.alloc(u8, 4);
    x[0] = 1;
    a.free(x);
    const y = try a.alloc(u8, 4);
    y[0] = 2;
    return y[0];
}

const Source = struct {
    items: []const u32,
    fn at(p: *const anyopaque, i: usize) ?*const u32 {
        const s: *const Source = @ptrCast(@alignCast(p));
        if (i >= s.items.len) return null;
        return &s.items[i];
    }
};

pub fn okIndirectResult(items: []const u32, f: *const fn (*const anyopaque, usize) ?*const u32) ?*const u32 {
    const s: Source = .{ .items = items };
    _ = f(&s, 0);
    return Source.at(&s, 0);
}

pub fn okIndirectKeeps(items: []const u32, f: *const fn (*const anyopaque, usize) ?*const u32) u32 {
    const s: Source = .{ .items = items };
    const got = f(&s, 0) orelse return 0;
    return got.*;
}
