//! Cases for `zv.PointsTo` permission tokens (docs/phase4.md): what zvc must refuse to prove about a program that
//! forges a token, uses one after it was consumed, hands out overlapping or misaligned memory, or leaves the
//! region; and the controls that show the correct programs are still proved. Verdicts are pinned in
//! `tokens.expect`. Ghost builds only (a token is `void` elsewhere); not run: the unsound ones would panic.

const zv = @import("zv");

pub const assurance = .{
    .take = .verified,
    .give = .verified,
    .roundTrip = .verified,
    .leak = .verified,
    .twoMints = .verified,
    .takeStuck = .verified,
    .takeKeepsOld = .verified,
    .takeOutside = .verified,
    .takeMisaligned = .verified,
    .giveTwice = .verified,
    .readAfterGive = .verified,
    .copyThenGive = .verified,
    .giveBoth = .verified,
    .giveBoth2 = .verified,
    .returnConsumed = .verified,
    .splitTwice = .verified,
    .joinGap = .verified,
    .forgeLiteral = .verified,
    .fakeToken = .checked,
    .forgeViaChecked = .verified,
    .maybeGive = .verified,
    .forgeField = .verified,
    .forgeAgain = .verified,
    .loopConsume = .verified,
    .dupResult = .verified,
    .useHolder = .verified,
    .optionalBoth = .verified,
    .twoFieldsPassed = .verified,
    .storedTwice = .verified,
    .errorUnionBoth = .verified,
    .pointeeAndResult = .verified,
    .arrayOfTokens = .verified,
    .loopCarried = .verified,
};

comptime {
    zv.requireAssurance(@This(), .checked);
}

pub const Region = struct { cap: usize, next: usize, free: zv.PointsTo };
pub const Piece = struct { lo: usize, hi: usize, perm: zv.PointsTo };
pub const Taken = struct { region: Region, piece: ?Piece };

inline fn sound(r: Region) bool {
    return r.next <= r.cap and r.free.lo() == r.next and r.free.hi() == r.cap;
}

inline fn tied(p: Piece) bool {
    return p.lo <= p.hi and p.perm.lo() == p.lo and p.perm.hi() == p.hi;
}

inline fn startsAligned(t: Taken, alignment: usize) bool {
    const p = t.piece orelse return false;
    return p.lo & (alignment -% 1) == 0;
}

inline fn took(old: Region, t: Taken) bool {
    const p = t.piece orelse return false;
    return sound(t.region) and tied(p) and p.lo == old.next and p.hi == t.region.next and t.region.cap == old.cap and p.lo <= p.hi;
}

// Controls: the correct programs.

/// Takes the next `n` bytes of the region. Proved: in bounds, the piece ends where the region now starts.
pub fn take(r: Region, n: usize) Taken {
    zv.requires(sound(r) and n <= r.cap -% r.next);
    const end = r.next + n;
    const parts = r.free.split(end);
    const t: Taken = .{
        .region = .{ .cap = r.cap, .next = end, .free = parts.tail },
        .piece = .{ .lo = r.next, .hi = end, .perm = parts.head },
    };
    return zv.ensures(t, took(r, t));
}

/// Gives the last piece back.
pub fn give(r: Region, p: Piece) Region {
    zv.requires(sound(r) and tied(p) and p.hi == r.next);
    const out: Region = .{ .cap = r.cap, .next = p.lo, .free = p.perm.join(r.free) };
    return zv.ensures(out, sound(out) and out.cap == r.cap and out.next == p.lo);
}

/// A token cut in two and joined again is the same range.
pub fn roundTrip(p: zv.PointsTo, cut: usize) zv.PointsTo {
    zv.requires(p.lo() <= cut and cut <= p.hi());
    const lo = p.lo();
    const hi = p.hi();
    const parts = p.split(cut);
    const back = parts.head.join(parts.tail);
    return zv.ensures(back, back.lo() == lo and back.hi() == hi);
}

/// Dropping a token is not a memory error (a leak is `zv-own`'s to report), so it is proved.
pub fn leak(r: Region, n: usize) usize {
    zv.requires(sound(r) and n <= r.cap -% r.next);
    const t = take(r, n);
    const p = t.piece orelse return 0;
    return zv.ensures(p.hi, p.hi == r.next + n);
}

