//! The abstract domain of the ownership checker: sets of ids, places, and the values the interpreter
//! tracks. Everything is allocated from an arena that lives as long as one function's run; sets and
//! values are immutable once built.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Id = u32;

/// An immutable sorted set of ids.
pub const Set = struct {
    ids: []const Id = &.{},

    pub const empty: Set = .{};

    pub fn isEmpty(s: Set) bool {
        return s.ids.len == 0;
    }

    pub fn has(s: Set, id: Id) bool {
        var lo: usize = 0;
        var hi: usize = s.ids.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (s.ids[mid] < id) lo = mid + 1 else hi = mid;
        }
        return lo < s.ids.len and s.ids[lo] == id;
    }

    pub fn single(arena: Allocator, id: Id) Allocator.Error!Set {
        return empty.with(arena, id);
    }

    pub fn with(s: Set, arena: Allocator, id: Id) Allocator.Error!Set {
        if (s.has(id)) return s;
        const out = try arena.alloc(Id, s.ids.len + 1);
        var i: usize = 0;
        while (i < s.ids.len and s.ids[i] < id) i += 1;
        @memcpy(out[0..i], s.ids[0..i]);
        out[i] = id;
        @memcpy(out[i + 1 ..], s.ids[i..]);
        return .{ .ids = out };
    }

    pub fn without(s: Set, arena: Allocator, id: Id) Allocator.Error!Set {
        if (!s.has(id)) return s;
        const out = try arena.alloc(Id, s.ids.len - 1);
        var k: usize = 0;
        for (s.ids) |x| if (x != id) {
            out[k] = x;
            k += 1;
        };
        return .{ .ids = out };
    }

    pub fn merge(a: Set, arena: Allocator, b: Set) Allocator.Error!Set {
        if (b.isEmpty() or a.eql(b)) return a;
        if (a.isEmpty()) return b;
        var out: std.ArrayList(Id) = try .initCapacity(arena, a.ids.len + b.ids.len);
        var i: usize = 0;
        var j: usize = 0;
        while (i < a.ids.len or j < b.ids.len) {
            if (j == b.ids.len or (i < a.ids.len and a.ids[i] < b.ids[j])) {
                out.appendAssumeCapacity(a.ids[i]);
                i += 1;
            } else if (i == a.ids.len or b.ids[j] < a.ids[i]) {
                out.appendAssumeCapacity(b.ids[j]);
                j += 1;
            } else {
                out.appendAssumeCapacity(a.ids[i]);
                i += 1;
                j += 1;
            }
        }
        return .{ .ids = out.items };
    }

    /// The members of `a` that are not in `b`.
    pub fn minus(a: Set, arena: Allocator, b: Set) Allocator.Error!Set {
        if (b.isEmpty() or a.isEmpty()) return a;
        var out: std.ArrayList(Id) = .empty;
        for (a.ids) |x| if (!b.has(x)) try out.append(arena, x);
        if (out.items.len == a.ids.len) return a;
        return .{ .ids = out.items };
    }

    pub fn meets(a: Set, b: Set) bool {
        for (a.ids) |x| if (b.has(x)) return true;
        return false;
    }

    pub fn eql(a: Set, b: Set) bool {
        return std.mem.eql(Id, a.ids, b.ids);
    }
};

pub const PlaceId = u32;
pub const no_place: PlaceId = std.math.maxInt(u32);

/// The epoch of a value nothing can change.
pub const fixed_epoch: u32 = std.math.maxInt(u32);

/// A bool that is true exactly when the scalar at `at` is (`eq`) or is not (`!eq`) `value`.
pub const Probe = struct { at: PlaceId, value: u64, eq: bool };

/// What holds when a bool built by `and` / `or` is true (`yes`) or false (`no`): tests of scalars, all of them.
pub const Implied = struct { yes: []const Probe = &.{}, no: []const Probe = &.{} };

pub const RootKind = enum(u8) {
    /// A stack slot: the `alloc` instruction `n`. The function owns its content, so stores are strong updates.
    cell,
    /// What parameter `n` points to. The caller owns it.
    param,
    /// The memory an allocator call (instruction `n`) returned.
    heap,
    /// A global variable or constant: memory of its own that no function in the run sees all of.
    global,
    /// A place nothing is known about.
    other,
};

