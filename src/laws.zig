//! Executable laws: a `laws` namespace of `fn(...) bool` properties.
//!
//! Two drivers share one argument model:
//!
//!   checkLaws  seeded and deterministic: the CI gate.
//!   fuzzLaws   arguments come from `std.testing.fuzz` input bytes, so
//!              `zig build test --fuzz` explores them coverage-guided.
//!
//! Supported argument types, all generated edge-biased:
//!   ints        0, 1, min, max over-represented
//!   bool, `?T`  optionals are null a quarter of the time
//!   `[N]T`      element-wise; `[N]u8` is often all 0x00 or all 0xff
//!   enums       exhaustive: a valid tag; non-exhaustive: mostly named tags,
//!               sometimes any backing value
//!   `Ranged`    always inside its range; min, max, min+1, max-1 over-represented
//!   `Bytes(n)`  variable-length byte string, lengths biased to 0, 1, n, n-1
//!               and typical header sizes (8, 20, 40) -- for parser laws
//!   structs     field by field
//!
//! Regressions are pinned argument tuples, replayed before any random case:
//!
//!     pub const pinned = .{ .lawName = .{ .{ arg0, arg1 }, .{ ... } } };
//!
//! A falsified law prints a ready-to-paste entry. See `pinned.zig` for the
//! spelling of each argument type and `docs/adoption.md` for the workflow.
//!
//! Test-time only: both drivers print on failure and use `std.testing`, so
//! they are analyzed (and OS-dependent) only where a test calls them.

const std = @import("std");
const manifest = @import("manifest.zig");
const pinned = @import("pinned.zig");

