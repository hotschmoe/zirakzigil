//! zv — the comptime layer of "Zirakzigil", a verification stack for Zig.
//!
//! Everything in this file is plain Zig 0.17. No compiler fork, no plugin.
//! It gives a team four things the language does not:
//!
//!   1. Contracts      requires / ensures / invariant / assume, written in Zig,
//!                     checked at runtime in safe builds and read by `zvc`
//!                     (the static verifier) as proof obligations.
//!   2. Refinements    Ranged(lo, hi): integers whose bounds live in the type and
//!                     whose arithmetic is proven overflow-free at comptime.
//!   3. Ownership      Pool / Handle (branded + generational), Linear(T) affine
//!                     tokens, PinCheck for do-not-copy structs.
//!   4. Governance     an assurance manifest every module must carry, enforced
//!                     at compile time, plus executable laws (property tests).

const std = @import("std");
const builtin = @import("builtin");
const opts = @import("zv_options");

/// Runtime contract checks run in Debug and ReleaseSafe, never in ReleaseFast/Small.
pub const checks: bool = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

/// Ghost code. `if (zv.ghost) { ... }` is compiled only in verification builds
/// (`zig build -Dghost=true`). In normal builds the branch is comptime-false and
/// vanishes, so ghost state costs nothing in production.
pub const ghost: bool = opts.ghost;

// ─────────────────────────────────────────────────────────────────────────────
// 1. Contracts
// ─────────────────────────────────────────────────────────────────────────────

/// Set by a read of ghost state in a build that has none. A contract that read some cannot be checked there, and `holds`
/// takes it as true: a ghost build is where such a contract is proved or checked.
var read_ghost: bool = false;

inline fn taint() void {
    if (checks and !ghost) read_ghost = true;
}

inline fn holds(ok: bool) bool {
    if (!checks) return true;
    if (ghost) return ok;
    const unread = !read_ghost;
    read_ghost = false;
    return ok or !unread;
}

/// Precondition. The caller's obligation.
pub inline fn requires(ok: bool) void {
    if (checks and !holds(ok)) @panic("zv: precondition violated");
}

/// Postcondition. Returns `value` so it composes with `return`:
///     return zv.ensures(r, lo <= r and r <= hi);
pub inline fn ensures(value: anytype, ok: bool) @TypeOf(value) {
    if (checks and !holds(ok)) @panic("zv: postcondition violated");
    return value;
}

/// Loop invariant. Place it as the first statement of a loop body.
pub inline fn invariant(ok: bool) void {
    if (checks and !holds(ok)) @panic("zv: loop invariant violated");
}

/// A fact the verifier may take for granted (trusted). Checked at runtime anyway.
pub inline fn assume(ok: bool) void {
    if (checks and !holds(ok)) @panic("zv: assumption violated");
}

/// Termination measure of a loop. Place it right after the loop's `invariant` calls: `zvc` proves that the
/// measure (an unsigned integer, or a ghost `Int`) is smaller at the end of every iteration than at its
/// start, and, for an `Int`, that it never goes below zero. Several calls are ordered lexicographically.
/// It does nothing when run.
pub inline fn decreases(measure: anytype) void {
    _ = measure;
}

/// Ghost state of type `T`: a value that exists only in ghost builds and costs nothing elsewhere. It is a field or a
/// local of ordinary code, and every operation on it can be written without asking whether the build has ghost code:
/// where there is none the box is empty, a write is dropped and a read is a value no one may rely on, which a
/// contract that makes it knows (`holds`). A ghost-aware type of this library (`BlockSet`, `PointsTo`, `Cell`, `Int`,
/// `Seq`) is its own ghost value and needs no box.
///
///     order: zv.Ghost([8]u32) = .{},
///     self.order.put(self.nfree, idx);            // dropped outside ghost builds
///     zv.requires(self.order.at(0) < 8);          // checked in ghost builds, proved by zvc
pub fn Ghost(comptime T: type) type {
    switch (@typeInfo(T)) {
        .@"struct" => if (@hasDecl(T, "is_ghost")) return T,
        else => {},
    }
    return struct {
        inner: if (ghost) T else void = undefined,

        const Self = @This();
        pub const is_ghost = true;

        pub inline fn init(value: T) Self {
            return .{ .inner = if (ghost) value else {} };
        }

        pub inline fn get(self: Self) T {
            if (ghost) return self.inner;
            taint();
            return std.mem.zeroes(T);
        }

        pub inline fn set(self: *Self, value: T) void {
            if (ghost) self.inner = value;
        }

        /// Element `i` of a ghost array.
        pub inline fn at(self: Self, i: usize) std.meta.Elem(T) {
            if (ghost) return self.inner[i];
            taint();
            return std.mem.zeroes(std.meta.Elem(T));
        }

        /// Stores `value` at element `i` of a ghost array.
        pub inline fn put(self: *Self, i: usize, value: std.meta.Elem(T)) void {
            if (ghost) self.inner[i] = value;
        }
    };
}