/// Whether the run sees what the places of this root hold: a function's own locals, its parameters, what it allocated.
pub fn followed(kind: RootKind) bool {
    return switch (kind) {
        .cell, .param, .heap => true,
        .global, .other => false,
    };
}

/// One step down from a place: field `n`, or an element of an array or slice (all elements are one place).
pub const elem_step: u32 = std.math.maxInt(u32);

/// A step to the object identity of the aggregate stored at a place (see `Val.obj`).
pub const obj_step: u32 = std.math.maxInt(u32) - 1;

/// The steps from here up to `elem_step` name the elements at constant indices.
pub const index_step: u32 = 1 << 30;

/// A step to the length of the slice stored at a place: writing it leaves the pointer alone.
pub const len_step: u32 = std.math.maxInt(u32) - 2;

/// Places form a tree, interned so that equal places have equal ids.
pub const Places = struct {
    recs: std.ArrayList(Rec) = .empty,
    map: std.AutoHashMapUnmanaged(Rec, PlaceId) = .empty,
    /// Places that have a child at a constant index.
    indexed: std.AutoHashMapUnmanaged(PlaceId, void) = .empty,

    pub const Rec = struct { kind: RootKind, n: u32, parent: PlaceId, step: u32 };

    pub fn root(p: *Places, arena: Allocator, kind: RootKind, n: u32) Allocator.Error!PlaceId {
        return p.intern(arena, .{ .kind = kind, .n = n, .parent = no_place, .step = 0 });
    }

    pub fn child(p: *Places, arena: Allocator, parent: PlaceId, step: u32) Allocator.Error!PlaceId {
        const r = p.recs.items[parent];
        if (step >= index_step and step < len_step) try p.indexed.put(arena, parent, {});
        return p.intern(arena, .{ .kind = r.kind, .n = r.n, .parent = parent, .step = step });
    }

    fn intern(p: *Places, arena: Allocator, rec_: Rec) Allocator.Error!PlaceId {
        const gop = try p.map.getOrPut(arena, rec_);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(p.recs.items.len);
            try p.recs.append(arena, rec_);
        }
        return gop.value_ptr.*;
    }

    /// The child of `parent` at `step` if some code already made it.
    pub fn find(p: *const Places, parent: PlaceId, step: u32) ?PlaceId {
        const r = p.recs.items[parent];
        return p.map.get(.{ .kind = r.kind, .n = r.n, .parent = parent, .step = step });
    }

    pub fn rec(p: *const Places, id: PlaceId) Rec {
        return p.recs.items[id];
    }

    /// `anc` is `desc` or a place `desc` lies inside.
    pub fn contains(p: *const Places, anc: PlaceId, desc: PlaceId) bool {
        var at = desc;
        while (true) {
            if (at == anc) return true;
            at = p.recs.items[at].parent;
            if (at == no_place) return false;
        }
    }

    pub fn overlaps(p: *const Places, a: PlaceId, b: PlaceId) bool {
        return p.contains(a, b) or p.contains(b, a);
    }

    pub fn depth(p: *const Places, id: PlaceId) u32 {
        var n: u32 = 0;
        var at = id;
        while (p.recs.items[at].parent != no_place) : (at = p.recs.items[at].parent) n += 1;
        return n;
    }

    /// The steps from the root down to `id`, in order.
    pub fn path(p: *const Places, arena: Allocator, id: PlaceId) Allocator.Error![]const u32 {
        const out = try arena.alloc(u32, p.depth(id));
        var at = id;
        var k = out.len;
        while (k > 0) : (at = p.recs.items[at].parent) {
            k -= 1;
            out[k] = p.recs.items[at].step;
        }
        return out;
    }

    /// True when the path from the root to `id` has an element step, which makes stores weak updates.
    pub fn hasElem(p: *const Places, id: PlaceId) bool {
        var at = id;
        while (p.recs.items[at].parent != no_place) : (at = p.recs.items[at].parent) {
            if (p.recs.items[at].step == elem_step) return true;
        }
        return false;
    }
};

