//! Cases for what zvc does beyond one straight-line function: calls through contracts, inlined contracts,
//! structs, optionals and errors, loop termination, ghost integers and sequences, and `switch`.
//! Each has a pinned verdict in `features.expect`. Not run: the unsound ones would panic.

const zv = @import("zv");

pub const assurance = .{
    .double = .verified,
    .useDouble = .verified,
    .useDoubleBadPre = .verified,
    .useDoubleNoPre = .verified,
    .chain = .verified,
    .hardware = .trusted,
    .useTrusted = .verified,
    .weak = .checked,
    .useWeak = .verified,
    .recursive = .verified,
    .mkPair = .verified,
    .swapPair = .verified,
    .useSwap = .verified,
    .bump = .verified,
    .bumpWrong = .verified,
    .orelseZero = .verified,
    .unwrapped = .verified,
    .checkedDiv = .verified,
    .viaTry = .verified,
    .viaTryNoGuard = .verified,
    .callsInline = .verified,
    .callsInlineBad = .verified,
    .countDown = .verified,
    .countStuck = .verified,
    .countUpGhost = .verified,
    .addNoWrap = .verified,
    .addMayWrap = .verified,
    .wideProduct = .verified,
    .seqPush = .verified,
    .seqOutOfRange = .verified,
    .classify = .verified,
    .classifyWrong = .verified,
    .sumSlice = .verified,
    .useSumSlice = .verified,
    .useSumSliceTail = .verified,
    .accumulate = .verified,
    .accumulateWrong = .verified,
    .tri = .verified,
};

// Calls through contracts.

pub fn double(x: u32) u32 {
    zv.requires(x <= 1000);
    return zv.ensures(x * 2, x * 2 >= x and x * 2 <= 2000);
}

pub fn useDouble(a: u32) u32 {
    zv.requires(a <= 500);
    const d = double(a * 2);
    return zv.ensures(d, d >= a);
}

pub fn useDoubleBadPre(a: u32) u32 {
    zv.requires(a <= 5000);
    return double(a);
}

pub fn useDoubleNoPre(a: u32) u32 {
    return double(a);
}

pub fn chain(a: u32) u32 {
    zv.requires(a <= 250);
    const d = double(a);
    const e = double(d);
    return zv.ensures(e, e >= a);
}

pub fn hardware(x: u8) u8 {
    zv.requires(x < 100);
    return zv.ensures(x, x < 100);
}

pub fn useTrusted(x: u8) u8 {
    zv.requires(x < 100);
    const y = hardware(x);
    return zv.ensures(y + 100, y + 100 < 200);
}

pub fn weak(x: u32) u32 {
    return x;
}

pub fn useWeak(x: u32) u32 {
    return weak(x);
}

pub fn recursive(n: u32) u32 {
    if (n == 0) return 0;
    return recursive(n - 1);
}

// Structs by value.

const Pair = struct { a: u32, b: u32 };

pub fn mkPair(a: u32, b: u32) Pair {
    const r: Pair = .{ .a = a, .b = b };
    return zv.ensures(r, r.a == a and r.b == b);
}

pub fn swapPair(p: Pair) Pair {
    const r: Pair = .{ .a = p.b, .b = p.a };
    return zv.ensures(r, r.a == p.b and r.b == p.a);
}

pub fn useSwap(a: u32, b: u32) u32 {
    const p = swapPair(mkPair(a, b));
    return zv.ensures(p.a, p.a == b);
}

pub fn bump(p: Pair) Pair {
    var q = p;
    q.a +%= 1;
    q.b = q.a;
    return zv.ensures(q, q.b == p.a +% 1);
}

pub fn bumpWrong(p: Pair) Pair {
    var q = p;
    q.a +%= 1;
    q.b = q.a;
    return zv.ensures(q, q.b == p.a);
}

// Optionals and errors.

pub fn orelseZero(x: ?u32) u32 {
    const r = x orelse 0;
    return zv.ensures(r, (x == null and r == 0) or (x != null and r == x.?));
}

pub fn unwrapped(x: ?u32) u32 {
    return x.?;
}

const Fail = error{Zero};

pub fn checkedDiv(a: u32, b: u32) Fail!u32 {
    if (b == 0) return error.Zero;
    return zv.ensures(a / b, a / b <= a);
}

pub fn viaTry(a: u32, b: u32) Fail!u32 {
    zv.requires(a < 1000);
    const q = try checkedDiv(a, b);
    return q + 1;
}

pub fn viaTryNoGuard(a: u32, b: u32) Fail!u32 {
    const q = try checkedDiv(a, b);
    return q + 1;
}

// Inlined contracts: the callee's requires are the caller's obligations.

inline fn needsSmall(x: u32) u32 {
    zv.requires(x < 100);
    return x + 1;
}

pub fn callsInline(x: u32) u32 {
    zv.requires(x < 50);
    return needsSmall(x * 2);
}

pub fn callsInlineBad(x: u32) u32 {
    return needsSmall(x);
}

