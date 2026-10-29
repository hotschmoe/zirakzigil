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

pub const RootKind = enum(u8) {
    /// A stack slot: the `alloc` instruction `n`. The function owns its content, so stores are strong updates.
    cell,
    /// What parameter `n` points to. The caller owns it.
    param,
    /// The memory an allocator call (instruction `n`) returned.
    heap,
    /// A place nothing is known about.
    other,
};

/// One step down from a place: field `n`, or an element of an array or slice (all elements are one place).
pub const elem_step: u32 = std.math.maxInt(u32);

/// A step to the allocator whose memory a container holds: what `list.append(gpa, x)` learns about `list`.
pub const backing_step: u32 = std.math.maxInt(u32) - 1;

/// Places form a tree, interned so that equal places have equal ids.
pub const Places = struct {
    recs: std.ArrayList(Rec) = .empty,
    map: std.AutoHashMapUnmanaged(Rec, PlaceId) = .empty,

    pub const Rec = struct { kind: RootKind, n: u32, parent: PlaceId, step: u32 };

    pub fn root(p: *Places, arena: Allocator, kind: RootKind, n: u32) Allocator.Error!PlaceId {
        return p.intern(arena, .{ .kind = kind, .n = n, .parent = no_place, .step = 0 });
    }

    pub fn child(p: *Places, arena: Allocator, parent: PlaceId, step: u32) Allocator.Error!PlaceId {
        const r = p.recs.items[parent];
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
    /// The owners (allocations, regions, buffers, stack slots) whose lifetime any pointer inside the value depends on.
    owners: Set = .empty,
    /// For a pointer: the place it points to, when exactly one is known.
    place: ?PlaceId = null,
    /// For an aggregate read out of a place: that place (the way `arena.deinit()` names the arena it ends).
    src: ?PlaceId = null,
    /// The fields of an aggregate, when known; `toks` and `owners` always cover them.
    parts: ?[]const Val = null,
    /// For a pointer into an array: its constant offset (in elements) from the start of `place`, when known.
    off: ?i64 = null,
    /// One of many instances: read out of an array or slice. An allocation site names all of them at once, so
    /// freeing this value does not say that the next one is freed.
    many: bool = false,
    /// `toks` holds alternatives: a join merged values that held different tokens, so the value is one of them.
    alt: bool = false,

    pub const none: Val = .{};

    pub fn isEmpty(v: Val) bool {
        return v.toks.isEmpty() and v.owners.isEmpty() and v.place == null and v.src == null and v.parts == null;
    }

    pub fn join(a: Val, arena: Allocator, b: Val) Allocator.Error!Val {
        var out: Val = .{
            .toks = try a.toks.merge(arena, b.toks),
            .owners = try a.owners.merge(arena, b.owners),
            .place = if (a.place != null and a.place == b.place) a.place else null,
            .src = if (a.src != null and a.src == b.src) a.src else null,
            .off = if (a.off != null and a.off == b.off) a.off else null,
            .many = a.many or b.many,
            .alt = a.alt or b.alt or (!a.toks.isEmpty() and !b.toks.isEmpty() and !a.toks.eql(b.toks)),
        };
        if (a.parts) |pa| if (b.parts) |pb| if (pa.len == pb.len) {
            const parts = try arena.alloc(Val, pa.len);
            for (parts, pa, pb) |*slot, x, y| slot.* = try x.join(arena, y);
            out.parts = parts;
        };
        return out;
    }

    pub fn eql(a: Val, b: Val) bool {
        if (!a.toks.eql(b.toks) or !a.owners.eql(b.owners) or a.place != b.place or a.src != b.src or a.alt != b.alt or a.off != b.off or a.many != b.many) return false;
        if (a.parts) |pa| {
            const pb = b.parts orelse return false;
            if (pa.len != pb.len) return false;
            for (pa, pb) |x, y| if (!x.eql(y)) return false;
        } else if (b.parts != null) return false;
        return true;
    }

    /// Without the structure: one value holding everything.
    pub fn flat(v: Val) Val {
        var out = v;
        out.parts = null;
        return out;
    }

    /// An aggregate of `parts`: the tokens and owners are theirs.
    pub fn aggregate(arena: Allocator, parts: []const Val) Allocator.Error!Val {
        var out: Val = .{ .parts = parts };
        for (parts) |part| {
            out.alt = out.alt or part.alt;
            out.toks = try out.toks.merge(arena, part.toks);
            out.owners = try out.owners.merge(arena, part.owners);
        }
        return out;
    }

    /// Field `i` of an aggregate. Without known parts the whole value stands for it.
    pub fn field(v: Val, i: usize) Val {
        if (v.parts) |parts| if (i < parts.len) return parts[i];
        return v.flat();
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
