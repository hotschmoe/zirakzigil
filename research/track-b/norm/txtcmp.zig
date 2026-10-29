//! How much of schema v1 can be recovered from the compiler's own AIR printer text?
//! usage: txtcmp V1_DIR TXT_DIR
//! Pairs files by function name (only names that occur once on both sides), flattens both in
//! print order, and compares ids, tags and instruction operands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Json = std.json.Value;

const Flat = struct {
    id: i64,
    tag: []const u8,
    refs: []i64,
    has_const: bool,
};

fn stemOf(name: []const u8) []const u8 {
    const end = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    const mid = std.mem.lastIndexOfScalar(u8, name[0..end], '.') orelse return name;
    return name[0..mid];
}

fn flattenJson(arena: Allocator, out: *std.ArrayList(Flat), insts: []const Json) Allocator.Error!void {
    for (insts) |inst| {
        var refs: std.ArrayList(i64) = .empty;
        var has_const = false;
        if (inst.object.get("operands")) |ops| for (ops.array.items) |op| {
            if (op == .object) {
                if (op.object.get("inst")) |i| try refs.append(arena, i.integer) else has_const = true;
            }
        };
        if (inst.object.get("attrs")) |attrs| if (attrs.object.get("target")) |t| try refs.append(arena, t.integer);
        try out.append(arena, .{ .id = inst.object.get("id").?.integer, .tag = inst.object.get("tag").?.string, .refs = refs.items, .has_const = has_const });
        if (inst.object.get("bodies")) |bodies| for (bodies.array.items) |b| {
            try flattenJson(arena, out, b.object.get("insts").?.array.items);
        };
    }
}

fn flattenText(arena: Allocator, out: *std.ArrayList(Flat), text: []const u8) Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " ");
        if (line.len < 4 or line[0] != '%') continue;
        var i: usize = 1;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        const id = std.fmt.parseInt(i64, line[1..i], 10) catch continue;
        const eq = std.mem.indexOf(u8, line[i..], "= ") orelse continue;
        const rest = line[i + eq + 2 ..];
        const paren = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
        const tag = rest[0..paren];
        const args = rest[paren..];
        var refs: std.ArrayList(i64) = .empty;
        var has_const = false;
        var k: usize = 0;
        while (k < args.len) : (k += 1) {
            if (args[k] == '<') has_const = true;
            if (args[k] == '%') {
                var e = k + 1;
                while (e < args.len and std.ascii.isDigit(args[e])) e += 1;
                if (e > k + 1) try refs.append(arena, std.fmt.parseInt(i64, args[k + 1 .. e], 10) catch continue);
                k = e - 1;
            }
        }
        try out.append(arena, .{ .id = id, .tag = tag, .refs = refs.items, .has_const = has_const });
    }
}

fn lessThan(_: void, a: i64, b: i64) bool {
    return a < b;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) std.process.exit(2);
    const cwd = std.Io.Dir.cwd();
    var v1_dir = try cwd.openDir(io, args[1], .{ .iterate = true });
    var txt_dir = try cwd.openDir(io, args[2], .{ .iterate = true });

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var v1_names: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    var txt_names: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    inline for (.{ .{ &v1_dir, &v1_names }, .{ &txt_dir, &txt_names } }) |pair| {
        var it = pair[0].iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .file) continue;
            const stem = stemOf(e.name);
            const gop = try pair[1].getOrPut(arena, try arena.dupe(u8, stem));
            gop.value_ptr.* = if (gop.found_existing) null else try arena.dupe(u8, e.name);
        }
    }

    var files: usize = 0;
    var skipped: usize = 0;
    var insts: usize = 0;
    var count_mismatch: usize = 0;
    var tag_mismatch: usize = 0;
    var ref_mismatch: usize = 0;
    var const_mismatch: usize = 0;
    var tag_examples: std.StringHashMapUnmanaged(usize) = .empty;
    var it = v1_names.iterator();
    while (it.next()) |entry| {
        const v1_name = entry.value_ptr.* orelse {
            skipped += 1;
            continue;
        };
        const txt_name = (txt_names.get(entry.key_ptr.*) orelse {
            skipped += 1;
            continue;
        }) orelse {
            skipped += 1;
            continue;
        };
        const v1_bytes = try v1_dir.readFileAlloc(io, v1_name, arena, .limited(1 << 30));
        const txt_bytes = try txt_dir.readFileAlloc(io, txt_name, arena, .limited(1 << 30));
        const root = try std.json.parseFromSliceLeaky(Json, arena, v1_bytes, .{});
        var a: std.ArrayList(Flat) = .empty;
        var b: std.ArrayList(Flat) = .empty;
        try flattenJson(arena, &a, root.object.get("insts").?.array.items);
        try flattenText(arena, &b, txt_bytes);
        files += 1;
        if (a.items.len != b.items.len) {
            count_mismatch += 1;
            continue;
        }
        for (a.items, b.items) |x, y| {
            insts += 1;
            if (x.id != y.id or !std.mem.eql(u8, x.tag, y.tag)) {
                tag_mismatch += 1;
                continue;
            }
            std.mem.sort(i64, x.refs, {}, lessThan);
            std.mem.sort(i64, y.refs, {}, lessThan);
            if (!std.mem.eql(i64, x.refs, y.refs)) {
                ref_mismatch += 1;
                const gop = try tag_examples.getOrPut(arena, x.tag);
                gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
            }
            if (x.has_const != y.has_const) const_mismatch += 1;
        }
    }
    std.debug.print("compared {d} functions, skipped {d}; {d} instructions; count mismatch {d}, id/tag mismatch {d}, operand-ref mismatch {d}, const-presence mismatch {d}\n", .{ files, skipped, insts, count_mismatch, tag_mismatch, ref_mismatch, const_mismatch });
}
