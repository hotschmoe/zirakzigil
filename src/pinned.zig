//! Pinned counterexamples: the regression corpus of a `laws` namespace.
//!
//! A law namespace may declare exact argument tuples that every run replays
//! before any random case, independent of the generators:
//!
//!     pub const pinned = .{
//!         .acceptedMeansComplete = .{
//!             .{ "\x00\x00\x00\x00\x00\x00\x00" }, // one tuple per case
//!         },
//!     };
//!
//! This file holds the three mechanical halves of that feature, none of which
//! knows about the drivers in `laws.zig`:
//!
//!   coerce   comptime: literal in `pinned` -> the law's argument type, with a
//!            compile error that names the law, the case and the argument
//!   fmt      runtime: argument value -> the source text that pins it, so a
//!            falsified law prints something ready to paste into `pinned`
//!   encode   comptime: argument value -> the bytes `std.testing.Smith` turns
//!            back into that value, so `fuzzLaws` can seed its corpus
//!
//! Spelling in a `pinned` entry, by argument type:
//!
//!   ints, bool         `5`, `-1`, `true`
//!   enum               `.tag`; a non-exhaustive enum also takes an integer
//!   `?T`               `null` or a `T`
//!   `[N]T`             `.{ a, b, ... }`; `[N]u8` also takes a string literal
//!   `zv.Ranged`        an integer
//!   `zv.Bytes(max)`    a string literal, or `.{ 0x45, 0x00 }`
//!   struct             `.{ .field = value, ... }` (defaults may be omitted)
//!
//! Any value of the exact argument type is accepted too (`Pct.lit(5)`).

const std = @import("std");

// ── coerce ───────────────────────────────────────────────────────────────────

fn fail(comptime where: []const u8, comptime msg: []const u8) noreturn {
    @compileError("zv: pinned " ++ where ++ ": " ++ msg);
}

fn mismatch(comptime T: type, comptime V: type, comptime where: []const u8, comptime want: []const u8) noreturn {
    fail(where, "expected " ++ want ++ " for `" ++ @typeName(T) ++ "`, found `" ++ @typeName(V) ++ "`.");
}

fn isSeq(comptime V: type) bool {
    return switch (@typeInfo(V)) {
        .array => true,
        .pointer => |p| p.size == .one and @typeInfo(p.child) == .array,
        .@"struct" => |s| s.is_tuple,
        else => false,
    };
}

fn seqLen(comptime v: anytype) usize {
    return switch (@typeInfo(@TypeOf(v))) {
        .pointer => v.*.len,
        else => v.len,
    };
}

fn checkInt(comptime T: type, comptime v: anytype, comptime where: []const u8) T {
    const V = @TypeOf(v);
    if (@typeInfo(V) != .int and V != comptime_int) mismatch(T, V, where, "an integer");
    if (v < std.math.minInt(T) or v > std.math.maxInt(T))
        fail(where, std.fmt.comptimePrint("{d} does not fit {s} [{d}, {d}].", .{ v, @typeName(T), std.math.minInt(T), std.math.maxInt(T) }));
    return @intCast(v);
}

