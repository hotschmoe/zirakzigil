//! Linearity cases for zv-own. Each `pub fn` is one case; tests/own/linear.expect pins its verdict.
//! `ok*` functions are correct and must be clean; `bad*` carry the mistake in their name; `adv*` are
//! adversarial attempts to slip a mistake past the checker.

const zv = @import("zv");

const Tok = zv.Linear(u64);
const Pair = struct { a: Tok, b: Tok, n: u32 };

fn sink(t: Tok) u64 {
    return t.consume();
}

fn mayFail(fail: bool) error{Boom}!void {
    if (fail) return error.Boom;
}

fn make(n: u64) error{Boom}!Tok {
    try mayFail(n == 0);
    return Tok.init(n);
}

fn pass(t: Tok) Tok {
    return t;
}

// Clean.

pub fn okOnce() u64 {
    const t = Tok.init(5);
    return sink(t);
}

pub fn okDirect() u64 {
    return Tok.init(5).consume();
}

pub fn okBothBranches(c: bool) u64 {
    const t = Tok.init(5);
    if (c) return sink(t);
    return sink(t) + 1;
}

pub fn okBranchValue(c: bool) u64 {
    const t = Tok.init(5);
    const v = if (c) t.consume() else sink(t);
    return v;
}

pub fn okLoopEach(n: u32) u64 {
    var sum: u64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const t = Tok.init(i);
        sum += sink(t);
    }
    return sum;
}

pub fn okReturnToken() Tok {
    return Tok.init(1);
}

pub fn okPassThrough() u64 {
    const t = pass(Tok.init(1));
    return sink(t);
}

pub fn okTry(n: u64) error{Boom}!u64 {
    const t = try make(n);
    return sink(t);
}

pub fn okErrdefer(fail: bool) error{Boom}!Tok {
    const t = Tok.init(1);
    errdefer _ = sink(t);
    try mayFail(fail);
    return t;
}

pub fn okOptional(c: bool) u64 {
    var slot: ?Tok = null;
    if (c) slot = Tok.init(1);
    if (slot) |t| return sink(t);
    return 0;
}

pub fn okFields() u64 {
    const p: Pair = .{ .a = Tok.init(1), .b = Tok.init(2), .n = 3 };
    return sink(p.a) + sink(p.b) + p.n;
}

pub fn okFieldsOrder() u64 {
    const p: Pair = .{ .a = Tok.init(1), .b = Tok.init(2), .n = 3 };
    const y = sink(p.b);
    const x = sink(p.a);
    return x + y;
}

pub fn okBorrowThenConsume() u64 {
    const t = Tok.init(7);
    const peek = t.borrow().*;
    return peek + sink(t);
}

pub fn okVar() u64 {
    var t = Tok.init(1);
    const first = sink(t);
    t = Tok.init(2);
    return first + sink(t);
}

pub fn okSwitch(k: u8) u64 {
    const t = Tok.init(1);
    switch (k) {
        0 => return sink(t),
        1 => return sink(t) + 1,
        else => return t.consume() + 2,
    }
}

pub fn okPairPassed() u64 {
    const p: Pair = .{ .a = Tok.init(1), .b = Tok.init(2), .n = 3 };
    return drain(p);
}

fn drain(p: Pair) u64 {
    return sink(p.a) + sink(p.b) + p.n;
}

pub fn okTokenParam(t: Tok) u64 {
    return sink(t);
}

pub fn okPanicPath(c: bool) u64 {
    const t = Tok.init(1);
    if (c) @panic("never mind the token");
    return sink(t);
}

// Mistakes.

pub fn badTwice() u64 {
    const t = Tok.init(5);
    const copy = t;
    return sink(t) + sink(copy);
}

pub fn badLeak() void {
    const t = Tok.init(5);
    _ = t.borrow();
}

pub fn badLeakBranch(c: bool) u64 {
    const t = Tok.init(5);
    if (c) return sink(t);
    return 0;
}

pub fn badLeakParam(t: Tok) u64 {
    _ = t.borrow();
    return 1;
}

pub fn badLeakError(n: u64) error{Boom}!u64 {
    const t = Tok.init(n);
    try mayFail(n == 0);
    return sink(t);
}

pub fn badUseAfterConsume() u64 {
    const t = Tok.init(5);
    const v = sink(t);
    return v + t.borrow().*;
}

pub fn badConsumeInLoop(n: u32) u64 {
    const t = Tok.init(1);
    var sum: u64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) sum += sink(t);
    return sum;
}

pub fn badLoopLeak(n: u32) u64 {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const t = Tok.init(i);
        _ = t.borrow();
    }
    return 0;
}

pub fn badOverwrite() u64 {
    var t = Tok.init(1);
    t = Tok.init(2);
    return sink(t);
}

pub fn badFieldLeak() u64 {
    const p: Pair = .{ .a = Tok.init(1), .b = Tok.init(2), .n = 3 };
    return sink(p.a) + p.n;
}

pub fn badFieldTwice() u64 {
    const p: Pair = .{ .a = Tok.init(1), .b = Tok.init(2), .n = 3 };
    return sink(p.a) + sink(p.a) + sink(p.b);
}

pub fn badOptionalLeak(c: bool) u64 {
    var slot: ?Tok = null;
    if (c) slot = Tok.init(1);
    _ = &slot;
    return 0;
}

pub fn badMaybeConsumed(c: bool) u64 {
    const t = Tok.init(1);
    var sum: u64 = 0;
    if (c) sum += sink(t);
    sum += sink(t);
    return sum;
}

pub fn badReturnConsumed() Tok {
    const t = Tok.init(1);
    _ = sink(t);
    return t;
}

pub fn badDropParamPair(p: Pair) u32 {
    return p.n;
}

// Adversarial.

pub fn advCopyViaVar() u64 {
    var a = Tok.init(1);
    const b = a;
    a = b;
    return sink(a) + sink(b);
}

pub fn advCopyViaStruct() u64 {
    const t = Tok.init(1);
    const p: Pair = .{ .a = t, .b = t, .n = 0 };
    return sink(p.a) + sink(p.b);
}

pub fn advHiddenInOptional() u64 {
    const t = Tok.init(1);
    const o: ?Tok = t;
    return sink(t) + sink(o.?);
}

pub fn advViaPointer(out: *Tok) void {
    const t = out.*;
    _ = sink(t);
}

pub fn advStoreThroughPointer(out: *Tok) void {
    out.* = Tok.init(1);
}

pub fn advLoopCarried(n: u32) u64 {
    var carried = Tok.init(0);
    var sum: u64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        sum += sink(carried);
        carried = Tok.init(i);
    }
    return sum + sink(carried);
}

pub fn advLoopCarriedLeak(n: u32) u64 {
    var carried = Tok.init(0);
    var sum: u64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        sum += sink(carried);
        carried = Tok.init(i);
    }
    return sum;
}
