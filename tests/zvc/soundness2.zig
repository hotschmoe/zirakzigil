//! Cases from the second soundness review (docs/reviews/zvc-soundness-2.md). Each one was `proved` while a Debug
//! run panicked or failed its `zv.ensures`, or guards the fix of a flaw that could have been. Verdicts are pinned
//! in `soundness2.expect`. Not run: the unsound ones would panic.

const std = @import("std");
const zv = @import("zv");

pub const assurance = .{
    .seqSubWrap = .verified,
    .seqSubMax = .verified,
    .seqSubOk = .verified,
    .ghostDivOv = .verified,
    .ghostModOv = .verified,
    .ghostDivOk = .verified,
    .lenBound = .verified,
    .lenPlus = .verified,
    .lenWrapEns = .verified,
    .lenTriple = .verified,
    .useLenBound = .verified,
    .assumeCheat = .verified,
    .useAssume = .verified,
    .ptrCastLoad = .verified,
    .shiftU8 = .verified,
    .shiftU24 = .verified,
    .shiftI65 = .verified,
    .shiftU96 = .verified,
    .shiftI128 = .verified,
    .shiftOff = .verified,
    .wrapOff = .verified,
};

// Ghost index arithmetic does not wrap, and a ghost operation carries every check of the body it stands for.

pub fn seqSubWrap(a: u128) bool {
    zv.requires(a == (@as(u128, 1) << 127));
    const big = zv.Int.of(a).mul(zv.Int.of(a));
    const t = zv.Seq.empty().sub(big, big);
    const ok = t.len().ge(zv.Int.of(0));
    return zv.ensures(ok, ok);
}

pub fn seqSubMax(a: u128) bool {
    zv.requires(a == (@as(u128, 1) << 127));
    const big = zv.Int.of(a).mul(zv.Int.of(a));
    const max = big.add(big.sub(zv.Int.of(1)));
    const t = zv.Seq.empty().sub(max, zv.Int.of(1));
    const ok = t.len().ge(zv.Int.of(0));
    return zv.ensures(ok, ok);
}

pub fn seqSubOk(n: u8) bool {
    zv.requires(n <= 4);
    var s = zv.Seq.empty();
    inline for (0..4) |i| s = s.push(zv.Int.of(i));
    const t = s.sub(zv.Int.of(0), zv.Int.of(n));
    const ok = t.len().eq(zv.Int.of(n));
    return zv.ensures(ok, ok);
}

pub fn ghostDivOv(x: i128) bool {
    zv.requires(x == std.math.minInt(i128));
    const two128 = zv.Int.of(@as(u128, 1) << 127).mul(zv.Int.of(@as(u128, 2)));
    const wide = zv.Int.of(x).mul(two128);
    const q = wide.divFloor(zv.Int.of(-1));
    return zv.ensures(q.eq(q), true);
}

pub fn ghostModOv(x: i128) bool {
    zv.requires(x == std.math.minInt(i128));
    const two128 = zv.Int.of(@as(u128, 1) << 127).mul(zv.Int.of(@as(u128, 2)));
    const wide = zv.Int.of(x).mul(two128);
    const r = wide.mod(zv.Int.of(-1));
    return zv.ensures(r.eq(r), true);
}

pub fn ghostDivOk(x: i128) bool {
    zv.requires(x == std.math.minInt(i128));
    const q = zv.Int.of(x).divFloor(zv.Int.of(-1));
    const ok = q.gt(zv.Int.of(0));
    return zv.ensures(ok, ok);
}

// A slice may be as long as the address space allows: nothing is assumed of its length.

pub fn lenBound(xs: []const u8) bool {
    const ok = xs.len < (@as(usize, 1) << 63);
    return zv.ensures(ok, ok);
}

pub fn lenPlus(xs: []const u8) usize {
    return xs.len + xs.len;
}

pub fn lenWrapEns(xs: []const u8) usize {
    const s = xs.len +% xs.len;
    return zv.ensures(s, s >= xs.len);
}

pub fn lenTriple(xs: []const u16) usize {
    return xs.len + xs.len + xs.len;
}

pub fn useLenBound(xs: []const u8) bool {
    return lenBound(xs);
}

// A premise is named in the verdict, in the caller's too, and counted.

pub fn assumeCheat(x: u8) u8 {
    zv.assume(x < 255);
    return x + 1;
}

pub fn useAssume(x: u8) u8 {
    return assumeCheat(x);
}

// A pointer cast between integer widths is not an identity.

pub fn ptrCastLoad(x: u16) u8 {
    const p: *const u16 = &x;
    const q: *const u8 = @ptrCast(p);
    const b = q.*;
    return zv.ensures(b, b == @as(u8, @truncate(x)));
}

// A shift amount is checked by the model, with or without the compiler's own check.

pub fn shiftU8(x: u8, n: u8) u8 {
    return x << @as(u3, @intCast(n));
}

pub fn shiftU24(x: u24, n: u5) u24 {
    return x << n;
}

pub fn shiftI65(x: i65, n: u7) i65 {
    return x << n;
}

pub fn shiftU96(x: u96, n: u7) u96 {
    return x >> n;
}

pub fn shiftI128(x: i128, n: u7) i128 {
    return zv.ensures(x >> n, x >= 0 or (x >> n) < 0);
}

pub fn shiftOff(x: u24, n: u5) u24 {
    @setRuntimeSafety(false);
    return x << n;
}

// With safety off an overflow is not a panic, and not a defined wrap either.

pub fn wrapOff(a: u8, b: u8) u8 {
    @setRuntimeSafety(false);
    const s = a + b;
    return zv.ensures(s, s >= a);
}