/// Convert the comptime literal `v` to `T`, or stop the build with a message
/// that says which pinned value is wrong and what to write instead.
/// `where` reads like "`.law` case 2, argument 0".
pub fn coerce(comptime T: type, comptime v: anytype, comptime where: []const u8) T {
    @setEvalBranchQuota(1_000_000_000);
    const V = @TypeOf(v);
    if (V == T) return v;
    switch (@typeInfo(T)) {
        .int => return checkInt(T, v, where),
        .bool => mismatch(T, V, where, "`true` or `false`"),
        .optional => |o| return if (V == @TypeOf(null)) null else coerce(o.child, v, where),
        .@"enum" => |e| {
            if (V == @TypeOf(.enum_literal)) {
                return std.meta.stringToEnum(T, @tagName(v)) orelse
                    fail(where, "`." ++ @tagName(v) ++ "` is not a tag of `" ++ @typeName(T) ++ "`. Tags: " ++ tagList(T) ++ ".");
            }
            if (e.mode == .nonexhaustive and (@typeInfo(V) == .int or V == comptime_int))
                return @fromBackingInt(checkInt(e.tag_type, v, where));
            mismatch(T, V, where, "an enum literal such as `." ++ (if (e.field_names.len > 0) e.field_names[0] else "tag") ++ "`");
        },
        .array => |a| {
            if (!isSeq(V)) mismatch(T, V, where, "a tuple like `.{ a, b }`" ++ (if (a.child == u8) " or a string literal" else ""));
            if (seqLen(v) != a.len)
                fail(where, std.fmt.comptimePrint("`{s}` needs exactly {d} elements, found {d}.", .{ @typeName(T), a.len, seqLen(v) }));
            var out: T = undefined;
            inline for (0..a.len) |i| out[i] = coerce(a.child, v[i], where ++ std.fmt.comptimePrint(", element {d}", .{i}));
            return out;
        },
        .@"struct" => |info| {
            if (@hasDecl(T, "is_ranged")) {
                if (V != comptime_int and @typeInfo(V) != .int) mismatch(T, V, where, "an integer in [" ++ std.fmt.comptimePrint("{d}, {d}", .{ T.min, T.max }) ++ "]");
                if (v < T.min or v > T.max)
                    fail(where, std.fmt.comptimePrint("{d} is outside zv.Ranged({d}, {d}).", .{ v, T.min, T.max }));
                return .{ .raw = @intCast(v) };
            }
            if (@hasDecl(T, "is_bytes")) {
                if (!isSeq(V)) mismatch(T, V, where, "a string literal like \"\\x45\\x00\" or a tuple like `.{ 0x45, 0x00 }`");
                if (seqLen(v) > T.max_len)
                    fail(where, std.fmt.comptimePrint("{d} bytes do not fit `zv.Bytes({d})`.", .{ seqLen(v), T.max_len }));
                var out: T = .{};
                out.len = seqLen(v);
                inline for (0..seqLen(v)) |i| out.buf[i] = coerce(u8, v[i], where ++ std.fmt.comptimePrint(", byte {d}", .{i}));
                return out;
            }
            if (@typeInfo(V) != .@"struct" or @typeInfo(V).@"struct".is_tuple)
                mismatch(T, V, where, "a struct literal like `.{ ." ++ (if (info.field_names.len > 0) info.field_names[0] else "field") ++ " = ... }`");
            inline for (@typeInfo(V).@"struct".field_names) |name| {
                if (!@hasField(T, name))
                    fail(where, "`" ++ @typeName(T) ++ "` has no field `" ++ name ++ "`. Fields: " ++ fieldList(T) ++ ".");
            }
            var out: T = undefined;
            inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
                const sub = where ++ ", field `." ++ name ++ "`";
                if (@hasField(V, name)) {
                    @field(out, name) = coerce(F, @field(v, name), sub);
                } else if (attrs.defaultValue(F)) |d| {
                    @field(out, name) = d;
                } else fail(where, "missing field `." ++ name ++ "` of `" ++ @typeName(T) ++ "`.");
            }
            return out;
        },
        else => @compileError("zv: cannot pin " ++ @typeName(T) ++ " (not a supported law argument type)."),
    }
}

fn tagList(comptime T: type) []const u8 {
    comptime {
        var s: []const u8 = "";
        for (@typeInfo(T).@"enum".field_names, 0..) |n, i| s = s ++ (if (i > 0) ", " else "") ++ "." ++ n;
        return s;
    }
}

fn fieldList(comptime T: type) []const u8 {
    comptime {
        var s: []const u8 = "";
        for (@typeInfo(T).@"struct".field_names, 0..) |n, i| s = s ++ (if (i > 0) ", " else "") ++ "." ++ n;
        return s;
    }
}

