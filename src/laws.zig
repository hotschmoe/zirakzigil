//! Executable laws: a `laws` namespace of `fn(...) bool` properties.
//!
//! Two drivers share one argument model (edge-biased integers, `Ranged`
//! values inside their range, structs field by field):
//!
//!   checkLaws  seeded and deterministic: the CI gate.
//!   fuzzLaws   arguments come from `std.testing.fuzz` input bytes, so
//!              `zig build test --fuzz` explores them coverage-guided.
//!
//! Test-time only: both print on failure and use `std.testing`, so they are
//! analyzed (and OS-dependent) only where a test calls them.

const std = @import("std");

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

fn falsified(comptime name: []const u8, args: anytype) error{LawFalsified} {
    std.debug.print("zv: law `{s}` falsified by {any}\n", .{ name, args });
    return error.LawFalsified;
}

// ── random source ────────────────────────────────────────────────────────────

fn fromRandom(comptime T: type, rnd: std.Random) T {
    switch (@typeInfo(T)) {
        .int => return edgeInt(T, rnd.int(u8)) orelse rnd.int(T),
        .bool => return rnd.boolean(),
        .@"struct" => |info| {
            if (@hasDecl(T, "is_ranged")) return .{ .raw = rnd.intRangeAtMost(T.T, T.min, T.max) };
            var v: T = undefined;
            inline for (info.field_names, info.field_types) |fname, ftype| @field(v, fname) = fromRandom(ftype, rnd);
            return v;
        },
        else => @compileError("zv: cannot generate " ++ @typeName(T) ++ " for a law argument; use ints, bools, Ranged or structs of those"),
    }
}

/// Run every law in `Laws` against `iterations` random argument tuples.
/// Same seed, same inputs.
pub fn checkLaws(comptime Laws: type, iterations: usize, seed: u64) error{LawFalsified}!void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rnd = prng.random();
    inline for (comptime lawFns(Laws)) |name| {
        for (0..iterations) |_| {
            var args: Args(Laws, name) = undefined;
            inline for (@typeInfo(@TypeOf(args)).@"struct".field_names) |field| {
                @field(args, field) = fromRandom(@TypeOf(@field(args, field)), rnd);
            }
            if (!@call(.auto, @field(Laws, name), args)) return falsified(name, args);
        }
    }
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
        .@"struct" => |info| {
            if (@hasDecl(T, "is_ranged")) return .{ .raw = smith.valueRangeAtMost(T.T, T.min, T.max) };
            var v: T = undefined;
            inline for (info.field_names, info.field_types) |fname, ftype| @field(v, fname) = fromSmith(ftype, smith);
            return v;
        },
        else => @compileError("zv: cannot generate " ++ @typeName(T) ++ " for a law argument; use ints, bools, Ranged or structs of those"),
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
                    if (!@call(.auto, @field(Laws, name), args)) return falsified(name, args);
                }
            }
        }
    };
    try std.testing.fuzz({}, Target.one, .{ .corpus = corpus });
}

// ── tests ────────────────────────────────────────────────────────────────────

const sample_laws = struct {
    pub fn addCommutes(a: u8, b: u8) bool {
        return a +% b == b +% a;
    }
    pub fn boolsAndSizes(flag: bool, n: usize) bool {
        return flag or !flag or n == 0;
    }
};

test "checkLaws is deterministic and passes true laws" {
    try checkLaws(sample_laws, 500, 1);
}

test "fuzzLaws replays a corpus and the empty input" {
    try fuzzLaws(sample_laws, &.{ "\x00\x01\x02\x03", &@as([64]u8, @splat(0xff)) });
}