/// Taking ownership of memory is a premise, named in the verdict and counted by `--max-assume`.
pub fn twoMints(a: []u8, b: []u8) usize {
    const x = zv.PointsTo.own(a);
    const y = zv.PointsTo.own(b);
    return zv.ensures(x.hi(), x.hi() == a.len and y.hi() == b.len);
}

// Overlap, reuse and leaving the region.

/// The region does not move on: the next request is handed the bytes of this piece again.
pub fn takeStuck(r: Region, n: usize) Taken {
    zv.requires(sound(r) and n <= r.cap -% r.next);
    const end = r.next + n;
    const parts = r.free.split(end);
    const t: Taken = .{
        .region = .{ .cap = r.cap, .next = r.next, .free = parts.tail },
        .piece = .{ .lo = r.next, .hi = end, .perm = parts.head },
    };
    return zv.ensures(t, took(r, t));
}

/// Returns the old region, whose token was cut: the same memory is then owned twice.
pub fn takeKeepsOld(r: Region, n: usize) Taken {
    zv.requires(sound(r) and n <= r.cap -% r.next);
    const end = r.next + n;
    const parts = r.free.split(end);
    const t: Taken = .{ .region = r, .piece = .{ .lo = r.next, .hi = end, .perm = parts.head } };
    return zv.ensures(t, if (t.piece) |_| true else false);
}

/// No check against the capacity.
pub fn takeOutside(r: Region, n: usize) Taken {
    zv.requires(sound(r));
    const end = r.next +% n;
    const parts = r.free.split(end);
    const t: Taken = .{
        .region = .{ .cap = r.cap, .next = end, .free = parts.tail },
        .piece = .{ .lo = r.next, .hi = end, .perm = parts.head },
    };
    return zv.ensures(t, took(r, t));
}

/// Claims the piece is aligned without padding to make it so.
pub fn takeMisaligned(r: Region, n: usize, alignment: usize) Taken {
    zv.requires(sound(r) and n <= r.cap -% r.next and alignment != 0 and alignment & (alignment -% 1) == 0);
    const end = r.next + n;
    const parts = r.free.split(end);
    const t: Taken = .{
        .region = .{ .cap = r.cap, .next = end, .free = parts.tail },
        .piece = .{ .lo = r.next, .hi = end, .perm = parts.head },
    };
    return zv.ensures(t, took(r, t) and startsAligned(t, alignment));
}

/// Gives the same piece back twice: after the first `give` its token is gone.
pub fn giveTwice(r: Region, p: Piece) Region {
    zv.requires(sound(r) and tied(p) and p.hi == r.next);
    const once = give(r, p);
    return give(once, p);
}

/// Reads the token of a piece that was given back.
pub fn readAfterGive(r: Region, p: Piece) usize {
    zv.requires(sound(r) and tied(p) and p.hi == r.next);
    const back = give(r, p);
    return zv.ensures(back.next, p.perm.lo() == p.lo);
}

/// A copy of a token is the token: giving it back leaves nothing to give through the original.
pub fn copyThenGive(r: Region, p: Piece) Region {
    zv.requires(sound(r) and tied(p) and p.hi == r.next);
    const copy = p;
    const once = give(r, copy);
    return give(once, p);
}

pub fn giveBoth2(r: Region, a: Piece, b: Piece) Region {
    zv.requires(sound(r) and tied(a) and a.hi == r.next);
    _ = b;
    return give(r, a);
}

/// One piece twice in the same call.
pub fn giveBoth(r: Region, p: Piece) Region {
    zv.requires(sound(r) and tied(p) and p.hi == r.next);
    return giveBoth2(r, p, p);
}

/// Returns a piece whose token went back to the region.
pub fn returnConsumed(r: Region, p: Piece) Taken {
    zv.requires(sound(r) and tied(p) and p.hi == r.next);
    const back = give(r, p);
    const t: Taken = .{ .region = back, .piece = p };
    return t;
}

/// Cuts one token twice.
pub fn splitTwice(p: zv.PointsTo, a: usize, b: usize) usize {
    zv.requires(p.lo() <= a and a <= p.hi() and p.lo() <= b and b <= p.hi());
    const x = p.split(a);
    const y = p.split(b);
    return zv.ensures(x.head.hi(), y.head.lo() == p.lo());
}

