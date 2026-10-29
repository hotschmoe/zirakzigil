//! Cases for the verifier, each with a pinned verdict in `cases.expect`. Not run: the unsound ones would panic.
//! A change to what zvc proves or refutes here is a change to its soundness or completeness and is reviewed as one.

const zv = @import("zv");

pub const assurance = .{
    .addChecked = .verified,
    .addUnchecked = .verified,
    .absDiff = .verified,
    .negate = .verified,
    .negateMin = .verified,
    .divide = .verified,
    .divideNoGuard = .verified,
    .signedDivide = .verified,
    .signedDivideGuarded = .verified,
    .byteAt = .verified,
    .byteAtOffByOne = .verified,
    .narrow = .verified,
    .narrowNoGuard = .verified,
    .countUp = .verified,
    .countUpBadEntry = .verified,
    .countUpBadStep = .verified,
    .countUpNoInvariant = .verified,
    .sumWrapping = .verified,
    .mulBytes = .verified,
    .mulBytesWide = .verified,
    .shiftRight = .verified,
    .claimsTooMuch = .verified,
    .unreachableGuarded = .verified,
    .unreachableOpen = .verified,
    .firstZero = .verified,
    .twoLoops = .verified,
    .nestedLoops = .verified,
    .swapFields = .verified,
    .optionalOr = .verified,
    .maxOf = .verified,
    .floatUse = .verified,
    .clamp = .verified,
};

pub fn addChecked(a: u32, b: u32) u32 {
    zv.requires(a <= 100 and b <= 100);
    return zv.ensures(a + b, a + b >= a);
}

pub fn addUnchecked(a: u32, b: u32) u32 {
    return a + b;
}

pub fn absDiff(a: u32, b: u32) u32 {
    const r = if (a > b) a - b else b - a;
    return zv.ensures(r, r <= a or r <= b);
}

pub fn negate(x: i32) i32 {
    zv.requires(x != -2147483648);
    return -x;
}

pub fn negateMin(x: i32) i32 {
    return -x;
}

pub fn divide(a: u32, b: u32) u32 {
    zv.requires(b != 0);
    return zv.ensures(a / b, a / b <= a);
}

pub fn divideNoGuard(a: u32, b: u32) u32 {
    return a / b;
}

pub fn signedDivide(a: i32, b: i32) i32 {
    zv.requires(b != 0);
    return @divTrunc(a, b);
}

pub fn signedDivideGuarded(a: i32, b: i32) i32 {
    zv.requires(b != 0 and b != -1);
    return zv.ensures(@divTrunc(a, b), true);
}

pub fn byteAt(xs: []const u8, i: usize) u8 {
    zv.requires(i < xs.len);
    return xs[i];
}

pub fn byteAtOffByOne(xs: []const u8, i: usize) u8 {
    zv.requires(i <= xs.len);
    return xs[i];
}

pub fn narrow(x: u32) u8 {
    zv.requires(x <= 255);
    return @intCast(x);
}

pub fn narrowNoGuard(x: u32) u8 {
    return @intCast(x);
}

pub fn countUp(n: u32) u32 {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        zv.invariant(i <= n);
    }
    return zv.ensures(i, i == n);
}

pub fn countUpBadEntry(n: u32) u32 {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        zv.invariant(i > 0);
    }
    return i;
}

pub fn countUpBadStep(n: u32) u32 {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        zv.invariant(i <= 5);
    }
    return i;
}

pub fn countUpNoInvariant(n: u32) u32 {
    var i: u32 = 0;
    while (i < n) : (i += 1) {}
    return zv.ensures(i, i == n);
}

pub fn sumWrapping(xs: []const u8) u32 {
    var s: u32 = 0;
    var i: usize = 0;
    while (i < xs.len) : (i += 1) {
        zv.invariant(i <= xs.len);
        s +%= xs[i];
    }
    return s;
}

pub fn mulBytes(a: u8, b: u8) u16 {
    return @as(u16, a) * @as(u16, b);
}

pub fn mulBytesWide(a: u8, b: u8) u8 {
    return a * b;
}

pub fn shiftRight(x: u32) u32 {
    const r = x >> 3;
    return zv.ensures(r, r <= x);
}

pub fn claimsTooMuch(x: u32) u32 {
    const r = x +% 1;
    return zv.ensures(r, r > x);
}

pub fn unreachableGuarded(x: u32) u32 {
    zv.requires(x <= 5);
    if (x > 5) unreachable;
    return x;
}

pub fn unreachableOpen(x: u32) u32 {
    if (x > 5) unreachable;
    return x;
}

pub fn firstZero(xs: []const u8) usize {
    var i: usize = 0;
    while (i < xs.len) : (i += 1) {
        zv.invariant(i <= xs.len);
        if (xs[i] == 0) break;
    }
    return zv.ensures(i, i <= xs.len);
}

pub fn twoLoops(n: u32) u32 {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        zv.invariant(i <= n);
    }
    var j: u32 = 0;
    while (j < i) : (j += 1) {
        zv.invariant(j <= i);
    }
    return zv.ensures(j, j == n);
}

pub fn nestedLoops(n: u8, m: u8) u32 {
    var i: u8 = 0;
    var total: u32 = 0;
    while (i < n) : (i += 1) {
        zv.invariant(i <= n and total <= @as(u32, i) * 255);
        var j: u8 = 0;
        while (j < m) : (j += 1) {
            zv.invariant(j <= m);
            total +%= 1;
        }
    }
    return total;
}

const Pair = struct { a: u32, b: u32 };

pub fn swapFields(p: Pair) Pair {
    const r: Pair = .{ .a = p.b, .b = p.a };
    return zv.ensures(r, r.a == p.b and r.b == p.a);
}

pub fn optionalOr(x: ?u32) u32 {
    const r = x orelse 7;
    return zv.ensures(r, x == null or r == x.?);
}

pub fn maxOf(a: u32, b: u32) u32 {
    const r = @max(a, b);
    return zv.ensures(r, r >= a and r >= b and (r == a or r == b));
}

pub fn floatUse(x: f32) f32 {
    return x + 1;
}

pub fn clamp(x: i32, lo: i32, hi: i32) i32 {
    zv.requires(lo <= hi);
    const r = if (x < lo) lo else if (x > hi) hi else x;
    return zv.ensures(r, lo <= r and r <= hi);
}