/// Bits of a ghost integer: `zvc` proves with exactly this width (`term.ghost_bits`), so a proof holds for what runs.
pub const ghost_bits = 256;
const Word = @Int(.signed, ghost_bits);

/// Ghost integer, for specifications that must not wrap. `zvc` reads it as a mathematical integer; run in a
/// ghost build it is an `i256` and panics on overflow. Outside ghost builds it is empty and its operations are no-ops.
pub const Int = if (ghost) struct {
    v: Word,

    const Self = @This();
    pub const is_ghost = true;

    pub inline fn of(x: anytype) Self {
        return .{ .v = x };
    }
    pub inline fn add(a: Self, b: Self) Self {
        return .{ .v = a.v + b.v };
    }
    pub inline fn sub(a: Self, b: Self) Self {
        return .{ .v = a.v - b.v };
    }
    pub inline fn mul(a: Self, b: Self) Self {
        return .{ .v = a.v * b.v };
    }
    pub inline fn neg(a: Self) Self {
        return .{ .v = -a.v };
    }
    /// Division rounding toward negative infinity; the divisor must not be zero.
    pub inline fn divFloor(a: Self, b: Self) Self {
        return .{ .v = @divFloor(a.v, b.v) };
    }
    /// The remainder of `divFloor`; the divisor must not be zero.
    pub inline fn mod(a: Self, b: Self) Self {
        return .{ .v = @mod(a.v, b.v) };
    }
    pub inline fn lt(a: Self, b: Self) bool {
        return a.v < b.v;
    }
    pub inline fn le(a: Self, b: Self) bool {
        return a.v <= b.v;
    }
    pub inline fn gt(a: Self, b: Self) bool {
        return a.v > b.v;
    }
    pub inline fn ge(a: Self, b: Self) bool {
        return a.v >= b.v;
    }
    pub inline fn eq(a: Self, b: Self) bool {
        return a.v == b.v;
    }
    pub inline fn ne(a: Self, b: Self) bool {
        return a.v != b.v;
    }
} else struct {
    const Self = @This();
    pub const is_ghost = true;

    pub inline fn of(x: anytype) Self {
        _ = x;
        return .{};
    }
    pub inline fn add(a: Self, b: Self) Self {
        _ = .{ a, b };
        return .{};
    }
    pub inline fn sub(a: Self, b: Self) Self {
        _ = .{ a, b };
        return .{};
    }
    pub inline fn mul(a: Self, b: Self) Self {
        _ = .{ a, b };
        return .{};
    }
    pub inline fn neg(a: Self) Self {
        _ = a;
        return .{};
    }
    pub inline fn divFloor(a: Self, b: Self) Self {
        _ = .{ a, b };
        return .{};
    }
    pub inline fn mod(a: Self, b: Self) Self {
        _ = .{ a, b };
        return .{};
    }
    pub inline fn lt(a: Self, b: Self) bool {
        _ = .{ a, b };
        taint();
        return true;
    }
    pub inline fn le(a: Self, b: Self) bool {
        return lt(a, b);
    }
    pub inline fn gt(a: Self, b: Self) bool {
        return lt(a, b);
    }
    pub inline fn ge(a: Self, b: Self) bool {
        return lt(a, b);
    }
    pub inline fn eq(a: Self, b: Self) bool {
        return lt(a, b);
    }
    pub inline fn ne(a: Self, b: Self) bool {
        return lt(a, b);
    }
};