/// What the interpreter knows about one runtime value.
pub const Val = struct {
    /// The linear tokens the value holds (all of its parts).
    toks: Set = .empty,
    /// The identities (allocations, buffers, stack slots, objects) any pointer inside the value may lead into. A
    /// value copied by value carries the same identities, so ending one through any copy ends it for all of them.
    ids: Set = .empty,
    /// The object identities of the aggregate itself (its incarnation: a container, an arena): what `deinit` ends.
    obj: Set = .empty,
    /// For a pointer: the place it points to, when exactly one is known.
    place: ?PlaceId = null,
    /// For an aggregate read out of a place: that place (the way `arena.deinit()` names the arena it ends).
    src: ?PlaceId = null,
    /// For an optional or error union read out of a place: that place, so a test of it can refine what is stored.
    from: ?PlaceId = null,
    /// The fields of an aggregate, when known; `toks` and `ids` always cover them.
    parts: ?[]const Val = null,
    /// For a pointer into an array: its constant offset (in elements) from the start of `place`, when known.
    off: ?i64 = null,
    /// One of many instances: read out of an array or slice. An allocation site names all of them at once, so
    /// freeing this value does not say that the next one is freed.
    many: bool = false,
    /// Identities that end if this value (an optional or an error union from a call that may move its argument) holds a
    /// payload: `remap` and `realloc` succeeded, so the old allocation is gone.
    moved: Set = .empty,
    /// `toks` holds alternatives: a join merged values that held different tokens, so the value is one of them.
    alt: bool = false,
    /// `ids` holds alternatives: a join merged pointers that led to different things, so the value is one of them.
    maybe: bool = false,
    /// A container made with room for this many elements and none in it (`initCapacity`).
    room: ?u64 = null,
    /// A number, a bool or an enum known to be this constant (an enum by the hash of its name).
    con: ?u64 = null,
    /// Without `con`: it is one of these two (a join of two constants). Only a test of whether an end can happen reads it.
    pair: ?[2]u64 = null,
    /// A scalar read from this place, or a bool that tests one (`probe`): good only while `ep` is the epoch of the run (no
    /// memory was written since), or `fixed_epoch` (a field of a parameter passed by value).
    at: ?PlaceId = null,
    probe: ?Probe = null,
    imp: ?*const Implied = null,
    /// A pointer whose pointee type is not the one of the place it was made from: what it writes is not read as a constant.
    cast: bool = false,
    ep: u32 = 0,

    pub const none: Val = .{};

    /// What of a scalar is still true once it is written to memory: its constant, and which field of a parameter it is.
    pub fn scalarKept(v: Val) Val {
        const fixed = v.at != null and v.ep == fixed_epoch;
        return .{ .con = v.con, .pair = v.pair, .at = if (fixed) v.at else null, .ep = if (fixed) fixed_epoch else 0 };
    }

    pub fn isEmpty(v: Val) bool {
        return v.toks.isEmpty() and v.ids.isEmpty() and v.obj.isEmpty() and v.place == null and v.src == null and v.parts == null;
    }

    /// The two constants a join of scalars can be, when it is exactly two.
    fn joinPair(a: Val, b: Val) ?[2]u64 {
        if (a.con != null and b.con != null and a.con != b.con) return .{ @min(a.con.?, b.con.?), @max(a.con.?, b.con.?) };
        if (a.pair) |p| {
            if (b.pair) |q| return if (std.meta.eql(p, q)) p else null;
            if (b.con) |c| return if (c == p[0] or c == p[1]) p else null;
        }
        if (b.pair) |q| if (a.con) |c| return if (c == q[0] or c == q[1]) q else null;
        return null;
    }

    /// Nothing is known of the scalar any more.
    pub fn forgetCon(v: *Val) void {
        v.con = null;
        v.pair = null;
    }

    pub fn join(a: Val, arena: Allocator, b: Val) Allocator.Error!Val {
        var out: Val = .{
            .toks = try a.toks.merge(arena, b.toks),
            .ids = try a.ids.merge(arena, b.ids),
            .obj = try a.obj.merge(arena, b.obj),
            .moved = try a.moved.merge(arena, b.moved),
            .place = if (a.place != null and a.place == b.place) a.place else null,
            .src = if (a.src != null and a.src == b.src) a.src else null,
            .from = if (a.from != null and a.from == b.from) a.from else null,
            .off = if (a.off != null and a.off == b.off) a.off else null,
            .many = a.many or b.many,
            .alt = a.alt or b.alt or (!a.toks.isEmpty() and !b.toks.isEmpty() and !a.toks.eql(b.toks)),
            .maybe = a.maybe or b.maybe or (!a.ids.isEmpty() and !b.ids.isEmpty() and !a.ids.eql(b.ids)),
            .room = if (a.room != null and a.room == b.room) a.room else null,
            .con = if (a.con != null and a.con == b.con) a.con else null,
            .pair = joinPair(a, b),
            .at = if (a.at != null and a.at == b.at and a.ep == b.ep) a.at else null,
            .probe = if (a.probe != null and b.probe != null and a.ep == b.ep and std.meta.eql(a.probe.?, b.probe.?)) a.probe else null,
            .imp = if (a.imp == b.imp) a.imp else null,
            .cast = a.cast or b.cast,
            .ep = a.ep,
        };
        if (a.parts) |pa| if (b.parts) |pb| if (pa.len == pb.len) {
            const parts = try arena.alloc(Val, pa.len);
            for (parts, pa, pb) |*slot, x, y| slot.* = try x.join(arena, y);
            out.parts = parts;
        };
        // One side without fields (an empty value, or one the checker cannot take apart) adds to every field.
        if (out.parts == null) {
            const shaped, const rest = if (a.parts != null and b.parts == null) .{ a, b } else if (b.parts != null and a.parts == null) .{ b, a } else return out;
            const parts = try arena.alloc(Val, shaped.parts.?.len);
            var extra = rest;
            extra.obj = .empty;
            for (parts, shaped.parts.?) |*slot, x| slot.* = try x.join(arena, extra.flat());
            out.parts = parts;
        }
        return out;
    }

    pub fn eql(a: Val, b: Val) bool {
        if (!a.toks.eql(b.toks) or !a.ids.eql(b.ids) or !a.obj.eql(b.obj) or !a.moved.eql(b.moved) or a.place != b.place or a.src != b.src or a.from != b.from or a.alt != b.alt or a.maybe != b.maybe or a.room != b.room or a.off != b.off or a.many != b.many or a.con != b.con or !std.meta.eql(a.pair, b.pair)) return false;
        if (a.parts) |pa| {
            const pb = b.parts orelse return false;
            if (pa.len != pb.len) return false;
            for (pa, pb) |x, y| if (!x.eql(y)) return false;
        } else if (b.parts != null) return false;
        return true;
    }

    /// Nothing but the constants of a value: what is left of it where it does not exist.
    pub fn onlyCons(v: Val, arena: Allocator) Allocator.Error!Val {
        var out: Val = .{ .con = v.con };
        if (v.parts) |parts| {
            const copy = try arena.alloc(Val, parts.len);
            for (copy, parts) |*slot, part| slot.* = try part.onlyCons(arena);
            out.parts = copy;
        }
        return out;
    }

    /// Without the structure: one value holding everything.
    pub fn flat(v: Val) Val {
        var out = v;
        out.parts = null;
        return out;
    }

    /// An aggregate of `parts`: the tokens and identities are theirs.
    pub fn aggregate(arena: Allocator, parts: []const Val) Allocator.Error!Val {
        var out: Val = .{ .parts = parts };
        for (parts) |part| {
            out.alt = out.alt or part.alt;
            out.maybe = out.maybe or part.maybe;
            out.toks = try out.toks.merge(arena, part.toks);
            out.ids = try out.ids.merge(arena, part.ids);
            out.moved = try out.moved.merge(arena, part.moved);
        }
        return out;
    }

    /// Field `i` of an aggregate. Without known parts the whole value stands for it.
    pub fn field(v: Val, i: usize) Val {
        if (v.parts) |parts| if (i < parts.len) return parts[i];
        var out = v.flat();
        out.obj = .empty;
        return out;
    }

    pub fn withoutToks(v: Val, arena: Allocator, gone: Set) Allocator.Error!Val {
        if (!v.toks.meets(gone)) return v;
        var out = v;
        out.toks = try v.toks.minus(arena, gone);
        if (v.parts) |parts| {
            const copy = try arena.alloc(Val, parts.len);
            for (copy, parts) |*slot, part| slot.* = try part.withoutToks(arena, gone);
            out.parts = copy;
        }
        return out;
    }
};