/// A byte string of at most `max` bytes, the argument type for parser laws:
/// `pub fn parses(input: zv.Bytes(64)) bool { _ = parse(input.slice()) catch {}; return true; }`
pub fn Bytes(comptime max: usize) type {
    return struct {
        buf: [max]u8 = @splat(0),
        len: usize = 0,

        const Self = @This();
        pub const is_bytes = true;
        pub const max_len = max;

        pub const assurance = .{ .slice = .tested };
        comptime {
            manifest.requireAssurance(Self, .tested);
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

const edge_choices = 8;

/// Integers with edge values over-represented: that is where overflow bugs live.
fn edgeInt(comptime T: type, selector: u8) ?T {
    return switch (selector % edge_choices) {
        0 => 0,
        1 => std.math.maxInt(T),
        2 => std.math.minInt(T),
        3 => 1,
        else => null,
    };
}

/// Ranged integers get the same treatment: the two ends of the range and their
/// neighbours, where off-by-one bugs live. A range too small to have distinct
/// neighbours just repeats its ends.
fn edgeRanged(comptime T: type, selector: u8) ?T.T {
    return switch (selector % edge_choices) {
        0 => T.min,
        1 => T.max,
        2 => @min(T.min + 1, T.max),
        3 => @max(T.max - 1, T.min),
        else => null,
    };
}

/// Byte-string lengths worth testing on every parser: empty, one byte, the
/// limits, and common header sizes (UDP 8, IPv4 20, IPv6 40).
fn edgeLen(comptime max: usize, selector: u8) ?usize {
    const sizes = [_]usize{ 0, 1, max, max -| 1, 8, 20, 40 };
    return switch (selector % 10) {
        0...6 => @min(sizes[selector % 10], max),
        else => null,
    };
}

fn lawFns(comptime Laws: type) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (std.meta.declarations(Laws)) |name| {
            if (@typeInfo(@TypeOf(@field(Laws, name))) == .@"fn") names = names ++ &[_][]const u8{name};
        }
        if (names.len == 0) @compileError("zv: `" ++ @typeName(Laws) ++ "` has no `pub fn` laws. Add `pub fn name(args...) bool` properties.");
        return names;
    }
}

fn Args(comptime Laws: type, comptime name: []const u8) type {
    return std.meta.ArgsTuple(@TypeOf(@field(Laws, name)));
}

fn unsupported(comptime T: type) noreturn {
    @compileError("zv: cannot generate " ++ @typeName(T) ++ " for a law argument. Supported: ints, bool, ?T, [N]T, enums, " ++
        "zv.Ranged, zv.Bytes(max) for byte strings, and structs of those. Slices and pointers have no fixed shape: take zv.Bytes(max) and call .slice().");
}

// ── random source ────────────────────────────────────────────────────────────

fn fromRandom(comptime T: type, rnd: std.Random) T {
    switch (@typeInfo(T)) {
        .int => return edgeInt(T, rnd.int(u8)) orelse rnd.int(T),
        .bool => return rnd.boolean(),
        .optional => |o| return if (rnd.uintLessThan(u8, 4) == 0) null else fromRandom(o.child, rnd),
        .array => |a| {
            var arr: [a.len]a.child = undefined;
            if (a.child == u8) {
                switch (rnd.uintLessThan(u8, 4)) {
                    0 => arr = @splat(0),
                    1 => arr = @splat(0xff),
                    else => rnd.bytes(&arr),
                }
            } else {
                for (&arr) |*item| item.* = fromRandom(a.child, rnd);
            }
            return arr;
        },
        .@"enum" => |e| {
            if (e.mode == .nonexhaustive and (e.field_names.len == 0 or rnd.uintLessThan(u8, 4) == 0))
                return @fromBackingInt(rnd.int(e.tag_type));
            return std.enums.values(T)[rnd.uintLessThan(usize, e.field_names.len)];
        },
        .@"struct" => |info| {
            if (@hasDecl(T, "is_ranged")) return .{ .raw = edgeRanged(T, rnd.int(u8)) orelse rnd.intRangeAtMost(T.T, T.min, T.max) };
            if (@hasDecl(T, "is_bytes")) {
                var v: T = .{};
                v.len = edgeLen(T.max_len, rnd.int(u8)) orelse rnd.intRangeAtMost(usize, 0, T.max_len);
                switch (rnd.uintLessThan(u8, 4)) {
                    0 => {},
                    1 => @memset(v.buf[0..v.len], 0xff),
                    else => rnd.bytes(v.buf[0..v.len]),
                }
                return v;
            }
            var v: T = undefined;
            inline for (info.field_names, info.field_types) |fname, ftype| @field(v, fname) = fromRandom(ftype, rnd);
            return v;
        },
        else => unsupported(T),
    }
}

pub const Options = struct {
    iterations: usize = 1000,
    seed: u64 = 0,
    /// Print `zv: law X seed S iteration I` to stderr before every call. Use
    /// it when a law panics inside the test (an out-of-bounds read, say): the
    /// panic cannot be caught, so the last printed line names the case.
    trace: bool = false,
};

const Failure = struct {
    law: []const u8,
    /// Random case number, or the index within the law's pinned list.
    iteration: usize,
    pinned: bool = false,
};

/// Argument tuple for one (law, seed, iteration). Every iteration seeds its
/// own generator, so any case can be regenerated without running the others.
fn argsFor(comptime Laws: type, comptime name: []const u8, seed: u64, iteration: usize) Args(Laws, name) {
    var prng: std.Random.DefaultPrng = .init(std.hash.Wyhash.hash(seed ^ std.hash.int(@as(u64, iteration)), name));
    const rnd = prng.random();
    var args: Args(Laws, name) = undefined;
    inline for (@typeInfo(@TypeOf(args)).@"struct".field_names) |field| {
        @field(args, field) = fromRandom(@TypeOf(@field(args, field)), rnd);
    }
    return args;
}

// ── pinned cases ─────────────────────────────────────────────────────────────

fn isTuple(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple;
}

fn lawList(comptime Laws: type) []const u8 {
    comptime {
        var list: []const u8 = "";
        for (lawFns(Laws), 0..) |n, i| list = list ++ (if (i > 0) ", " else "") ++ "`" ++ n ++ "`";
        return list;
    }
}

/// The pinned argument tuples of one law, converted to its argument types.
/// Every problem in `pinned` (unknown law, bad shape, wrong arity or type) is
/// a compile error that says what to write. The key check runs for every law,
/// so a typo in a law name is caught even though no law has that name.
fn pinnedCases(comptime Laws: type, comptime name: []const u8) []const Args(Laws, name) {
    return comptime buildPinned(Laws, name);
}

fn buildPinned(comptime Laws: type, comptime name: []const u8) []const Args(Laws, name) {
    {
        if (!@hasDecl(Laws, "pinned")) return &.{};
        const P = @TypeOf(Laws.pinned);
        const where_ns = "`pinned` in " ++ @typeName(Laws);
        if (@typeInfo(P) != .@"struct" or @typeInfo(P).@"struct".is_tuple)
            @compileError("zv: " ++ where_ns ++ " must be a struct literal keyed by law name: " ++
                "`pub const pinned = .{ .lawName = .{ .{ arg0, arg1 } } };`.");
        for (@typeInfo(P).@"struct".field_names) |key| {
            const is_law = @hasDecl(Laws, key) and @typeInfo(@TypeOf(@field(Laws, key))) == .@"fn";
            if (!is_law) @compileError("zv: " ++ where_ns ++ " names `." ++ key ++ "`, which is not a law there. Laws: " ++ lawList(Laws) ++ ".");
        }
        if (!@hasField(P, name)) return &.{};

        const list = @field(Laws.pinned, name);
        const A = Args(Laws, name);
        const fields = @typeInfo(A).@"struct".field_names;
        if (!isTuple(@TypeOf(list)))
            @compileError("zv: " ++ where_ns ++ ": `." ++ name ++ "` must be a list of argument tuples: `." ++ name ++ " = .{ .{ arg0, arg1 }, .{ ... } }`.");
        var out: [list.len]A = undefined;
        for (0..list.len) |k| {
            const case = list[k];
            const where = std.fmt.comptimePrint("in {s}, `.{s}` case {d}", .{ @typeName(Laws), name, k });
            if (!isTuple(@TypeOf(case)))
                @compileError("zv: pinned " ++ where ++ ": a case is a tuple of the law's arguments, like `.{ arg0, arg1 }`.");
            if (case.len != fields.len)
                @compileError(std.fmt.comptimePrint("zv: pinned {s}: law `{s}` takes {d} argument(s) but the case has {d}.", .{ where, name, fields.len, case.len }));
            for (fields, 0..) |field, i| {
                const T = @FieldType(A, field);
                @field(out[k], field) = pinned.coerce(T, case[i], where ++ std.fmt.comptimePrint(", argument {d} (`{s}`)", .{ i, @typeName(T) }));
            }
        }
        const final = out;
        return &final;
    }
}

fn reportRandom(comptime name: []const u8, args: anytype, seed: u64, iteration: usize) void {
    std.debug.print(
        "zv: law `{s}` falsified by random case (seed {d}, iteration {d}).\n" ++
            "zv: pin it: paste this into `pub const pinned` in the laws namespace (inside the existing `.{s}` list if there is one):\n{f}\n" ++
            "zv: reproduce with zv.laws.replay(<laws>, \"{s}\", {d}, {d})\n",
        .{ name, seed, iteration, name, pinned.entry(name, args), name, seed, iteration },
    );
}

fn reportPinned(comptime name: []const u8, args: anytype, case: usize) void {
    std.debug.print(
        "zv: law `{s}` falsified by its pinned case {d}. Fix the code, not the pin:\n{f}\n",
        .{ name, case, pinned.entry(name, args) },
    );
}

fn find(comptime Laws: type, options: Options, comptime verbose: bool) ?Failure {
    // Pinned regressions first, every run, whatever the generators do.
    inline for (comptime lawFns(Laws)) |name| {
        for (pinnedCases(Laws, name), 0..) |args, k| {
            if (options.trace) std.debug.print("zv: law `{s}` pinned case {d}\n", .{ name, k });
            if (!@call(.auto, @field(Laws, name), args)) {
                if (verbose) reportPinned(name, args, k);
                return .{ .law = name, .iteration = k, .pinned = true };
            }
        }
    }
    inline for (comptime lawFns(Laws)) |name| {
        for (0..options.iterations) |i| {
            const args = argsFor(Laws, name, options.seed, i);
            if (options.trace) std.debug.print("zv: law `{s}` seed {d} iteration {d}\n", .{ name, options.seed, i });
            if (!@call(.auto, @field(Laws, name), args)) {
                if (verbose) reportRandom(name, args, options.seed, i);
                return .{ .law = name, .iteration = i };
            }
        }
    }
    return null;
}

/// Replay the `pinned` cases of every law, then run each law against
/// `options.iterations` random argument tuples. Same seed, same inputs. A
/// falsified law prints a ready-to-paste `pinned` entry and the exact `replay`
/// call.
pub fn checkLaws(comptime Laws: type, options: Options) error{LawFalsified}!void {
    if (find(Laws, options, true) != null) return error.LawFalsified;
}

/// Regenerate the argument tuple of one case reported by `checkLaws`, print it,
/// and call the law once. Run it under a debugger, or let a panic show its
/// full trace without the other cases around it.
pub fn replay(comptime Laws: type, comptime name: []const u8, seed: u64, iteration: usize) error{LawFalsified}!void {
    const args = argsFor(Laws, name, seed, iteration);
    std.debug.print("zv: replaying law `{s}` seed {d} iteration {d}:\n{f}\n", .{ name, seed, iteration, pinned.entry(name, args) });
    if (!@call(.auto, @field(Laws, name), args)) return error.LawFalsified;
}

// ── fuzzer source ────────────────────────────────────────────────────────────

fn fromSmith(comptime T: type, smith: *std.testing.Smith) T {
    switch (@typeInfo(T)) {
        .int => |info| {
            if (edgeInt(T, smith.value(u8))) |edge| return edge;
            // Smith rejects usize/isize (no fixed width): draw 64 bits and truncate.
            if (T == usize or T == isize) return @truncate(smith.value(@Int(info.signedness, 64)));
            return smith.value(T);
        },
        .bool => return smith.value(bool),
        .optional => |o| return if (smith.value(u8) % 4 == 0) null else fromSmith(o.child, smith),
        .array => |a| {
            var arr: [a.len]a.child = undefined;
            if (a.child == u8) {
                switch (smith.value(u8) % 4) {
                    0 => arr = @splat(0),
                    1 => arr = @splat(0xff),
                    else => smith.bytes(&arr),
                }
            } else {
                for (&arr) |*item| item.* = fromSmith(a.child, smith);
            }
            return arr;
        },
        .@"enum" => |e| {
            if (e.mode == .nonexhaustive and (e.field_names.len == 0 or smith.value(u8) % 4 == 0))
                return @fromBackingInt(smith.value(e.tag_type));
            return std.enums.values(T)[smith.index(e.field_names.len)];
        },
        .@"struct" => |info| {
            if (@hasDecl(T, "is_ranged"))
                return .{ .raw = edgeRanged(T, smith.value(u8)) orelse smith.valueRangeAtMost(T.T, T.min, T.max) };
            if (@hasDecl(T, "is_bytes")) {
                var v: T = .{};
                v.len = edgeLen(T.max_len, smith.value(u8)) orelse smith.index(T.max_len + 1);
                switch (smith.value(u8) % 4) {
                    0 => {},
                    1 => @memset(v.buf[0..v.len], 0xff),
                    else => smith.bytes(v.buf[0..v.len]),
                }
                return v;
            }
            var v: T = undefined;
            inline for (info.field_names, info.field_types) |fname, ftype| @field(v, fname) = fromSmith(ftype, smith);
            return v;
        },
        else => unsupported(T),
    }
}

/// Fuzz inputs that regenerate each pinned case: the law's index, then its
/// arguments in the encoding `fromSmith` reads. A case too large for the
/// encoder's buffer is skipped (checkLaws still replays it).
fn pinnedCorpus(comptime Laws: type, comptime names: []const []const u8) []const []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000_000);
        var out: []const []const u8 = &.{};
        for (names, 0..) |name, law_index| {
            for (pinnedCases(Laws, name)) |args| {
                var sink: pinned.Sink = .{};
                sink.word(law_index);
                for (@typeInfo(@TypeOf(args)).@"struct".field_names) |field| {
                    pinned.encode(@FieldType(@TypeOf(args), field), @field(args, field), &sink);
                }
                if (sink.overflow) continue;
                const bytes = sink.buf[0..sink.len].*;
                out = out ++ &[_][]const u8{&bytes};
            }
        }
        return out;
    }
}