/// Ghost sequence of ghost integers. `zvc` reads it as a sequence and obliges it to stay within `capacity`
/// (`term.seq_capacity`) elements, which is all it holds when run in a ghost build. Like `Int`, it is empty outside them.
pub const Seq = if (ghost) struct {
    items: [capacity]Word = undefined,
    n: usize = 0,

    pub const capacity = 64;
    const Self = @This();
    pub const is_ghost = true;

    pub inline fn empty() Self {
        return .{};
    }
    /// The sequence with `x` added at the end.
    pub inline fn push(s: Self, x: Int) Self {
        var r = s;
        r.items[r.n] = x.v;
        r.n += 1;
        return r;
    }
    pub inline fn len(s: Self) Int {
        return .{ .v = s.n };
    }
    /// Element `i`; it must be in range.
    pub inline fn at(s: Self, i: Int) Int {
        return .{ .v = s.items[@intCast(i.v)] };
    }
    pub inline fn concat(a: Self, b: Self) Self {
        var r = a;
        for (b.items[0..b.n]) |x| {
            r.items[r.n] = x;
            r.n += 1;
        }
        return r;
    }
    /// The `n` elements starting at `lo`; they must be in range.
    pub inline fn sub(s: Self, lo: Int, n: Int) Self {
        var r: Self = .{};
        const first: usize = @intCast(lo.v);
        const count: usize = @intCast(n.v);
        for (s.items[first..][0..count]) |x| {
            r.items[r.n] = x;
            r.n += 1;
        }
        return r;
    }
} else struct {
    const Self = @This();
    pub const is_ghost = true;
    pub const capacity = 64;

    pub inline fn empty() Self {
        return .{};
    }
    pub inline fn push(s: Self, x: Int) Self {
        _ = .{ s, x };
        return .{};
    }
    pub inline fn len(s: Self) Int {
        _ = s;
        return .{};
    }
    pub inline fn at(s: Self, i: Int) Int {
        _ = .{ s, i };
        return .{};
    }
    pub inline fn concat(a: Self, b: Self) Self {
        _ = .{ a, b };
        return .{};
    }
    pub inline fn sub(s: Self, lo: Int, n: Int) Self {
        _ = .{ s, lo, n };
        return .{};
    }
};

/// `forall i in [0, n): pred(ctx, i)` for `n <= bound`, a conjunction written out at comptime: the verifier sees `bound`
/// guarded instances of `pred`, no quantifier, so a proof about it is as predictable as any other and a timeout is a
/// timeout. Past `bound` the instances would be missing from the conjunction, so `n > bound` is false and a proof must show `n <= bound`. `ctx` is passed by value to an inlined call, so a token in it is read, not consumed.
pub inline fn forall(comptime bound: usize, n: usize, ctx: anytype, comptime pred: fn (@TypeOf(ctx), usize) bool) bool {
    if (n > bound) return false;
    inline for (0..bound) |i| {
        if (i < n and !@call(.always_inline, pred, .{ ctx, i })) return false;
    }
    return true;
}

/// `exists i in [0, n): pred(ctx, i)`, written out the same way.
pub inline fn exists(comptime bound: usize, n: usize, ctx: anytype, comptime pred: fn (@TypeOf(ctx), usize) bool) bool {
    inline for (0..bound) |i| {
        if (i < n and @call(.always_inline, pred, .{ ctx, i })) return true;
    }
    return false;
}