/// Joins two pieces that do not meet.
pub fn joinGap(p: zv.PointsTo, a: usize, b: usize) zv.PointsTo {
    zv.requires(p.lo() <= a and a < b and b <= p.hi());
    const first = p.split(a);
    const second = first.tail.split(b);
    return first.head.join(second.tail);
}

// Forging.

/// A token from a function that is only checked: whatever it builds, a proof may not rest on it.
pub fn fakeToken(n: usize) zv.PointsTo {
    const p: zv.PointsTo = .{ .from = 0, .to = n };
    return p;
}

pub fn forgeViaChecked(n: usize) usize {
    const p = fakeToken(n);
    return zv.ensures(p.hi(), p.hi() == n);
}

/// Gives a piece back on one path only, then reads its token: it may be gone.
pub fn maybeGive(r: Region, p: Piece, c: bool) usize {
    zv.requires(sound(r) and tied(p) and p.hi == r.next);
    var next = r.next;
    if (c) {
        const back = give(r, p);
        next = back.next;
    }
    return zv.ensures(next, p.perm.lo() == p.lo);
}

/// A token written out as a literal.
pub fn forgeLiteral(n: usize) Piece {
    const p: Piece = .{ .lo = 0, .hi = n, .perm = .{ .from = 0, .to = n } };
    return p;
}

/// A token whose range is changed after the fact.
pub fn forgeField(p: Piece) Piece {
    var perm = p.perm;
    perm.to = 1000;
    return .{ .lo = p.lo, .hi = 1000, .perm = perm };
}

/// A token made by copying fields into a new one.
pub fn forgeAgain(p: Piece) zv.PointsTo {
    const same: zv.PointsTo = .{ .from = p.perm.lo(), .to = p.perm.hi() };
    return same;
}

/// A loop that consumes a token it did not make: the second iteration has none.
pub fn loopConsume(r: Region, p: Piece, k: u8) Region {
    zv.requires(sound(r) and tied(p) and p.hi == r.next);
    var out = r;
    var i: u8 = 0;
    while (i < k) : (i += 1) {
        zv.invariant(i <= k);
        out = give(r, p);
    }
    return out;
}

pub const Both = struct { a: zv.PointsTo, b: zv.PointsTo };

/// One token given back twice: the caller would own the same memory twice.
pub fn dupResult(p: zv.PointsTo) Both {
    const t: Both = .{ .a = p, .b = p };
    return t;
}

// Ways a token can flow, each tried to be used twice.

pub const Holder = struct { a: zv.PointsTo, b: zv.PointsTo };

pub fn useHolder(h: Holder) void {
    h.a.discard();
    h.b.discard();
}

/// Held in an optional that is unwrapped and kept.
pub fn optionalBoth(p: zv.PointsTo) zv.PointsTo {
    const o: ?zv.PointsTo = p;
    if (o) |q| q.discard();
    return p;
}

/// Two fields of one struct, passed on.
pub fn twoFieldsPassed(p: zv.PointsTo) void {
    const h: Holder = .{ .a = p, .b = p };
    useHolder(h);
}

/// Stored into two fields one after the other, then each consumed.
pub fn storedTwice(p: zv.PointsTo) void {
    var h: Holder = undefined;
    h.a = p;
    h.b = p;
    h.a.discard();
    h.b.discard();
}

/// Through an error union that is also kept.
pub fn errorUnionBoth(p: zv.PointsTo, fail: bool) error{Failed}!zv.PointsTo {
    if (fail) return error.Failed;
    p.discard();
    return p;
}

/// Through the pointee of a pointer parameter and the result.
pub fn pointeeAndResult(h: *Holder) zv.PointsTo {
    return h.a;
}

/// An array of tokens: not in the fragment.
pub fn arrayOfTokens(p: zv.PointsTo, q: zv.PointsTo) usize {
    const both = [2]zv.PointsTo{ p, q };
    return both[1].lo();
}

/// Carried round a loop without being consumed or copied.
pub fn loopCarried(p: zv.PointsTo, k: u8) zv.PointsTo {
    var t = p;
    var i: u8 = 0;
    while (i < k) : (i += 1) {
        zv.invariant(i <= k);
        zv.decreases(k - i);
        t = t;
    }
    return t;
}