/// Run `Laws` as one fuzz target: each input picks a law, then derives its
/// arguments from the input bytes. The corpus is seeded with every `pinned`
/// case, encoded back into input bytes, plus `corpus` (comptime, so the two
/// can be joined without an allocator). Under plain `zig build test` this only
/// replays the corpus plus an empty input (a smoke test); under
/// `zig build test --fuzz` the fuzzer drives it. Call from a single `test`.
pub fn fuzzLaws(comptime Laws: type, comptime corpus: []const []const u8) anyerror!void {
    const names = comptime lawFns(Laws);
    const seeds = comptime pinnedCorpus(Laws, names) ++ corpus;
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            const pick = smith.index(names.len);
            inline for (names, 0..) |name, i| {
                if (pick == i) {
                    var args: Args(Laws, name) = undefined;
                    inline for (@typeInfo(@TypeOf(args)).@"struct".field_names) |field| {
                        @field(args, field) = fromSmith(@TypeOf(@field(args, field)), smith);
                    }
                    if (!@call(.auto, @field(Laws, name), args)) {
                        std.debug.print(
                            "zv: law `{s}` falsified. Pin it by pasting this into `pub const pinned` in the laws namespace:\n{f}\n",
                            .{ name, pinned.entry(name, args) },
                        );
                        return error.LawFalsified;
                    }
                }
            }
        }
    };
    try std.testing.fuzz({}, Target.one, .{ .corpus = seeds });
}

