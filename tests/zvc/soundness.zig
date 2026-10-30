//! Cases from the soundness review (docs/reviews/zvc-soundness-1.md). Each one was `proved` while a Debug run
//! panicked, or guards the fix of a flaw that could have been. Verdicts are pinned in `soundness.expect` and,
//! for a run that selects one function, in `soundness.only.expect`. Not run: the unsound ones would panic.

const zv = @import("zv");

pub const assurance = .{
    .badAdd = .trusted,
    .useBadAdd = .verified,
    .inc = .verified,
    .useInc = .verified,
    .useUseInc = .verified,
    .safeInc = .verified,
    .useSafeInc = .verified,
    .ghostMul = .verified,
    .ghostMulWide = .verified,
    .ghostNeg = .verified,
    .ghostAdd = .verified,
    .seqFull = .verified,
    .seqOverfull = .verified,
    .bigPos = .verified,
    .bigPosIs = .verified,
    .bigNeg = .verified,
    .bigNegIs = .verified,
    .bigWide = .verified,
    .bigU128 = .verified,
    .divMin128 = .verified,
    .div128 = .verified,
    .cmpSign = .verified,
    .divSign = .verified,
    .errCollide = .verified,
    .errSame = .verified,
    .boolInt = .verified,
};

// A caller relies on a callee's contract, so the callee must hold up.

pub fn badAdd(x: u8) u8 {
    return x + 1;
}

pub fn useBadAdd(x: u8) u8 {
    return badAdd(x);
}

pub fn inc(x: u8) u8 {
    return zv.ensures(x + 1, true);
}

pub fn useInc(x: u8) u8 {
    return inc(x);
}

pub fn useUseInc(x: u8) u8 {
    return useInc(x);
}

pub fn safeInc(x: u8) u8 {
    zv.requires(x < 255);
    return zv.ensures(x + 1, true);
}

pub fn useSafeInc(x: u8) u8 {
    return if (x < 255) safeInc(x) else x;
}

// A ghost integer is as wide in the proof as it is when run.

pub fn ghostMul(a: u64, b: u64) bool {
    const ok = zv.Int.of(a).mul(zv.Int.of(b)).ge(zv.Int.of(0));
    return zv.ensures(ok, ok);
}

pub fn ghostMulWide(a: u128) bool {
    const k: u128 = 1 << 127;
    const ok = zv.Int.of(a).mul(zv.Int.of(k)).mul(zv.Int.of(2)).ge(zv.Int.of(0));
    return zv.ensures(ok, ok);
}

pub fn ghostNeg(x: i128) bool {
    const ok = zv.Int.of(x).neg().eq(zv.Int.of(0).sub(zv.Int.of(x)));
    return zv.ensures(ok, ok);
}

pub fn ghostAdd(x: i128, y: i128) bool {
    zv.requires(y >= 0);
    const ok = zv.Int.of(x).add(zv.Int.of(y)).ge(zv.Int.of(x));
    return zv.ensures(ok, ok);
}

// A ghost sequence holds as many elements in the proof as it does when run.

pub fn seqFull() bool {
    var s = zv.Seq.empty();
    inline for (0..zv.Seq.capacity) |_| {
        s = s.push(zv.Int.of(1));
    }
    const ok = s.len().eq(zv.Int.of(zv.Seq.capacity));
    return zv.ensures(ok, ok);
}

pub fn seqOverfull() bool {
    var s = zv.Seq.empty();
    inline for (0..zv.Seq.capacity + 1) |_| {
        s = s.push(zv.Int.of(1));
    }
    return zv.ensures(true, true);
}

// Constants wider than 64 bits are the numbers they are written as.

pub fn bigPos(x: i128) u8 {
    zv.requires(x == 9223372036854775808);
    const y: u8 = if (x > 0) 255 else 0;
    return y + 1;
}

pub fn bigPosIs(x: i128) bool {
    zv.requires(x == 9223372036854775808);
    const r = x > 0;
    return zv.ensures(r, r);
}

pub fn bigNeg(x: i128) u8 {
    zv.requires(x == -9223372036854775808);
    const y: u8 = if (x < 0) 255 else 0;
    return y + 1;
}

pub fn bigNegIs(x: i128) bool {
    zv.requires(x == -9223372036854775808);
    const r = x < 0;
    return zv.ensures(r, r);
}

pub fn bigWide(x: i65) u8 {
    zv.requires(x == 9223372036854775808);
    const y: u8 = if (x > 0) 255 else 0;
    return y + 1;
}

pub fn bigU128(x: u128) u8 {
    zv.requires(x == 18446744073709551616);
    const y: u8 = if (x > 18446744073709551615) 255 else 0;
    return y + 1;
}

pub fn divMin128(a: i128) i128 {
    return @divTrunc(a, -1);
}

pub fn div128(a: i128, b: i128) i128 {
    zv.requires(b != 0);
    return @divTrunc(a, b);
}

// A signed value is shown signed, and divides and compares as one.

pub fn cmpSign(x: i8) bool {
    zv.requires(x == -1);
    const r = x < 0;
    return zv.ensures(r, r == false);
}

pub fn divSign(a: i8, b: i8) i8 {
    zv.requires(a == -5 and b == 2);
    const r = @divTrunc(a, b);
    return zv.ensures(r, r == 125);
}

// Two errors are two codes.

pub fn errCollide(e: anyerror!u8) u8 {
    if (e) |v| {
        return v;
    } else |err| {
        const r: u8 = if (err == error.E204) 1 else 0;
        return zv.ensures(r, err != error.E349 or r == 1);
    }
}

pub fn errSame(e: anyerror!u8) u8 {
    if (e) |v| {
        return v;
    } else |err| {
        const r: u8 = if (err == error.E204) 1 else 0;
        return zv.ensures(r, err != error.E204 or r == 1);
    }
}

// A bool cast to an integer is the integer.

pub fn boolInt(b: bool) u8 {
    const x: u8 = @intFromBool(b);
    return x + 255;
}
