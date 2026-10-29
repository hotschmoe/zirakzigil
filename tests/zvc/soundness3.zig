//! Cases from the third soundness review (docs/reviews/zvc-soundness-3.md). Each one was `proved` while a Debug
//! run panicked or failed its `zv.ensures`, aborted `zvc`, or guards the fix of one; the correct ones show what
//! the fix still accepts. Verdicts are pinned in `soundness3.expect`. Not run: the unsound ones would panic.

const std = @import("std");
const zv = @import("zv");

pub const assurance = .{
    .packBit = .verified,
    .packFieldM = .verified,
    .packBit2 = .verified,
    .usePack = .verified,
    .packToInt = .verified,
    .packRead = .verified,
    .packOrder = .verified,
    .bitSign = .verified,
    .bitRoundTrip = .verified,
    .bitBool = .verified,
    .packPtr = .verified,
    .ptrNest0 = .verified,
    .ptrNest1 = .verified,
    .ptrNest4 = .verified,
    .ptrWide = .verified,
    .ptrCastSame = .verified,
    .ptrSameOk = .verified,
    .plus1 = .verified,
    .incU8 = .verified,
    .incU16 = .verified,
    .sentinel0 = .verified,
    .sentinel1 = .verified,
    .sentinelCall = .verified,
    .ghostMin = .verified,
    .ghostMinMul = .verified,
};

const A16 = packed struct { lo: u8, hi: u8 };
const B16 = packed struct { n: u4, m: u4, rest: u8 };

// A bit cast between aggregates reads the same bits as another type: not a copy of the fields.

pub fn packBit(a: u8, b: u8) u4 {
    const s = A16{ .lo = a, .hi = b };
    const t: B16 = @bitCast(s);
    return zv.ensures(t.n, t.n == a);
}

pub fn packFieldM(a: u8, b: u8) u4 {
    const s = A16{ .lo = a, .hi = b };
    const t: B16 = @bitCast(s);
    return zv.ensures(t.m, t.m == b);
}

pub fn packBit2(a: u8, b: u8) u4 {
    const s = A16{ .lo = a, .hi = b };
    const t: B16 = @bitCast(s);
    return zv.ensures(t.n, t.n == a);
}

pub fn usePack(a: u8, b: u8) u4 {
    return packBit2(a, b);
}

pub fn packToInt(a: u8, b: u8) u16 {
    const s = A16{ .lo = a, .hi = b };
    const v: u16 = @bitCast(s);
    return zv.ensures(v, v & 0xff == a);
}

// What stays accepted: fields of one packed struct, and scalar casts.

pub fn packRead(a: u8, b: u8) u8 {
    const s = A16{ .lo = a, .hi = b };
    return zv.ensures(s.hi, s.hi == b);
}

const P3 = packed struct { a: u8, b: u32, c: u8 };

pub fn packOrder(a: u8, b: u32, c: u8) u8 {
    const s = P3{ .a = a, .b = b, .c = c };
    return zv.ensures(s.c, s.c == a);
}

pub fn bitSign(x: u8) bool {
    const y: i8 = @bitCast(x);
    return zv.ensures(y >= 0, y >= 0);
}

pub fn bitRoundTrip(x: u8) u8 {
    const y: i8 = @bitCast(x);
    const z: u8 = @bitCast(y);
    return zv.ensures(z, z == x);
}

pub fn bitBool(x: bool) u1 {
    const y: u1 = @bitCast(x);
    return zv.ensures(y, (y == 1) == x);
}

// A pointer cast keeps the model's value only between pointees of one layout.

pub fn packPtr(a: u8, b: u8) u4 {
    var s = A16{ .lo = a, .hi = b };
    const p: *const B16 = @ptrCast(&s);
    return zv.ensures(p.n, p.n == a);
}

pub fn ptrNest0(a: [8]u8) u8 {
    const p: *const [2][4]u8 = @ptrCast(&a);
    return zv.ensures(p[1][0], p[1][0] == a[0]);
}

pub fn ptrNest1(a: [8]u8) u8 {
    const p: *const [2][4]u8 = @ptrCast(&a);
    return zv.ensures(p[1][0], p[1][0] == a[1]);
}

pub fn ptrNest4(a: [8]u8) u8 {
    const p: *const [2][4]u8 = @ptrCast(&a);
    return zv.ensures(p[1][0], p[1][0] == a[4]);
}

pub fn ptrWide(x: u16) u8 {
    const p: *const u16 = &x;
    const q: *const u8 = @ptrCast(p);
    return q.*;
}

pub fn ptrCastSame(x: u8) bool {
    const p: *const u8 = &x;
    const q: *const i8 = @ptrCast(p);
    return zv.ensures(q.* >= 0, q.* >= 0);
}

pub fn ptrSameOk(x: u8) bool {
    const p: *const u8 = &x;
    const q: *const i8 = @ptrCast(p);
    return zv.ensures(q.* < 0, (q.* < 0) == (x >= 128));
}

// A comptime parameter is not a parameter of the signature.

noinline fn plus1(comptime T: type, x: T) T {
    return x + 1;
}

pub fn incU8(x: u8) u8 {
    return zv.ensures(plus1(u8, x), plus1(u8, x) > x);
}

pub fn incU16(x: u16) u16 {
    zv.requires(x < 1000);
    return zv.ensures(plus1(u16, x), plus1(u16, x) == x + 1);
}

// A slice with a sentinel has it at its length.

pub fn sentinel0(xs: [:0]const u8) u8 {
    return zv.ensures(xs[xs.len], xs[xs.len] == 0);
}

pub fn sentinel1(xs: [:0]const u8) u8 {
    return zv.ensures(xs[xs.len], xs[xs.len] == 1);
}

pub fn sentinelCall(xs: [:0]const u8) u8 {
    return sentinel0(xs);
}

// A ghost value outside the 256-bit range is not a constant of the fragment; an operation that leaves it is refuted.

pub fn ghostMinMul(x: i128) bool {
    zv.requires(x == std.math.minInt(i128));
    if (!zv.ghost) return zv.ensures(true, true);
    const two128 = zv.Int.of(@as(u128, 1) << 127).mul(zv.Int.of(@as(u128, 2)));
    const wide = zv.Int.of(x).mul(two128);
    const q = wide.divFloor(zv.Int.of(-1));
    return zv.ensures(q.eq(q), true);
}

pub fn ghostMin() bool {
    if (!zv.ghost) return zv.ensures(true, true);
    const q = zv.Int.of(std.math.minInt(i256)).divFloor(zv.Int.of(@as(i8, -1)));
    return zv.ensures(q.eq(q), true);
}