// ── tests ────────────────────────────────────────────────────────────────────

const Color = enum { red, green, blue };
const Mode = enum(u8) { off = 0, on = 1, _ };

const sample_laws = struct {
    pub fn addCommutes(a: u8, b: u8) bool {
        return a +% b == b +% a;
    }
    pub fn boolsAndSizes(flag: bool, n: usize) bool {
        return flag or !flag or n == 0;
    }
    pub fn shapes(bytes: [4]u8, color: Color, mode: Mode, maybe: ?u16, input: Bytes(32)) bool {
        _ = bytes;
        _ = maybe;
        return @backingInt(color) < 3 and @backingInt(mode) <= 255 and input.slice().len <= 32;
    }
};

/// A header parser with a planted off-by-one: 8 header bytes are needed, but
/// the guard lets a 7-byte input through.
const Header = struct { first: u8, last: u8, last_in_range: bool };
fn parseHeader(b: []const u8) ?Header {
    if (b.len < 7) return null; // BUG: should be `< 8`
    const in_range = b.len > 7;
    return .{ .first = b[0], .last = if (in_range) b[7] else 0, .last_in_range = in_range };
}

const parser_laws = struct {
    pub fn acceptedMeansComplete(input: Bytes(64)) bool {
        const h = parseHeader(input.slice()) orelse return true;
        return h.last_in_range;
    }
};

