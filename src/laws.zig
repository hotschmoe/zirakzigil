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
//!   `Ranged`    always inside its range
//!   `Bytes(n)`  variable-length byte string, lengths biased to 0, 1, n, n-1
//!               and typical header sizes (8, 20, 40) -- for parser laws
//!   structs     field by field
//!
//! Test-time only: both drivers print on failure and use `std.testing`, so
//! they are analyzed (and OS-dependent) only where a test calls them.

const std = @import("std");
const manifest = @import("manifest.zig");

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
            if (@hasDecl(T, "is_ranged")) return .{ .raw = rnd.intRangeAtMost(T.T, T.min, T.max) };
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

fn check(comptime Laws: type, iterations: usize, seed: u64, comptime verbose: bool) error{LawFalsified}!void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rnd = prng.random();
    inline for (comptime lawFns(Laws)) |name| {
        for (0..iterations) |_| {
            var args: Args(Laws, name) = undefined;
            inline for (@typeInfo(@TypeOf(args)).@"struct".field_names) |field| {
                @field(args, field) = fromRandom(@TypeOf(@field(args, field)), rnd);
            }
            if (!@call(.auto, @field(Laws, name), args)) return falsified(name, args, verbose);
        }
    }
}

fn falsified(comptime name: []const u8, args: anytype, comptime verbose: bool) error{LawFalsified} {
    if (verbose) std.debug.print("zv: law `{s}` falsified by {any}\n", .{ name, args });
    return error.LawFalsified;
}

/// Run every law in `Laws` against `iterations` random argument tuples.
/// Same seed, same inputs.
pub fn checkLaws(comptime Laws: type, iterations: usize, seed: u64) error{LawFalsified}!void {
    return check(Laws, iterations, seed, true);
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
            if (@hasDecl(T, "is_ranged")) return .{ .raw = smith.valueRangeAtMost(T.T, T.min, T.max) };
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

/// Run `Laws` as one fuzz target: each input picks a law, then derives its
/// arguments from the input bytes. Under plain `zig build test` this only
/// replays `corpus` plus an empty input (a smoke test); under
/// `zig build test --fuzz` the fuzzer drives it. Call from a single `test`.
pub fn fuzzLaws(comptime Laws: type, corpus: []const []const u8) anyerror!void {
    const names = comptime lawFns(Laws);
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            const pick = smith.index(names.len);
            inline for (names, 0..) |name, i| {
                if (pick == i) {
                    var args: Args(Laws, name) = undefined;
                    inline for (@typeInfo(@TypeOf(args)).@"struct".field_names) |field| {
                        @field(args, field) = fromSmith(@TypeOf(@field(args, field)), smith);
                    }
                    if (!@call(.auto, @field(Laws, name), args)) return falsified(name, args, true);
                }
            }
        }
    };
    try std.testing.fuzz({}, Target.one, .{ .corpus = corpus });
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
    try checkLaws(sample_laws, 500, 1);
}

test "checkLaws finds an off-by-one in a parser at a fixed seed" {
    try std.testing.expectError(error.LawFalsified, check(parser_laws, 2000, 1, false));
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

test "fuzzLaws replays a corpus and the empty input" {
    try fuzzLaws(sample_laws, &.{ "\x00\x01\x02\x03", &@as([64]u8, @splat(0xff)) });
}