// ── fmt ──────────────────────────────────────────────────────────────────────

const Writer = std.Io.Writer;
const max_line = 96;
const bytes_per_chunk = 32;

fn indentBy(w: *Writer, n: usize) Writer.Error!void {
    try w.splatByteAll(' ', n);
}

fn byteSlice(comptime T: type, v: *const T) []const u8 {
    return if (@typeInfo(T) == .array) &v.* else v.slice();
}

fn isRanged(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_ranged");
}

fn isByteString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |a| a.child == u8,
        .@"struct" => @hasDecl(T, "is_bytes"),
        else => false,
    };
}

fn writeBytes(w: *Writer, bytes: []const u8, indent: usize) Writer.Error!void {
    if (bytes.len <= bytes_per_chunk) return w.print("\"{f}\"", .{std.zig.fmtString(bytes)});
    var rest = bytes;
    while (rest.len > 0) {
        const n = @min(rest.len, bytes_per_chunk);
        try w.print("\"{f}\"", .{std.zig.fmtString(rest[0..n])});
        rest = rest[n..];
        if (rest.len > 0) {
            try w.writeAll(" ++\n");
            try indentBy(w, indent + 4);
        }
    }
}

/// `value` as Zig source that `coerce` accepts for `T`. `indent` is the column
/// the value starts on; nested lines are indented relative to it. Containers
/// that fit on one line stay on one line, so small tuples read as
/// `.{ 1, 2 }` and a 32-op script becomes one op per line.
pub fn write(w: *Writer, comptime T: type, value: T, indent: usize) Writer.Error!void {
    switch (@typeInfo(T)) {
        .int => try w.print("{d}", .{value}),
        .bool => try w.writeAll(if (value) "true" else "false"),
        .optional => |o| if (value) |inner| try write(w, o.child, inner, indent) else try w.writeAll("null"),
        .@"enum" => |e| {
            inline for (e.field_names) |name| {
                if (value == @field(T, name)) return w.print(".{f}", .{std.zig.fmtId(name)});
            }
            try w.print("{d}", .{@backingInt(value)}); // non-exhaustive, unnamed
        },
        .array, .@"struct" => {
            if (comptime isByteString(T)) return writeBytes(w, byteSlice(T, &value), indent);
            if (comptime isRanged(T)) return w.print("{d}", .{value.raw});
            try writeContainer(w, T, value, indent);
        },
        else => @compileError("zv: cannot print " ++ @typeName(T)),
    }
}

fn writeContainer(w: *Writer, comptime T: type, value: T, indent: usize) Writer.Error!void {
    var counter_buf: [1]u8 = undefined;
    var counter: Writer.Discarding = .init(&counter_buf);
    try writeShape(&counter.writer, T, value, indent, false);
    try counter.writer.flush();
    const fits = indent + counter.fullCount() <= max_line;
    try writeShape(w, T, value, indent, !fits);
}

fn writeShape(w: *Writer, comptime T: type, value: T, indent: usize, multiline: bool) Writer.Error!void {
    const count = switch (@typeInfo(T)) {
        .array => |a| a.len,
        .@"struct" => |s| s.field_names.len,
        else => unreachable,
    };
    if (count == 0) return w.writeAll(".{}");
    try w.writeAll(if (multiline) ".{\n" else ".{ ");
    inline for (0..count) |i| {
        const Item = switch (@typeInfo(T)) {
            .array => |a| a.child,
            .@"struct" => |s| s.field_types[i],
            else => unreachable,
        };
        const item = switch (@typeInfo(T)) {
            .array => value[i],
            .@"struct" => |s| @field(value, s.field_names[i]),
            else => unreachable,
        };
        if (multiline) try indentBy(w, indent + 4) else if (i > 0) try w.writeAll(", ");
        if (@typeInfo(T) == .@"struct" and !@typeInfo(T).@"struct".is_tuple)
            try w.print(".{f} = ", .{std.zig.fmtId(@typeInfo(T).@"struct".field_names[i])});
        try write(w, Item, item, if (multiline) indent + 4 else indent);
        if (multiline) try w.writeAll(",\n");
    }
    if (multiline) {
        try indentBy(w, indent);
        try w.writeAll("}");
    } else try w.writeAll(" }");
}