test "checkLaws is deterministic and passes true laws" {
    try checkLaws(sample_laws, .{ .iterations = 500, .seed = 1 });
}

test "a falsified case is found at a fixed seed and replays exactly" {
    const failure = find(parser_laws, .{ .iterations = 2000, .seed = 1 }, false) orelse return error.TestExpectedFailure;
    try std.testing.expectEqualStrings("acceptedMeansComplete", failure.law);
    try std.testing.expect(failure.iteration < 500); // found quickly
    try std.testing.expectError(
        error.LawFalsified,
        replay(parser_laws, "acceptedMeansComplete", 1, failure.iteration),
    );
    try replay(parser_laws, "acceptedMeansComplete", 1, 0); // iteration 0 passes
}

test "generators cover edge lengths and enum tags" {
    var prng: std.Random.DefaultPrng = .init(3);
    const rnd = prng.random();
    var seen_len: [4]bool = @splat(false); // 0, 1, 64, 63
    var seen_other = false;
    var seen_tag: [3]bool = @splat(false);
    for (0..400) |_| {
        const b = fromRandom(Bytes(64), rnd);
        switch (b.len) {
            0 => seen_len[0] = true,
            1 => seen_len[1] = true,
            64 => seen_len[2] = true,
            63 => seen_len[3] = true,
            else => seen_other = true,
        }
        seen_tag[@backingInt(fromRandom(Color, rnd))] = true;
    }
    try std.testing.expect(std.mem.allEqual(bool, &seen_len, true) and seen_other);
    try std.testing.expect(std.mem.allEqual(bool, &seen_tag, true));
}