// Termination.

pub fn countDown(n: u32) u32 {
    var i = n;
    while (i > 0) : (i -= 1) {
        zv.invariant(i <= n);
        zv.decreases(i);
    }
    return zv.ensures(i, i == 0);
}

pub fn countStuck(n: u32) u32 {
    var i = n;
    while (i > 0) {
        zv.invariant(i <= n);
        zv.decreases(i);
        if (i > 3) i -= 1;
    }
    return i;
}

pub fn countUpGhost(n: u32) u32 {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        zv.invariant(i <= n);
        if (zv.ghost) zv.decreases(zv.Int.of(n).sub(zv.Int.of(i)));
    }
    return zv.ensures(i, i == n);
}

// Ghost integers and sequences.

pub fn addNoWrap(a: u32, b: u32) u32 {
    zv.requires(!zv.ghost or zv.Int.of(a).add(zv.Int.of(b)).le(zv.Int.of(0xffffffff)));
    return a + b;
}

pub fn addMayWrap(a: u32, b: u32) u32 {
    zv.requires(!zv.ghost or zv.Int.of(a).add(zv.Int.of(b)).le(zv.Int.of(0x1ffffffff)));
    return a + b;
}

pub fn wideProduct(x: u32, y: u32) u64 {
    const r = @as(u64, x) * y;
    return zv.ensures(r, !zv.ghost or zv.Int.of(r).le(zv.Int.of(x).mul(zv.Int.of(y))));
}

pub fn seqPush(a: u8, b: u8) u8 {
    const s = if (zv.ghost) zv.Seq.empty().push(zv.Int.of(a)).push(zv.Int.of(b)) else {};
    return zv.ensures(b, !zv.ghost or (s.len().eq(zv.Int.of(2)) and s.at(zv.Int.of(0)).eq(zv.Int.of(a)) and s.at(zv.Int.of(1)).eq(zv.Int.of(b))));
}

pub fn seqOutOfRange(a: u8) u8 {
    const s = if (zv.ghost) zv.Seq.empty().push(zv.Int.of(a)) else {};
    return zv.ensures(a, !zv.ghost or s.at(zv.Int.of(1)).eq(zv.Int.of(a)));
}

// switch.

pub fn classify(x: u8) u8 {
    const r: u8 = switch (x) {
        0 => 1,
        1...9 => 2,
        10, 20 => 3,
        else => 4,
    };
    return zv.ensures(r, (x == 0) == (r == 1) and (x >= 1 and x <= 9) == (r == 2));
}

pub fn classifyWrong(x: u8) u8 {
    const r: u8 = switch (x) {
        0 => 1,
        1...9 => 2,
        10, 20 => 3,
        else => 4,
    };
    return zv.ensures(r, (x == 0) == (r == 1) and (x >= 1 and x <= 10) == (r == 2));
}

// A callee that reads a slice, called on a sub-slice.

pub fn sumSlice(xs: []const u8) u32 {
    zv.requires(xs.len <= 1000);
    var s: u32 = 0;
    var i: usize = 0;
    while (i < xs.len) : (i += 1) {
        zv.invariant(i <= xs.len and s <= i * 255);
        zv.decreases(xs.len - i);
        s += xs[i];
    }
    return zv.ensures(s, s <= xs.len * 255);
}

pub fn useSumSlice(xs: []const u8) u32 {
    zv.requires(xs.len <= 1000);
    const s = sumSlice(xs);
    return zv.ensures(s, s <= 255000);
}

pub fn useSumSliceTail(xs: []const u8) u32 {
    zv.requires(xs.len >= 1 and xs.len <= 1000);
    const s = sumSlice(xs[1..]);
    return zv.ensures(s, s <= 255000);
}

// Structs changed in a loop, and a three-way join.

pub fn accumulate(p: Pair, n: u32) Pair {
    zv.requires(n <= 100 and p.a <= 1000 and p.b <= 1000);
    var q = p;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        zv.invariant(i <= n and q.a <= 1000 + i * 10 and q.b <= 1000 + i * 10);
        zv.decreases(n - i);
        q.a += 10;
        q.b += 10;
    }
    return zv.ensures(q, q.a <= 2000 and q.b <= 2000);
}

pub fn accumulateWrong(p: Pair, n: u32) Pair {
    zv.requires(n <= 100 and p.a <= 1000 and p.b <= 1000);
    var q = p;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        zv.invariant(i <= n and q.a <= 1000 + i * 10 and q.b <= 1000 + i * 10);
        zv.decreases(n - i);
        q.a += 10;
        q.b += 10;
    }
    return zv.ensures(q, q.a <= 1500 and q.b <= 2000);
}

pub fn tri(x: u8) u8 {
    var r: u8 = 0;
    if (x < 10) {
        r = 1;
    } else if (x < 20) {
        r = 2;
    } else {
        r = 3;
    }
    return zv.ensures(r, r >= 1 and r <= 3 and (r == 1) == (x < 10));
}