/// Runtime check over [lo, hi): spec helper for quantified properties.
pub fn forallRange(lo: usize, hi: usize, ctx: anytype, comptime pred: fn (@TypeOf(ctx), usize) bool) bool {
    var i = lo;
    while (i < hi) : (i += 1) if (!pred(ctx, i)) return false;
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Refinement integers: the range is part of the type
// ─────────────────────────────────────────────────────────────────────────────

/// An integer known to lie in [lo, hi]. Storage is the smallest fitting int.
pub fn Ranged(comptime lo: comptime_int, comptime hi: comptime_int) type {
    if (lo > hi) @compileError(std.fmt.comptimePrint("zv.Ranged: empty range [{d}, {d}]", .{ lo, hi }));
    return struct {
        raw: T,

        pub const T = std.math.IntFittingRange(lo, hi);
        pub const min: comptime_int = lo;
        pub const max: comptime_int = hi;
        pub const is_ranged = true;
        const Self = @This();

        pub const assurance = .{ .lit = .checked, .from = .tested, .get = .checked, .as = .checked };
        comptime {
            manifest.requireAssurance(Self, .tested);
        }

        /// Comptime literal: out-of-range is a compile error, not a runtime one.
        pub fn lit(comptime x: comptime_int) Self {
            if (x < lo or x > hi) @compileError(std.fmt.comptimePrint("zv.Ranged: literal {d} outside [{d}, {d}]", .{ x, lo, hi }));
            return .{ .raw = x };
        }

        /// Runtime entry point: the only place a range is *checked*.
        pub fn from(x: anytype) error{OutOfRange}!Self {
            if (x < lo or x > hi) return error.OutOfRange;
            return .{ .raw = @intCast(x) };
        }

        pub fn get(self: Self) T {
            if (checks) std.debug.assert(self.raw >= lo and self.raw <= hi);
            return self.raw;
        }

        /// Convert to a plain int type. Compile error unless every value fits.
        pub fn as(self: Self, comptime U: type) U {
            if (lo < std.math.minInt(U) or hi > std.math.maxInt(U))
                @compileError("zv.Ranged.as: range [" ++ std.fmt.comptimePrint("{d}, {d}", .{ lo, hi }) ++ "] does not fit " ++ @typeName(U));
            return self.raw;
        }
    };
}

/// Index into an array of comptime-known length `n`.
pub fn Index(comptime n: comptime_int) type {
    return Ranged(0, n - 1);
}

fn Wide(comptime a: comptime_int, comptime b: comptime_int, comptime c: comptime_int, comptime d: comptime_int) type {
    return std.math.IntFittingRange(@min(@min(a, b), @min(c, d)), @max(@max(a, b), @max(c, d)));
}

pub fn AddResult(comptime A: type, comptime B: type) type {
    return Ranged(A.min + B.min, A.max + B.max);
}
pub fn SubResult(comptime A: type, comptime B: type) type {
    return Ranged(A.min - B.max, A.max - B.min);
}
pub fn MulResult(comptime A: type, comptime B: type) type {
    const p = [_]comptime_int{ A.min * B.min, A.min * B.max, A.max * B.min, A.max * B.max };
    return Ranged(@min(@min(p[0], p[1]), @min(p[2], p[3])), @max(@max(p[0], p[1]), @max(p[2], p[3])));
}

/// Interval arithmetic computed at comptime: the result type is wide enough by
/// construction, so overflow is impossible and no runtime check is emitted.
pub fn add(a: anytype, b: anytype) AddResult(@TypeOf(a), @TypeOf(b)) {
    const A = @TypeOf(a);
    const B = @TypeOf(b);
    const R = AddResult(A, B);
    const W = Wide(A.min, B.max, R.min, R.max);
    return .{ .raw = @intCast(@as(W, a.raw) + @as(W, b.raw)) };
}
pub fn sub(a: anytype, b: anytype) SubResult(@TypeOf(a), @TypeOf(b)) {
    const A = @TypeOf(a);
    const B = @TypeOf(b);
    const R = SubResult(A, B);
    const W = Wide(@min(A.min, B.min), @max(A.max, B.max), R.min, R.max);
    return .{ .raw = @intCast(@as(W, a.raw) - @as(W, b.raw)) };
}
pub fn mul(a: anytype, b: anytype) MulResult(@TypeOf(a), @TypeOf(b)) {
    const A = @TypeOf(a);
    const B = @TypeOf(b);
    const R = MulResult(A, B);
    const W = Wide(@min(A.min, B.min), @max(A.max, B.max), R.min, R.max);
    return .{ .raw = @intCast(@as(W, a.raw) * @as(W, b.raw)) };
}

/// Shrink a range with a runtime check (the explicit, greppable trust point).
pub fn narrow(comptime lo: comptime_int, comptime hi: comptime_int, x: anytype) error{OutOfRange}!Ranged(lo, hi) {
    return Ranged(lo, hi).from(x.raw);
}

/// Index an array with a proven-in-bounds index. Length mismatch is a compile error.
pub fn at(arr: anytype, idx: anytype) @TypeOf(arr[0]) {
    const n = arr.len;
    const I = @TypeOf(idx);
    if (I.min < 0 or I.max >= n) @compileError("zv.at: index range does not fit the array length");
    return arr[idx.raw];
}

// ─────────────────────────────────────────────────────────────────────────────
// 3a. Pool + branded, generational handles
// ─────────────────────────────────────────────────────────────────────────────

/// A fixed-capacity pool. `Brand` is any unique type (pass `struct {}` at the
/// declaration site); handles from one pool are a *different type* from handles
/// of another, so mixing them is a compile error. Each slot carries a generation,
/// so a stale handle (use-after-free, ABA) is caught at runtime in safe builds.
pub fn Pool(comptime T: type, comptime capacity: u32, comptime Brand: type) type {
    return struct {
        items: [capacity]T = undefined,
        gens: [capacity]u32 = @splat(0), // even = free, odd = live
        free_list: [capacity]u32 = undefined,
        free_len: u32 = 0,
        high: u32 = 0,

        pub const brand = Brand;
        pub const Handle = struct {
            index: u32,
            gen: u32,
            pub const Pool = Self;
        };
        const Self = @This();

        pub const assurance = .{ .alloc = .tested, .get = .checked, .isLive = .tested, .free = .checked };
        comptime {
            manifest.requireAssurance(Self, .tested);
        }

        pub fn alloc(self: *Self, value: T) error{PoolFull}!Handle {
            const i: u32 = if (self.free_len > 0) blk: {
                self.free_len -= 1;
                break :blk self.free_list[self.free_len];
            } else if (self.high < capacity) blk: {
                self.high += 1;
                break :blk self.high - 1;
            } else return error.PoolFull;
            self.gens[i] +%= 1; // free(even) -> live(odd)
            self.items[i] = value;
            return .{ .index = i, .gen = self.gens[i] };
        }

        fn check(self: *const Self, h: Handle) void {
            if (checks and (h.index >= self.high or self.gens[h.index] != h.gen))
                @panic("zv.Pool: stale or foreign handle (use-after-free?)");
        }

        pub fn get(self: *Self, h: Handle) *T {
            self.check(h);
            return &self.items[h.index];
        }

        pub fn isLive(self: *const Self, h: Handle) bool {
            return h.index < self.high and self.gens[h.index] == h.gen;
        }

        pub fn free(self: *Self, h: Handle) void {
            self.check(h);
            self.gens[h.index] +%= 1; // live(odd) -> free(even); old handles now stale
            self.free_list[self.free_len] = h.index;
            self.free_len += 1;
        }
    };
}

/// Generational handles over caller-provided slot slices: the `Pool`
/// counterpart for libraries that borrow storage and report stale handles as
/// errors instead of panicking (see `slots.zig`).
pub const slots = @import("slots.zig");
pub const Slots = slots.Slots;

// ─────────────────────────────────────────────────────────────────────────────
// 3b. Linear(T): affine ownership tokens, enforced at runtime
// ─────────────────────────────────────────────────────────────────────────────
//
// Zig copies structs silently, so a flag *inside* the token cannot detect a
// double consume (the copy carries its own flag). The liveness bit lives
// out-of-line in a ledger keyed by ticket, so every copy shares it.
// `zv-own` (docs/phase3.md) enforces the same rule at compile time, from the
// AIR of the code; this ledger is the backstop for what a test run reaches.
// The types are the annotations; nothing else is written:
//
//   fn f(t: Linear(T)) ...          takes ownership: f consumes `t` (or hands it on) on every path
//   fn f(t: *const Linear(T)) ...   borrows: the caller keeps ownership; f cannot consume it
//   fn f() Linear(T)                hands ownership to the caller
//   struct { tok: Linear(T), ... }  a linear value too: consume or hand on every field
//   ?Linear(T), E!Linear(T)         the token exists on the paths where the value does
//   Linear(T).consume(self)         the one sink; `init` the one source
//
// Passing a linear value to a function by value consumes it. A linear value
// read out of memory the function does not own (`out.*` through a parameter)
// is outside what zv-own follows: it reports that function as unproven.

/// Whether a value of type `T` holds a `Linear` by value, so it must be consumed or handed on. A pointer to a
/// `Linear` holds none: it borrows. Use it in a `comptime` block to keep a generic container from silently
/// accepting a type whose ownership it does not model: `comptime assert(!zv.holdsLinear(T))`.
pub fn holdsLinear(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            if (@hasField(T, "ticket") and @hasField(T, "value") and T == Linear(@FieldType(T, "value"))) break :blk true;
            for (info.field_types) |F| if (holdsLinear(F)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| blk: {
            for (info.field_types) |F| if (holdsLinear(F)) break :blk true;
            break :blk false;
        },
        .optional => |info| holdsLinear(info.child),
        .error_union => |info| holdsLinear(info.payload),
        .array => |info| holdsLinear(info.child),
        else => false,
    };
}

const ledger_capacity = 1 << 14;
var ledger: std.StaticBitSet(ledger_capacity) = .empty;
var ledger_next: u32 = 0;

pub fn Linear(comptime T: type) type {
    return struct {
        value: T,
        ticket: u32,
        const Self = @This();

        pub const assurance = .{ .init = .tested, .borrow = .checked, .consume = .checked };
        comptime {
            manifest.requireAssurance(Self, .tested);
        }

        pub fn init(value: T) Self {
            const t = ledger_next % ledger_capacity;
            ledger_next +%= 1;
            if (checks) ledger.set(t);
            return .{ .value = value, .ticket = t };
        }

        /// Read access while the token is still owned.
        pub fn borrow(self: *const Self) *const T {
            if (checks and !ledger.isSet(self.ticket)) @panic("zv.Linear: borrow after consume");
            return &self.value;
        }

        /// Move the value out. A second consume (via any copy) panics.
        pub fn consume(self: Self) T {
            if (checks) {
                if (!ledger.isSet(self.ticket)) @panic("zv.Linear: consumed twice (copied token?)");
                ledger.unset(self.ticket);
            }
            return self.value;
        }
    };
}

/// Tokens created but never consumed. Call at the end of a test: must be 0.
pub fn leakedTokens() usize {
    return ledger.count();
}
pub fn resetLedger() void {
    ledger = .empty;
}

// ─────────────────────────────────────────────────────────────────────────────
// 3c. PinCheck: catch accidental by-value copies of self-referential structs
// ─────────────────────────────────────────────────────────────────────────────

pub const PinCheck = struct {
    addr: usize = 0,

    pub const assurance = .{ .pin = .tested, .check = .checked };
    comptime {
        manifest.requireAssurance(PinCheck, .tested);
    }

    pub fn pin(self: *PinCheck) void {
        self.addr = @intFromPtr(self);
    }
    pub fn check(self: *const PinCheck) void {
        if (checks and self.addr != @intFromPtr(self)) @panic("zv.PinCheck: pinned struct was copied or moved");
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 3d. Permission tokens for raw memory (docs/phase4.md)
// ─────────────────────────────────────────────────────────────────────────────
//
// A token is linear ghost state. In a ghost build it is a value: `split`, `join`, `cut` and the others consume
// theirs, a function that takes one by value consumes it, and a consumed token may not be used again; `zvc` proves
// that of the functions it verifies and refuses a token built any other way than by the operations below. In any
// other build it is a type with no fields and the same operations, which do nothing, so code that holds tokens is
// written once and compiles to the code without them.

/// The right to use the bytes `[lo(), hi())` of one region of memory, owned by whoever holds the value.
pub const PointsTo = if (ghost) struct {
    from: usize,
    to: usize,

    const Self = @This();
    pub const is_ghost = true;

    pub const Pair = struct { head: Self, tail: Self };

    /// The permission for all of `buf`. This is the one trusted source of tokens: the caller states that
    /// nothing else uses these bytes, and `zvc` names every call as a premise (`assuming ... at file:line`).
    pub inline fn own(buf: []const u8) Self {
        return .{ .from = 0, .to = buf.len };
    }

    pub inline fn lo(self: Self) usize {
        return self.from;
    }

    pub inline fn hi(self: Self) usize {
        return self.to;
    }

    /// `[lo, cut)` and `[cut, hi)`: disjoint, and together exactly what `self` was. `cut` is a position in the
    /// region, not a length, so that no arithmetic is needed to say where the cut is.
    pub inline fn split(self: Self, cut: usize) Pair {
        requires(self.from <= cut and cut <= self.to);
        return .{
            .head = .{ .from = self.from, .to = cut },
            .tail = .{ .from = cut, .to = self.to },
        };
    }

    /// The inverse of `split`: two permissions that meet make one.
    pub inline fn join(head: Self, tail: Self) Self {
        requires(head.to == tail.from);
        return .{ .from = head.from, .to = tail.to };
    }

    /// Gives the permission up for good: the bytes can never be used through it again.
    pub inline fn discard(self: Self) void {
        _ = self;
    }
} else struct {
    const Self = @This();
    pub const is_ghost = true;

    pub const Pair = struct { head: Self, tail: Self };

    pub inline fn own(buf: []const u8) Self {
        _ = buf;
        return .{};
    }
    pub inline fn lo(self: Self) usize {
        _ = self;
        taint();
        return 0;
    }
    pub inline fn hi(self: Self) usize {
        _ = self;
        taint();
        return 0;
    }
    pub inline fn split(self: Self, cut: usize) Pair {
        _ = .{ self, cut };
        return .{ .head = .{}, .tail = .{} };
    }
    pub inline fn join(head: Self, tail: Self) Self {
        _ = .{ head, tail };
        return .{};
    }
    pub inline fn discard(self: Self) void {
        _ = self;
    }
};

/// The right to one cell of memory of type `T`, and the value it holds: a typed `PointsTo`. `write` consumes the token
/// and makes the one for the cell after the store, so the old value cannot be read once the new one is written; a
/// function that did not get the token cannot say what the cell holds.
pub fn Cell(comptime T: type) type {
    return if (ghost) struct {
        where: usize,
        held: T,

        const Self = @This();
        pub const is_ghost = true;

        /// The token of cell `slot` holding `value`. The trusted source: the caller states that nothing else touches it.
        pub inline fn own(at_: usize, value_: T) Self {
            return .{ .where = at_, .held = value_ };
        }

        pub inline fn slot(self: Self) usize {
            return self.where;
        }

        pub inline fn value(self: Self) T {
            return self.held;
        }

        /// The cell after a store of `new`.
        pub inline fn write(self: Self, new: T) Self {
            return .{ .where = self.where, .held = new };
        }

        pub inline fn discard(self: Self) void {
            _ = self;
        }
    } else struct {
        const Self = @This();
        pub const is_ghost = true;

        pub inline fn own(at_: usize, value_: T) Self {
            _ = .{ at_, value_ };
            return .{};
        }
        pub inline fn slot(self: Self) usize {
            _ = self;
            taint();
            return 0;
        }
        pub inline fn value(self: Self) T {
            _ = self;
            taint();
            return std.mem.zeroes(T);
        }
        pub inline fn write(self: Self, new: T) Self {
            _ = .{ self, new };
            return .{};
        }
        pub inline fn discard(self: Self) void {
            _ = self;
        }
    };
}

var block_set_ids: usize = 0;

/// The right to use the blocks of one pool whose bits are set in `mask()`, by index (at most 64 blocks). It is what a
/// pool hands out: a block's token has one bit, the pool keeps the free ones. `id()` names the pool: two tokens of one
/// pool that are both alive cannot share a block (`apart`), which is how a free of the same block twice is refused.
pub const BlockSet = if (ghost) struct {
    pool: usize,
    bits: u64,

    const Self = @This();
    pub const is_ghost = true;

    pub const Pair = struct { head: Self, tail: Self };

    /// The permission for the blocks of `mask` of a pool no one else uses. The trusted source of block tokens: the caller
    /// states that the pool is its own, and `zvc` names every call as a premise.
    pub inline fn own(blocks: u64) Self {
        block_set_ids += 1;
        return .{ .pool = block_set_ids, .bits = blocks };
    }

    pub inline fn id(self: Self) usize {
        return self.pool;
    }

    pub inline fn mask(self: Self) u64 {
        return self.bits;
    }

    /// Whether block `idx` is in the set.
    pub inline fn has(self: Self, idx: usize) bool {
        return idx < 64 and (self.bits >> @intCast(idx)) & 1 == 1;
    }

    /// The set of block `idx` alone, as a mask.
    pub inline fn bit(idx: usize) u64 {
        return @as(u64, 1) << @intCast(idx);
    }

    /// The blocks of `which`, which must all be in the set, and the rest.
    pub inline fn cut(self: Self, which: u64) Pair {
        requires(which & ~self.bits == 0);
        return .{
            .head = .{ .pool = self.pool, .bits = which },
            .tail = .{ .pool = self.pool, .bits = self.bits & ~which },
        };
    }

    /// The inverse of `cut`: two sets of one pool that share no block make one.
    pub inline fn join(head: Self, tail: Self) Self {
        requires(head.pool == tail.pool and head.bits & tail.bits == 0);
        return .{ .pool = head.pool, .bits = head.bits | tail.bits };
    }

    pub inline fn discard(self: Self) void {
        _ = self;
    }

    /// The lemma `points_to_disjoint` of Verus: two tokens that are alive together, of one pool, share no block. Both
    /// are returned (they are consumed and made again). `zvc` assumes it of two distinct tokens and refuses the same
    /// token twice; run, it is checked.
    pub inline fn apart(a: Self, b: Self) Pair {
        requires(a.pool != b.pool or a.bits & b.bits == 0);
        return .{
            .head = .{ .pool = a.pool, .bits = a.bits },
            .tail = .{ .pool = b.pool, .bits = b.bits },
        };
    }
} else struct {
    const Self = @This();
    pub const is_ghost = true;

    pub const Pair = struct { head: Self, tail: Self };

    pub inline fn own(blocks: u64) Self {
        _ = blocks;
        return .{};
    }
    pub inline fn id(self: Self) usize {
        _ = self;
        taint();
        return 0;
    }
    pub inline fn mask(self: Self) u64 {
        _ = self;
        taint();
        return 0;
    }
    pub inline fn has(self: Self, idx: usize) bool {
        _ = .{ self, idx };
        taint();
        return true;
    }
    pub inline fn bit(idx: usize) u64 {
        return @as(u64, 1) << @intCast(idx);
    }
    pub inline fn cut(self: Self, which: u64) Pair {
        _ = .{ self, which };
        return .{ .head = .{}, .tail = .{} };
    }
    pub inline fn join(head: Self, tail: Self) Self {
        _ = .{ head, tail };
        return .{};
    }
    pub inline fn discard(self: Self) void {
        _ = self;
    }
    pub inline fn apart(a: Self, b: Self) Pair {
        _ = .{ a, b };
        return .{ .head = .{}, .tail = .{} };
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 4. Governance: assurance manifest + laws
// ─────────────────────────────────────────────────────────────────────────────

pub const manifest = @import("manifest.zig");
pub const Level = manifest.Level;
pub const Counts = manifest.Counts;
pub const requireAssurance = manifest.requireAssurance;
pub const requireOwnership = @import("ownership.zig").requireOwnership;
pub const governed = manifest.governed;
pub const assuranceCounts = manifest.assuranceCounts;

/// Test-time property drivers (see `laws.zig`). Not analyzed unless used.
pub const laws = @import("laws.zig");
pub const checkLaws = laws.checkLaws;
pub const LawOptions = laws.Options;
pub const fuzzLaws = laws.fuzzLaws;
pub const Bytes = laws.Bytes;

/// Host-side assurance table for `zig build assurance` (see `report.zig`).
pub const report = @import("report.zig");

/// Function-level execution evidence, planted by the build (see `cover.zig`).
pub const cover = @import("cover.zig");

test {
    _ = manifest;
    _ = laws;
    _ = report;
    _ = slots;
}