test "Ranged arguments hit both ends and their neighbours, in both generators" {
    const R = @import("zv.zig").Ranged(10, 200);
    var prng: std.Random.DefaultPrng = .init(5);
    const rnd = prng.random();
    var seen_random: [4]bool = @splat(false); // 10, 11, 199, 200
    var seen_smith: [4]bool = @splat(false);
    var inside = true;
    for (0..300) |i| {
        const r = fromRandom(R, rnd).raw;
        for ([_]u8{ 10, 11, 199, 200 }, &seen_random) |edge, *seen| seen.* = seen.* or r == edge;
        inside = inside and r >= 10 and r <= 200;

        // Smith reads each value as a little-endian u64: selector, then payload.
        var input: [16]u8 = @splat(0);
        std.mem.writeInt(u64, input[0..8], i % edge_choices, .little);
        std.mem.writeInt(u64, input[8..16], 100, .little);
        var smith: std.testing.Smith = .{ .in = &input };
        const s = fromSmith(R, &smith).raw;
        for ([_]u8{ 10, 11, 199, 200 }, &seen_smith) |edge, *seen| seen.* = seen.* or s == edge;
        inside = inside and s >= 10 and s <= 200;
    }
    try std.testing.expect(inside);
    try std.testing.expect(std.mem.allEqual(bool, &seen_random, true));
    try std.testing.expect(std.mem.allEqual(bool, &seen_smith, true));
}

test "tiny Ranged types stay inside their range" {
    var prng: std.Random.DefaultPrng = .init(9);
    const rnd = prng.random();
    for (0..50) |_| {
        try std.testing.expectEqual(4, fromRandom(@import("zv.zig").Ranged(4, 4), rnd).raw);
        try std.testing.expect(fromRandom(@import("zv.zig").Ranged(-1, 0), rnd).raw <= 0);
    }
}

test "fuzzLaws replays a corpus and the empty input" {
    try fuzzLaws(sample_laws, &.{ "\x00\x01\x02\x03", &@as([64]u8, @splat(0xff)) });
}

// ── pinned tests ─────────────────────────────────────────────────────────────

const Kind = enum { send, recv, tick };
const Op = struct { kind: Kind, len: u8 = 0 };
const Pct = @import("zv.zig").Ranged(0, 100);
const Signed = @import("zv.zig").Ranged(-8, 8);

/// One law over every supported argument shape, pinned with every spelling.
const kitchen_sink = struct {
    pub fn everything(a: i16, b: bool, c: ?u8, d: [3]u8, e: Kind, f: Mode, g: Pct, h: Bytes(16), i: Op, j: [2]Op, k: usize, l: i64, m: Signed, n: u128) bool {
        _ = .{ a, b, c, d, e, f, g, h, i, j, k, l, m, n };
        return true;
    }

    pub const pinned = .{
        .everything = .{
            .{ -5, true, null, "abc", .recv, 7, 100, "hi", .{ .kind = .tick }, .{ .{ .kind = .send, .len = 3 }, .{ .kind = .recv } }, 9, -1, -8, 1 << 100 },
            .{ 0, false, 200, .{ 1, 2, 3 }, .tick, .on, Pct.lit(0), .{ 0x45, 0x00 }, .{ .kind = .send }, .{ .{ .kind = .send }, .{ .kind = .send } }, 0, 0, 8, 0 },
        },
    };
};

test "pinned cases pass through checkLaws before any random case" {
    try checkLaws(kitchen_sink, .{ .iterations = 0 });
}

