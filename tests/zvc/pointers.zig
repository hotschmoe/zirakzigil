//! Cases for pointer-to-struct parameters (`*Self`, docs/phase4.md M2): what a call may rely on of the pointee, what
//! it may not, and the tokens that live in a field of the pointee. Verdicts are pinned in `pointers.expect`. Ghost
//! builds only; not run: the unsound ones would panic.

const zv = @import("zv");

pub const Wrap = struct { a: R, b: R };

pub const R = struct {
    cap: usize,
    next: usize,
    spare: zv.PointsTo,

    pub const assurance = .{
        .setNext = .verified,
        .useSet = .verified,
        .keepsCap = .verified,
        .take = .verified,
        .forward = .verified,
        .readOnly = .verified,
        .useReadOnly = .verified,
        .sneaky = .verified,
        .claimsCap = .verified,
        .useSneaky = .verified,
        .loopWrites = .verified,
        .useLoopWrites = .verified,
        .same = .verified,
        .callSame = .verified,
        .callSameField = .verified,
        .callFieldsApart = .verified,
        .callApart = .verified,
        .dropSpare = .verified,
        .readSpareTwice = .verified,
        .holdAcrossCall = .verified,
        .forgeSpare = .verified,
        .intPointee = .verified,
    };

    inline fn sound(r: R) bool {
        return r.next <= r.cap and r.spare.lo == r.next and r.spare.hi == r.cap;
    }

    // Controls.

    pub fn setNext(self: *R, n: usize) void {
        self.next = n;
        return zv.ensures({}, self.next == n);
    }

    /// What the callee changed is what it said.
    pub fn useSet(self: *R) bool {
        self.setNext(7);
        return zv.ensures(true, self.next == 7);
    }

    /// What it did not touch is what the caller had.
    pub fn keepsCap(self: *R) bool {
        const c = self.cap;
        self.setNext(7);
        return zv.ensures(true, self.cap == c);
    }

    /// The token in a field is cut and the tail put back.
    pub fn take(self: *R, n: usize) usize {
        zv.requires(sound(self.*) and n <= self.cap -% self.next);
        const end = self.next + n;
        const start = self.next;
        const parts = self.spare.split(end);
        self.spare = parts.tail;
        self.next = end;
        parts.head.discard();
        return zv.ensures(start, sound(self.*) and self.next == end);
    }

    pub fn forward(self: *R, n: usize) bool {
        zv.requires(sound(self.*) and n <= self.cap -% self.next);
        _ = self.take(n);
        return zv.ensures(true, sound(self.*));
    }

    pub fn readOnly(self: *const R) usize {
        return self.cap -% self.next;
    }

    pub fn useReadOnly(self: *R) bool {
        const before = self.next;
        _ = self.readOnly();
        return zv.ensures(true, self.next == before);
    }

    // Frame: a callee changes only what it says, and the caller learns all of it.

    pub fn sneaky(self: *R) void {
        self.next = 1;
        self.cap = 0;
    }

    /// Claims the capacity is as it was.
    pub fn claimsCap(self: *R) void {
        const c = self.cap;
        self.cap = 0;
        return zv.ensures({}, self.cap == c);
    }

    pub fn useSneaky(self: *R) bool {
        const c = self.cap;
        self.sneaky();
        return zv.ensures(true, self.cap == c);
    }

    pub fn loopWrites(self: *R, k: u8) void {
        var i: u8 = 0;
        while (i < k) : (i += 1) {
            zv.invariant(i <= k);
            zv.decreases(k - i);
            self.cap = 0;
        }
    }

    pub fn useLoopWrites(self: *R, k: u8) bool {
        const c = self.cap;
        self.loopWrites(k);
        return zv.ensures(true, self.cap == c);
    }

    // Aliasing: two pointers to one place.

    pub fn same(a: *R, b: *R) void {
        a.next = 1;
        b.next = 2;
    }

    pub fn callSame(self: *R) void {
        same(self, self);
    }

    /// The same field twice.
    pub fn callSameField(w: *Wrap) void {
        same(&w.a, &w.a);
    }

    /// Two fields of one struct are two places.
    pub fn callFieldsApart(w: *Wrap) bool {
        same(&w.a, &w.b);
        return zv.ensures(true, w.a.next == 1 and w.b.next == 2);
    }

    /// Two different structs are two places.
    pub fn callApart(a: *R, b: *R) bool {
        same(a, b);
        return zv.ensures(true, a.next == 1 and b.next == 2);
    }

    // Tokens in a field of the pointee.

    /// Takes the token out of the struct and does not put it back.
    pub fn dropSpare(self: *R) void {
        self.spare.discard();
    }

    pub fn readSpareTwice(self: *R) void {
        const a = self.spare;
        const b = self.spare;
        a.discard();
        b.discard();
    }

    /// A copy of the token is held across a call that takes the field.
    pub fn holdAcrossCall(self: *R, n: usize) usize {
        zv.requires(sound(self.*) and n <= self.cap -% self.next);
        const held = self.spare;
        _ = self.take(n);
        return zv.ensures(held.lo, true);
    }

    pub fn forgeSpare(self: *R) void {
        self.spare = .{ .lo = 0, .hi = 99 };
    }

    pub fn intPointee(p: *u32) void {
        p.* = 3;
    }
};
