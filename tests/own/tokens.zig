//! Cases for zv-own on `zv.PointsTo` tokens: each `pub fn` is one case, tests/own/tokens.expect pins its verdict.
//! A token must be consumed or handed on exactly once, in code `zvc` does not verify too. Ghost builds only.

const zv = @import("zv");

const Tok = zv.PointsTo;
const Holder = struct { n: usize, t: Tok };

fn drain(t: Tok) void {
    t.discard();
}

fn pass(t: Tok) Tok {
    return t;
}

pub fn okSplitJoin(buf: []u8) Tok {
    const whole = Tok.own(buf);
    const parts = whole.split(buf.len / 2);
    return parts.head.join(parts.tail);
}

pub fn okDiscard(buf: []u8) void {
    Tok.own(buf).discard();
}

pub fn okThroughCall(buf: []u8) Tok {
    return pass(Tok.own(buf));
}

pub fn okBothBranches(buf: []u8, c: bool) void {
    const t = Tok.own(buf);
    if (c) drain(t) else t.discard();
}

pub fn okInStruct(buf: []u8) Holder {
    return .{ .n = buf.len, .t = Tok.own(buf) };
}

pub fn okTakeHolder(h: Holder) usize {
    h.t.discard();
    return h.n;
}

pub fn okReadFieldsFirst(t: Tok) usize {
    const n = t.hi() - t.lo();
    t.discard();
    return n;
}

pub fn okReplaceInPlace(self: *Holder, more: Tok) void {
    const old = self.t;
    self.t = old.join(more);
}

pub fn badDrop(buf: []u8) usize {
    const t = Tok.own(buf);
    return t.hi();
}

pub fn badDropHalf(buf: []u8) Tok {
    const parts = Tok.own(buf).split(buf.len / 2);
    return parts.head;
}

pub fn badSplitTwice(buf: []u8) usize {
    const t = Tok.own(buf);
    const a = t.split(1);
    const b = t.split(2);
    a.head.discard();
    a.tail.discard();
    b.head.discard();
    b.tail.discard();
    return 0;
}

pub fn badCopyBothUsed(buf: []u8) void {
    const t = Tok.own(buf);
    const copy = t;
    drain(t);
    drain(copy);
}

pub fn badUseAfterConsume(buf: []u8) usize {
    const t = Tok.own(buf);
    t.discard();
    return t.hi();
}

pub fn badLeakOnBranch(buf: []u8, c: bool) void {
    const t = Tok.own(buf);
    if (c) t.discard();
}

pub fn badConsumeInLoop(buf: []u8, n: u8) void {
    const t = Tok.own(buf);
    var i: u8 = 0;
    while (i < n) : (i += 1) drain(t);
}

pub fn badReturnAndConsume(buf: []u8) Tok {
    const t = Tok.own(buf);
    drain(t);
    return t;
}

pub fn badDropHolder(buf: []u8) usize {
    const h = okInStruct(buf);
    return h.n;
}

pub fn badJoinReuse(buf: []u8) Tok {
    const t = Tok.own(buf);
    const parts = t.split(1);
    const whole = parts.head.join(parts.tail);
    drain(parts.head);
    return whole;
}

pub fn advCopyViaStruct(buf: []u8) void {
    const h: Holder = .{ .n = 0, .t = Tok.own(buf) };
    const g = h;
    h.t.discard();
    g.t.discard();
}

pub fn advOptional(buf: []u8, c: bool) void {
    const maybe: ?Tok = if (c) Tok.own(buf) else null;
    if (maybe) |t| drain(t);
}

pub fn okReplaceDirect(self: *Holder, more: Tok) void {
    self.t = self.t.join(more);
}

pub fn badTakenNotPutBack(self: *Holder) void {
    self.t.discard();
}

pub fn badReadTwice(self: *Holder) void {
    const a = self.t;
    const b = self.t;
    a.discard();
    b.discard();
    self.t = Tok.own(&.{});
}

/// Known miss: the old token in memory the caller owns is replaced without being taken out first; a write into
/// uninitialized memory looks the same, so it is counted (handed to memory it does not follow), not reported.
pub fn gapOverwriteLive(self: *Holder, buf: []u8) void {
    self.t = Tok.own(buf);
}

/// Known limit: a copy of a whole struct that holds a token, read out of memory the function does not own, is not followed
/// (read the fields you need).
pub fn advWholeStructRead(self: *Holder) usize {
    const copy = self.*;
    return copy.n;
}