test "pinned cases survive a round trip through the fuzz encoding" {
    const names = comptime lawFns(kitchen_sink);
    const corpus = comptime pinnedCorpus(kitchen_sink, names);
    try std.testing.expectEqual(2, corpus.len);
    inline for (corpus, 0..) |bytes, k| {
        var smith: std.testing.Smith = .{ .in = bytes };
        try std.testing.expectEqual(0, smith.index(names.len));
        var args: Args(kitchen_sink, "everything") = undefined;
        inline for (@typeInfo(@TypeOf(args)).@"struct".field_names) |field| {
            @field(args, field) = fromSmith(@TypeOf(@field(args, field)), &smith);
        }
        try std.testing.expectEqualDeep(pinnedCases(kitchen_sink, "everything")[k], args);
        try std.testing.expectEqual(0, smith.in.?.len); // consumed exactly
    }
}

test "fuzzLaws runs the pinned corpus" {
    try fuzzLaws(kitchen_sink, &.{});
}

const too_big = struct {
    pub fn huge(a: [40000]u8) bool {
        return a.len == 40000;
    }
    pub const pinned = .{ .huge = .{.{@as([40000]u8, @splat(1))}} };
};

test "a pinned case too large for the fuzz encoder is skipped, not an error" {
    try std.testing.expectEqual(0, comptime pinnedCorpus(too_big, lawFns(too_big)).len);
    try checkLaws(too_big, .{ .iterations = 0 });
}

const regression_laws = struct {
    pub fn lessThanTwo(a: u8, b: u8) bool {
        return a +% b != 2;
    }
    pub fn notFortyTwo(x: u8) bool {
        return x != 42;
    }
    pub const pinned = .{
        .notFortyTwo = .{ .{0}, .{42}, .{43} },
    };
};

test "a falsified pinned case is reported before random cases, with its index" {
    const failure = find(regression_laws, .{ .iterations = 0 }, false) orelse return error.TestExpectedFailure;
    try std.testing.expect(failure.pinned);
    try std.testing.expectEqualStrings("notFortyTwo", failure.law);
    try std.testing.expectEqual(1, failure.iteration);
    // With random cases enabled the pinned failure still wins, even though
    // `lessThanTwo` is declared first and falls to random cases quickly.
    const again = find(regression_laws, .{ .iterations = 5000, .seed = 3 }, false).?;
    try std.testing.expect(again.pinned);
}

/// The entry below was pasted from the output of `parser_laws` failing.
const parser_regression = struct {
    pub fn acceptedMeansComplete(input: Bytes(64)) bool {
        const h = parseHeader(input.slice()) orelse return true;
        return h.last_in_range;
    }
    pub const pinned = .{
        .acceptedMeansComplete = .{
            .{"\xff\xff\xff\xff\xff\xff\xff"},
        },
    };
};

test "an entry printed for a random failure, pasted into pinned, fails first" {
    const failure = find(parser_regression, .{ .iterations = 0 }, false).?;
    try std.testing.expect(failure.pinned);
    try std.testing.expectEqual(0, failure.iteration);
}

test "pinned is not a law and does not trip the assurance manifest" {
    const Module = struct {
        pub const assurance = .{ .laws = .{ .conservation = .tested } };
        pub const laws = struct {
            pub fn conservation(a: u8, k: Kind, s: Bytes(4)) bool {
                _ = .{ a, k, s };
                return true;
            }
            pub const pinned = .{ .conservation = .{.{ 1, .tick, "ab" }} };
        };
    };
    try std.testing.expectEqualStrings("", manifest.audit(Module, .tested).problem);
    try checkLaws(Module.laws, .{ .iterations = 10 });
    // And the laws list does not include it.
    try std.testing.expectEqual(1, comptime lawFns(Module.laws).len);
}

test "the printed entry for a wide argument stays pasteable" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const ops: [3]Op = .{ .{ .kind = .send, .len = 200 }, .{ .kind = .recv }, .{ .kind = .tick, .len = 1 } };
    try w.print("{f}", .{pinned.entry("script", .{ ops, @as(u8, 4) })});
    try std.testing.expectEqualStrings(
        \\    .script = .{
        \\        .{
        \\            .{
        \\                .{ .kind = .send, .len = 200 },
        \\                .{ .kind = .recv, .len = 0 },
        \\                .{ .kind = .tick, .len = 1 },
        \\            },
        \\            4,
        \\        },
        \\    },
    , w.buffered());
}