/// Formatter for `std.debug.print("{f}", ...)`: the full `pinned` entry for one
/// falsified case, ready to paste inside `pub const pinned = .{ ... };`.
pub fn Entry(comptime Args: type) type {
    return struct {
        law: []const u8,
        args: Args,

        pub fn format(self: @This(), w: *Writer) Writer.Error!void {
            try indentBy(w, 4);
            try w.print(".{f} = .{{\n", .{std.zig.fmtId(self.law)});
            try indentBy(w, 8);
            try write(w, Args, self.args, 8);
            try w.writeAll(",\n");
            try indentBy(w, 4);
            try w.writeAll("},");
        }
    };
}

pub fn entry(law: []const u8, args: anytype) Entry(@TypeOf(args)) {
    return .{ .law = law, .args = args };
}

// ── encode ───────────────────────────────────────────────────────────────────

/// Growing byte buffer used while a corpus entry is built at comptime.
pub const Sink = struct {
    buf: [capacity]u8 = undefined,
    len: usize = 0,
    /// Set when the case did not fit; such a case is not seeded.
    overflow: bool = false,

    pub const capacity = 1 << 15;

    pub fn word(s: *Sink, x: u64) void {
        if (s.len + 8 > capacity) {
            s.overflow = true;
            return;
        }
        std.mem.writeInt(u64, s.buf[s.len..][0..8], x, .little);
        s.len += 8;
    }

    pub fn raw(s: *Sink, bytes: []const u8) void {
        if (s.len + bytes.len > capacity) {
            s.overflow = true;
            return;
        }
        @memcpy(s.buf[s.len..][0..bytes.len], bytes);
        s.len += bytes.len;
    }
};

/// `std.testing.Smith` reads every scalar as a little-endian u64 (values wider
/// than 64 bits in 64-bit chunks, low first) and byte strings verbatim.
fn encodeBits(comptime T: type, x: T, s: *Sink) void {
    const bits = if (T == usize or T == isize) 64 else @bitSizeOf(T);
    const wide: @Int(.unsigned, bits) = if (T == usize) @intCast(x) else if (T == isize) @bitCast(@as(i64, x)) else @bitCast(x);
    comptime var at = 0;
    inline while (at < bits) : (at += 64) s.word(@truncate(wide >> at));
}

/// Mirror of `laws.fromSmith` for one value: append the bytes that make it
/// regenerate `value`. Always chooses the "no edge bias" selectors, so the
/// value is reproduced exactly. `laws.zig` tests the round trip.
pub fn encode(comptime T: type, comptime value: T, s: *Sink) void {
    switch (@typeInfo(T)) {
        .int => {
            s.word(4); // edge selector: not an edge
            encodeBits(T, value, s);
        },
        .bool => s.word(@intFromBool(value)),
        .optional => |o| if (value) |inner| {
            s.word(1);
            encode(o.child, inner, s);
        } else s.word(0),
        .@"enum" => |e| {
            const named = comptime blk: {
                for (std.enums.values(T), 0..) |tag, i| {
                    if (tag == value) break :blk @as(?usize, i);
                }
                break :blk null;
            };
            if (e.mode == .nonexhaustive) {
                if (e.field_names.len > 0) s.word(if (named != null) 1 else 0);
                if (named) |i| s.word(i) else encodeBits(e.tag_type, @backingInt(value), s);
            } else s.word(named.?);
        },
        .array => |a| if (a.child == u8) {
            s.word(2); // content selector: random bytes
            s.raw(&value);
        } else inline for (value) |item| encode(a.child, item, s),
        .@"struct" => |info| {
            if (@hasDecl(T, "is_ranged")) {
                s.word(4);
                // Smith draws signed ranges as an offset from the type's minimum.
                s.word(@intCast(@as(i128, value.raw) - std.math.minInt(T.T)));
                return;
            }
            if (@hasDecl(T, "is_bytes")) {
                s.word(7); // length selector: not an edge
                s.word(value.len);
                s.word(2);
                s.raw(value.slice());
                return;
            }
            inline for (info.field_names, info.field_types) |name, F| encode(F, @field(value, name), s);
        },
        else => unreachable,
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

const Op = struct { kind: enum { send, recv, tick }, len: u8 };

fn render(comptime T: type, value: T, indent: usize, buf: []u8) ![]const u8 {
    var w: Writer = .fixed(buf);
    try write(&w, T, value, indent);
    return w.buffered();
}

test "scalars and small containers print on one line" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("-5", try render(i8, -5, 0, &buf));
    try std.testing.expectEqualStrings("null", try render(?u8, null, 0, &buf));
    try std.testing.expectEqualStrings(".{ 1, 2, 3 }", try render([3]u16, .{ 1, 2, 3 }, 0, &buf));
    try std.testing.expectEqualStrings(".{ .kind = .recv, .len = 7 }", try render(Op, .{ .kind = .recv, .len = 7 }, 0, &buf));
    try std.testing.expectEqualStrings("\"\\x00A\\xff\"", try render([3]u8, .{ 0, 'A', 0xff }, 0, &buf));
}

test "a long list of structs prints one element per line" {
    var buf: [4096]u8 = undefined;
    var ops: [12]Op = undefined;
    for (&ops, 0..) |*op, i| op.* = .{ .kind = .send, .len = @intCast(i) };
    const text = try render([12]Op, ops, 4, &buf);
    try std.testing.expect(std.mem.startsWith(u8, text, ".{\n        .{ .kind = .send, .len = 0 },\n"));
    try std.testing.expect(std.mem.endsWith(u8, text, "        .{ .kind = .send, .len = 11 },\n    }"));
}

test "long byte strings are chunked and concatenated" {
    var buf: [1024]u8 = undefined;
    const bytes: [70]u8 = @splat(0xff);
    const text = try render([70]u8, bytes, 8, &buf);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, " ++\n"));
}

test "entry wraps the case in the pinned shape" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try w.print("{f}", .{entry("lawName", .{ @as(u8, 1), @as(?bool, null) })});
    try std.testing.expectEqualStrings(
        \\    .lawName = .{
        \\        .{ 1, null },
        \\    },
    , w.buffered());
}

test "coerce builds every supported shape" {
    const Mode = enum(u8) { off, on, _ };
    const S = struct { a: u8, b: ?Mode = null };
    const R = struct {
        pub const T = u8;
        pub const min = 10;
        pub const max = 20;
        pub const is_ranged = true;
        raw: u8,
    };
    comptime {
        std.debug.assert(coerce(u8, 255, "x") == 255);
        std.debug.assert(coerce(i8, -128, "x") == -128);
        std.debug.assert(coerce(?u8, null, "x") == null);
        std.debug.assert(coerce(?u8, 3, "x").? == 3);
        std.debug.assert(coerce(Mode, .on, "x") == .on);
        std.debug.assert(coerce(Mode, 9, "x") == @as(Mode, @fromBackingInt(9)));
        std.debug.assert(std.mem.eql(u8, &coerce([3]u8, "abc", "x"), "abc"));
        std.debug.assert(coerce([2]u16, .{ 1, 2 }, "x")[1] == 2);
        std.debug.assert(coerce(S, .{ .a = 4 }, "x").b == null);
        std.debug.assert(coerce(S, .{ .a = 4, .b = .on }, "x").b.? == .on);
        std.debug.assert(coerce(R, 20, "x").raw == 20);
    }
}
