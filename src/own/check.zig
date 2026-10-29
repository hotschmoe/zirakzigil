//! The ownership checker. One function is run abstractly over its AIR (structured control flow, joined at
//! the end of every construct, loops iterated to a fixed point); the run tracks
//!
//!   linear tokens   every `zv.Linear` value a path creates, receives or gets back from a call is a token;
//!                   a token is live until a sink ends it: passing it by value, returning it, storing it into
//!                   memory the function does not own. Ending an ended token, or leaving a live one, is a finding.
//!   identities      what a pointer's validity hangs on: a stack slot, an allocation, the storage a caller handed
//!                   in, an object (an arena, a container). A value carries the set of identities it may lead
//!                   into, and a copy of the value carries the same set: an operation that ends an identity ends
//!                   it for every copy. Using a value that leads into an ended identity is a finding.
//!
//! A path is analyzed once; at joins the facts are unioned, so a finding means "on some path". Anything the
//! interpreter does not model stops the run of that function with an `unsupported` finding: it is neither
//! accepted nor refuted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zv_air = @import("zv_air");
const schema = zv_air.schema;
const View = @import("view.zig").View;
const Types = @import("types.zig").Types;
const spec = @import("spec.zig");
const dom = @import("domain.zig");
const diag = @import("diag.zig");
const calls = @import("calls.zig");
const Set = dom.Set;
const Val = dom.Val;
const PlaceId = dom.PlaceId;
const Places = dom.Places;
const Inst = schema.Inst;

pub const Ref = struct { pack: *const schema.Pack, func: schema.Func };

pub const Stats = struct {
    insts: u32 = 0,
    /// Calls to functions that are not in the packs and that the checker has no model of: they are assumed
    /// to neither end identities nor keep their arguments.
    unknown_calls: u32 = 0,
    /// Tokens handed to memory the function does not own: ownership passes on, the checker stops following it.
    transfers: u32 = 0,
    /// Container methods nobody wrote down and whose body is not in the packs: assumed to invalidate.
    unmodelled: u32 = 0,
    /// Operations on a container or allocation the checker cannot name a place for: their effects are not applied.
    blind: u32 = 0,
    /// `resize` or `remap` with a length the checker cannot show to be non-zero: assumed not to free.
    dynamic_len: u32 = 0,
    /// A use or a free of something that is ended on some of the things a pointer may lead to, not on all: the
    /// checker cannot tell which, and does not report it.
    maybe_alias: u32 = 0,
    /// A pointer into storage that an operation reallocates only if there is no room, and the room is not known.
    maybe_stale: u32 = 0,
    /// An end of an identity that stands for several allocations (one site run again before the last was ended).
    summarized: u32 = 0,
    /// Functions that end or change memory through two pointer parameters of one type, assumed not to overlap.
    alias_params: u32 = 0,
    /// Ends and uses of memory the checker follows, to set against what it counted and did not decide.
    ends: u32 = 0,
    uses: u32 = 0,
    /// A pointer to a local handed to a call that returns a new block or that the summary does not trace, whose result may
    /// keep it: not followed.
    lent: u32 = 0,
};

/// What of a callee's parameter an effect names: the value passed (`value`: its identities, below `path` for a
/// by-value aggregate), the memory a pointer parameter points to (`content`, at `path` below it), or the object
/// (an arena, a container) at that place.
pub const SlotKind = enum(u8) { value, content, object, view };

pub const Slot = struct {
    param: u32,
    path: []const u32 = &.{},
    kind: SlotKind = .value,

    pub fn eql(a: Slot, b: Slot) bool {
        return a.param == b.param and a.kind == b.kind and std.mem.eql(u32, a.path, b.path);
    }
};

/// Where a value of the result or of a store comes from: a slot of an argument, or the `k`th fresh allocation of the
/// callee. `obj`: it names the object identities of the value, not the identities its pointers lead into.
pub const Desc = struct {
    src: union(enum) { from: Slot, fresh: u32, gone },
    obj: bool = false,

    pub fn eql(a: Desc, b: Desc) bool {
        if (a.obj != b.obj) return false;
        return switch (a.src) {
            .from => |x| b.src == .from and x.eql(b.src.from),
            .fresh => |x| b.src == .fresh and x == b.src.fresh,
            .gone => b.src == .gone,
        };
    }
};

/// The descriptors of the leaf `path` below a result (the field path inside a returned aggregate).
pub const Leaf = struct { path: []const u32, descs: []const Desc };

/// Memory below a pointer parameter holds `descs` when the callee returns. `must`: on every path that returns.
pub const Write = struct { into: Slot, descs: []const Desc, must: bool };

/// A fresh allocation of the callee ends with the objects `regions` (an arena it allocated from).
pub const Fresh = struct { regions: []const Slot, many: bool = false };

/// What a caller needs to know about a function it calls, read from the function itself: the effects it has on
/// what its parameters lead into, expressed over access paths rooted at the parameters, and where its result comes from.
pub const Summary = struct {
    /// False when the run stopped early: a caller falls back to the model of a function it cannot read.
    complete: bool = true,
    /// A guess made while the function's own body is read (recursion), not something the body showed.
    assumed: bool = false,
    /// Where the result comes from, per field.
    ret: []const Leaf = &.{},
    /// The result is the pointer passed as this parameter, at `path` below it, on every path that returns.
    ret_place: ?Slot = null,
    /// Ended or invalidated on some path that returns.
    kills: []const Slot = &.{},
    /// Bit i: the allocation or handle behind parameter i is freed on every path that returns.
    frees: u64 = 0,
    /// What the memory below the pointer parameters holds afterwards.
    writes: []const Write = &.{},
    fresh: []const Fresh = &.{},
    /// What the function reads or writes through (the memory a pointer it was given leads into, at these slots).
    derefs: []const Slot = &.{},
    /// Bit i: a linear value passed in parameter i is stored into memory the function does not own.
    token_stores: u64 = 0,
    /// Bit i: the function returns the result of a `realloc` or `remap` of parameter i, so the allocation is gone
    /// when the result holds a payload.
    moves: u64 = 0,

    pub fn eql(a: Summary, b: Summary) bool {
        if (a.complete != b.complete or a.frees != b.frees or a.token_stores != b.token_stores or a.moves != b.moves) return false;
        if (a.ret.len != b.ret.len or a.kills.len != b.kills.len or a.writes.len != b.writes.len or a.fresh.len != b.fresh.len or a.derefs.len != b.derefs.len) return false;
        for (a.derefs, b.derefs) |x, y| if (!x.eql(y)) return false;
        for (a.ret, b.ret) |x, y| if (!std.mem.eql(u32, x.path, y.path) or !eqlDescs(x.descs, y.descs)) return false;
        for (a.kills, b.kills) |x, y| if (!x.eql(y)) return false;
        for (a.writes, b.writes) |x, y| if (!x.into.eql(y.into) or x.must != y.must or !eqlDescs(x.descs, y.descs)) return false;
        if ((a.ret_place == null) != (b.ret_place == null)) return false;
        if (a.ret_place) |p| if (!p.eql(b.ret_place.?)) return false;
        return true;
    }

    fn eqlDescs(a: []const Desc, b: []const Desc) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!x.eql(y)) return false;
        return true;
    }
};

pub const Result = struct {
    name: []const u8,
    diags: []const diag.Diag,
    stats: Stats,
    summary: Summary = .{},

    pub fn errors(r: Result) usize {
        var n: usize = 0;
        for (r.diags) |d| n += @intFromBool(d.kind.isError());
        return n;
    }

    pub fn unsupported(r: Result) bool {
        for (r.diags) |d| if (d.kind == .unsupported) return true;
        return false;
    }
};

pub const ParamNames = struct {
    context: *anyopaque,
    lookup: *const fn (context: *anyopaque, ref: Ref, index: u32) ?[]const u8,
};

const Tentative = struct { result: *Result, on: []const []const u8 };

pub const Program = struct {
    gpa: Allocator,
    /// Holds the results: lives as long as the program.
    arena: Allocator,
    packs: []const *const schema.Pack,
    /// Every function by name: instances of one generic function share it, so a call picks by the types it passes.
    /// The same function exported into several packs is listed once.
    funcs: std.StringHashMapUnmanaged(std.ArrayList(Ref)) = .empty,
    results: std.StringHashMapUnmanaged(*Result) = .empty,
    /// Functions being analyzed, with the summary assumed for them while their own body is read: a call back into
    /// one of them (recursion) uses the assumption, and the analysis repeats until the summary it ends with is the
    /// one it assumed.
    busy: std.StringHashMapUnmanaged(Summary) = .empty,
    /// The busy functions the current analysis used an assumption of: a result that depends on an outer function's
    /// assumption is only good while that assumption holds, so it is not kept.
    consulted: std.StringHashMapUnmanaged(void) = .empty,
    /// Results that depend on the assumption of a function still being analyzed: good until that assumption changes.
    tentative: std.StringHashMapUnmanaged(Tentative) = .empty,
    /// Effects the project gives its own functions in an `ownership` manifest, by declared name.
    annotations: std.StringHashMapUnmanaged(spec.Effect) = .empty,
    /// Names of parameters, which the packs do not carry; set by whoever has the sources.
    param_names: ?ParamNames = null,

    pub fn init(gpa: Allocator, arena: Allocator, packs: []const *const schema.Pack) Allocator.Error!Program {
        var p: Program = .{ .gpa = gpa, .arena = arena, .packs = packs };
        for (packs) |pack| for (pack.t.funcs) |f| {
            const gop = try p.funcs.getOrPut(arena, pack.str(f.fqn));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            const here: Ref = .{ .pack = pack, .func = f };
            var dup = false;
            for (gop.value_ptr.items) |other| if (sameFunc(other, here)) {
                dup = true;
            };
            if (!dup) try gop.value_ptr.append(arena, here);
        };
        return p;
    }

    /// Two exports of one function: the same declared name, file, line and parameter types.
    fn sameFunc(a: Ref, b: Ref) bool {
        if (a.func.line != b.func.line) return false;
        const fa = a.pack.t.files[@backingInt(a.func.file)];
        const fb = b.pack.t.files[@backingInt(b.func.file)];
        if (!std.mem.eql(u8, a.pack.str(fa.path), b.pack.str(fb.path)) or !std.mem.eql(u8, a.pack.str(fa.module), b.pack.str(fb.module))) return false;
        const pa = a.pack.t.params[a.func.params.off..][0..a.func.params.len];
        const pb = b.pack.t.params[b.func.params.off..][0..b.func.params.len];
        if (pa.len != pb.len) return false;
        for (pa, pb) |x, y| if (!std.mem.eql(u8, a.pack.typeName(x.ty), b.pack.typeName(y.ty))) return false;
        return true;
    }

    fn packIndex(p: *Program, pack: *const schema.Pack) usize {
        for (p.packs, 0..) |q, i| if (q == pack) return i;
        return 0;
    }

    fn keyOf(p: *Program, ref: Ref) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(p.arena, "{s}#{d}.{x}", .{ ref.pack.str(ref.func.fqn), p.packIndex(ref.pack), ref.func.id });
    }

    /// The function a call names. Several functions of one name are instances of a generic function: the one whose
    /// parameters have the types of the arguments is meant, and when that does not settle it the call is unknown.
    pub fn resolve(p: *Program, name: []const u8, pack: *const schema.Pack, arg_tys: []const schema.TypeId) ?Ref {
        const list = p.funcs.get(name) orelse return null;
        if (list.items.len == 1) return list.items[0];
        var found: ?Ref = null;
        for (list.items) |cand| {
            const params = cand.pack.t.params[cand.func.params.off..][0..cand.func.params.len];
            if (params.len != arg_tys.len) continue;
            var same = true;
            for (params, arg_tys) |param, ty| {
                if (!std.mem.eql(u8, cand.pack.typeName(param.ty), if (ty == .none) "?" else pack.typeName(ty))) same = false;
            }
            if (!same) continue;
            if (found != null) return null;
            found = cand;
        }
        return found;
    }

    pub fn analyze(p: *Program, ref: Ref) Allocator.Error!*const Result {
        const key = try p.keyOf(ref);
        if (p.results.get(key)) |done| return done;
        if (p.tentative.get(key)) |t| {
            for (t.on) |k| try p.consulted.put(p.arena, k, {});
            return t.result;
        }
        var outer = p.consulted;
        p.consulted = .empty;
        // Start from the most optimistic summary: everything is freed, nothing else happens. Recursion that
        // frees on every path keeps it; recursion that does not loses it in the first round.
        var guess: Summary = .{ .frees = ~@as(u64, 0), .assumed = true };
        var rounds: u32 = 0;
        const out = try p.arena.create(Result);
        while (true) {
            try p.busy.put(p.arena, key, guess);
            p.forget(key);
            var scratch: std.heap.ArenaAllocator = .init(p.gpa);
            defer scratch.deinit();
            var run: Run = try .init(p, scratch.allocator(), ref);
            out.* = try run.execute();
            if (!p.consulted.contains(key) or !out.summary.complete or out.summary.eql(guess)) break;
            rounds += 1;
            if (rounds >= 8) {
                out.summary.complete = false;
                break;
            }
            guess = out.summary;
            guess.assumed = true;
        }
        _ = p.busy.remove(key);
        _ = p.consulted.remove(key);
        p.forget(key);
        const cacheable = p.consulted.count() == 0;
        var on: std.ArrayList([]const u8) = .empty;
        var it = p.consulted.keyIterator();
        while (it.next()) |k| {
            try outer.put(p.arena, k.*, {});
            try on.append(p.arena, k.*);
        }
        p.consulted = outer;
        if (cacheable) try p.results.put(p.arena, key, out) else try p.tentative.put(p.arena, key, .{ .result = out, .on = on.items });
        return out;
    }

    /// The assumption for `key` is new or gone: results computed under the old one are not good any more.
    fn forget(p: *Program, key: []const u8) void {
        var gone: std.ArrayList([]const u8) = .empty;
        var it = p.tentative.iterator();
        while (it.next()) |e| for (e.value_ptr.on) |k| if (std.mem.eql(u8, k, key)) {
            gone.append(p.gpa, e.key_ptr.*) catch return;
            break;
        };
        defer gone.deinit(p.gpa);
        for (gone.items) |k| _ = p.tentative.remove(k);
    }

    /// What a call to `ref` does, read from its body; the assumed summary while it is being analyzed (recursion);
    /// null when its run was cut short.
    pub fn summaryOf(p: *Program, ref: Ref) Allocator.Error!?Summary {
        const key = try p.keyOf(ref);
        if (p.busy.get(key)) |assumed| {
            try p.consulted.put(p.arena, key, {});
            return assumed;
        }
        const done = try p.analyze(ref);
        return if (done.summary.complete) done.summary else null;
    }
};

pub const Error = Allocator.Error || error{Unsupported};

const Token = struct { site: u32, sub: u32, loc: schema.LocId };

pub const Kind = enum(u8) {
    /// A stack slot (`a` is its `alloc`). Pointers to it must not leave the function.
    local,
    /// An allocation, handle or buffer made by call `a` (`b`: which of the call's results, and which of two recent
    /// instances of the site, see `Run.mint`).
    heap,
    /// What the caller gave: `b == 0`, the value of the parameter place `a` (the pointer itself, or a part of a
    /// by-value aggregate); `b == 1`, the memory behind the place `a`; `b == 2`, the elements inline in the place `a`
    /// (a pointer to one of them is stale when an operation moves them).
    init,
    /// The incarnation of the aggregate (an arena, a container) stored at place `a`: while it lives, what it handed
    /// out is valid.
    object,
    /// The end of identity `a` (`b == 1`: it stands for several blocks, or the end depends on room nobody could
    /// read): a value that holds it leads into memory that is gone.
    tomb,
};

pub const Ident = struct { kind: Kind, a: u32, b: u32 };

/// `exact`: the end is of the one block a place holds, whichever of the names that stand for several it carries.
pub const Event = struct { loc: schema.LocId, text: []const u8, trail: ?*const diag.Trail, soft: bool = false, exact: bool = false };

pub const Pending = struct { loc: schema.LocId, ident: dom.Id, site: u32 };

/// `cap_lb`: the container holds at least this many elements without reallocating. `len_ub`: it holds at most this
/// many now, when that is known.
/// A second free of a handle that may only be an ignored error: reported where the error is propagated.
pub const Cancel = struct { tomb: dom.Id };

pub const Over = struct { val: Val, stamp: u32 };

pub const Cap = struct { cap_lb: u64 = 0, len_ub: ?u64 = null, sym: bool = false };

pub const Pred = struct { subject: Val, ptr: bool, present_if_true: bool, ty: schema.TypeId };

pub const Trail = diag.Trail;

pub const State = struct {
    alive: bool = true,
    mem: std.AutoArrayHashMapUnmanaged(PlaceId, Val) = .empty,
    live: Set = .empty,
    ended: Set = .empty,
    /// Parameter values freed on every path that led here (the dead set is the paths' union).
    freed: Set = .empty,
    /// Identities that no longer exist, and why (the first cause on this path).
    dead: std.AutoArrayHashMapUnmanaged(dom.Id, Event) = .empty,
    /// Allocations and objects that exist now (on some path): a new one of the same site gets another name.
    alloced: Set = .empty,
    /// Identities that stand for several allocations: ending one does not end the others.
    multi: Set = .empty,
    /// Stack slots whose address went into a container that outlives them: fine if the entry is removed before
    /// the function returns (a registry for the duration of a call).
    pending: std.AutoArrayHashMapUnmanaged(dom.Id, Pending) = .empty,
    /// What is known of the room in a container (an array list, a hash map) at a place: how many elements fit without
    /// reallocating, and how many are in it at most. A place without an entry is known to hold nothing of the sort.
    caps: std.AutoArrayHashMapUnmanaged(PlaceId, Cap) = .empty,
    /// The values computed so far that an end or a rename changed on this path (by instruction; the stamp says which
    /// definition of the instruction it belongs to).
    over: std.AutoArrayHashMapUnmanaged(u32, Over) = .empty,
    trail: ?*const Trail = null,

    pub fn clone(s: State, arena: Allocator) Allocator.Error!State {
        var c = s;
        c.mem = try s.mem.clone(arena);
        c.dead = try s.dead.clone(arena);
        c.pending = try s.pending.clone(arena);
        c.caps = try s.caps.clone(arena);
        c.over = try s.over.clone(arena);
        return c;
    }

    /// The state after either of two paths. `entry` is the trail where they split.
    fn join(a: State, arena: Allocator, b: State, entry: ?*const Trail) Allocator.Error!State {
        if (!a.alive) return b;
        if (!b.alive) return a;
        var out = try a.clone(arena);
        out.trail = entry;
        out.live = try a.live.merge(arena, b.live);
        out.freed = try a.freed.minus(arena, try a.freed.minus(arena, b.freed));
        out.ended = try a.ended.merge(arena, b.ended);
        out.alloced = try a.alloced.merge(arena, b.alloced);
        out.multi = try a.multi.merge(arena, b.multi);
        var pending_it = b.pending.iterator();
        while (pending_it.next()) |e| {
            const gop = try out.pending.getOrPut(arena, e.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = e.value_ptr.*;
        }
        var dead_it = b.dead.iterator();
        while (dead_it.next()) |e| {
            const gop = try out.dead.getOrPut(arena, e.key_ptr.*);
            if (!gop.found_existing) {
                gop.value_ptr.* = e.value_ptr.*;
            } else if (gop.value_ptr.soft and !e.value_ptr.soft) gop.value_ptr.* = e.value_ptr.*;
        }
        var k: usize = 0;
        while (k < out.caps.count()) {
            const other = b.caps.get(out.caps.keys()[k]) orelse {
                out.caps.swapRemoveAt(k);
                continue;
            };
            const mine = &out.caps.values()[k];
            mine.cap_lb = @min(mine.cap_lb, other.cap_lb);
            // A count that differs between two paths is not followed: a loop would never settle.
            if (mine.len_ub == null or other.len_ub == null or mine.len_ub.? != other.len_ub.?) mine.len_ub = null;
            k += 1;
        }
        var it = b.mem.iterator();
        while (it.next()) |e| {
            const gop = try out.mem.getOrPut(arena, e.key_ptr.*);
            gop.value_ptr.* = if (gop.found_existing) try gop.value_ptr.join(arena, e.value_ptr.*) else e.value_ptr.*;
        }
        var over_it = b.over.iterator();
        while (over_it.next()) |e| {
            const gop = try out.over.getOrPut(arena, e.key_ptr.*);
            if (!gop.found_existing) {
                gop.value_ptr.* = e.value_ptr.*;
            } else if (gop.value_ptr.stamp == e.value_ptr.stamp) gop.value_ptr.val = try gop.value_ptr.val.join(arena, e.value_ptr.val);
        }
        return out;
    }

    fn eql(a: State, b: State) bool {
        if (a.alive != b.alive) return false;
        if (!a.alive) return true;
        if (!a.live.eql(b.live) or !a.ended.eql(b.ended)) return false;
        if (!a.freed.eql(b.freed) or !a.alloced.eql(b.alloced) or !a.multi.eql(b.multi)) return false;
        if (a.caps.count() != b.caps.count()) return false;
        var caps_it = a.caps.iterator();
        while (caps_it.next()) |e| {
            const other = b.caps.get(e.key_ptr.*) orelse return false;
            if (e.value_ptr.cap_lb != other.cap_lb or e.value_ptr.len_ub != other.len_ub) return false;
        }
        if (a.pending.count() != b.pending.count()) return false;
        for (a.pending.keys()) |k| if (!b.pending.contains(k)) return false;
        if (a.dead.count() != b.dead.count()) return false;
        for (a.dead.keys(), a.dead.values()) |k, v| {
            const other = b.dead.get(k) orelse return false;
            if (other.soft != v.soft) return false;
        }
        if (a.over.count() != b.over.count()) return false;
        for (a.over.keys(), a.over.values()) |k, v| {
            const other = b.over.get(k) orelse return false;
            if (v.stamp != other.stamp or !v.val.eql(other.val)) return false;
        }
        if (a.mem.count() != b.mem.count()) return false;
        var it = a.mem.iterator();
        while (it.next()) |e| {
            const other = b.mem.get(e.key_ptr.*) orelse return false;
            if (!e.value_ptr.eql(other)) return false;
        }
        return true;
    }
};

const Incoming = struct { state: State, val: Val };

const BlockCtx = struct { incoming: std.ArrayList(Incoming) = .empty };

const LoopCtx = struct { back: std.ArrayList(State) = .empty };

/// What one `ret` instruction showed about the function, kept until the run ends: the last execution of the
/// instruction is the one with the settled facts.
const Snap = struct {
    kills: []const Slot,
    frees: u64,
    moves: u64,
    ret: []const Leaf,
    ret_place: ?Slot,
    writes: []const SnapWrite,
    /// The function returns an error here: the result carries nothing, and the caller's `try` does not go on.
    failed: bool,
};

const SnapWrite = struct { into: Slot, descs: []const Desc };

pub const Run = struct {
    prog: *Program,
    arena: Allocator,
    pack: *const schema.Pack,
    v: View,
    ty: Types,
    func: schema.Func,
    name: []const u8,
    places: Places = .{},
    tokens: std.ArrayList(Token) = .empty,
    token_map: std.AutoHashMapUnmanaged(u64, dom.Id) = .empty,
    idents: std.ArrayList(Ident) = .empty,
    ident_map: std.AutoHashMapUnmanaged(Ident, dom.Id) = .empty,
    /// The objects (arenas, pools) an allocation was made from: it ends with them.
    region_of: std.AutoHashMapUnmanaged(dom.Id, Set) = .empty,
    /// How each tombstone came to be (the first time, on any path).
    tomb_events: std.AutoHashMapUnmanaged(dom.Id, Event) = .empty,
    /// The allocations that flow out of the function (into the result or into memory the caller owns), in order of
    /// appearance: the `k` of `Desc.fresh`.
    fresh_ids: std.ArrayList(dom.Id) = .empty,
    vals: []Val,
    by_id: []?*const Inst,
    names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    tok_names: std.AutoHashMapUnmanaged(dom.Id, []const u8) = .empty,
    /// The first stack slot a token was stored into: a variable named after it.
    tok_cells: std.AutoHashMapUnmanaged(dom.Id, u32) = .empty,
    /// Names of the fields places stand for.
    field_names: std.AutoHashMapUnmanaged(PlaceId, []const u8) = .empty,
    snaps: std.AutoArrayHashMapUnmanaged(u32, Snap) = .empty,
    /// The state before a call to a container operation that can fail by running out of memory.
    pre_state: std.AutoHashMapUnmanaged(u32, State) = .empty,
    /// The slots of the parameters that the function dereferenced.
    derefs: std.ArrayList(Slot) = .empty,
    /// The parameter place a fresh block was last stored into: a store through a pointer into it lands below that place.
    holder_of: std.AutoHashMapUnmanaged(dom.Id, PlaceId) = .empty,
    cancels: std.AutoHashMapUnmanaged(u32, Cancel) = .empty,
    /// The pointer to a field that a pointer to its parent (`@fieldParentPtr`) was made from, by that parent.
    up_of: std.AutoHashMapUnmanaged(PlaceId, PlaceId) = .empty,
    /// The instructions whose value has ever held an identity: the only ones an end or a rename can change.
    carriers: std.ArrayList(u32) = .empty,
    carries: []bool = &.{},
    /// Which definition of each instruction `vals` holds (0: none yet), and how many there have been.
    stamps: []u32 = &.{},
    defs: u32 = 0,
    /// The state of the instruction being run.
    cur: ?*State = null,
    /// Stores through a pointer into storage a parameter holds (`list.items[i] = x`): the elements of a container
    /// are not followed in memory, but the summary says they were written.
    elem_stores: std.AutoArrayHashMapUnmanaged(PlaceId, Val) = .empty,
    /// Contents of single-item pointers: objects, not buffers, so a container that moves its buffer leaves them be.
    pointees: std.AutoHashMapUnmanaged(dom.Id, void) = .empty,
    /// For the summary: bit i is set when a linear value that came in as parameter i went into memory the function
    /// does not own.
    token_stored: u64 = 0,
    /// The parameter a token came in as.
    param_of_tok: std.AutoHashMapUnmanaged(dom.Id, u32) = .empty,
    /// What a call that may move its argument did to it, for when the payload turns out to exist.
    moved_events: std.AutoHashMapUnmanaged(dom.Id, Event) = .empty,
    blocks: std.AutoHashMapUnmanaged(u32, *BlockCtx) = .empty,
    loops: std.AutoHashMapUnmanaged(u32, *LoopCtx) = .empty,
    preds: std.AutoHashMapUnmanaged(u32, Pred) = .empty,
    ends: std.AutoHashMapUnmanaged(dom.Id, Event) = .empty,
    diags: std.ArrayList(diag.Diag) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    stats: Stats = .{},
    /// The (instruction, kind) pairs already counted in `stats`: a loop body runs several times.
    tallied: std.AutoHashMapUnmanaged(u64, void) = .empty,
    quiet: u32 = 0,
    next_arg: u32 = 0,
    cur_loc: schema.LocId = .none,

    fn init(prog: *Program, arena: Allocator, ref: Ref) Allocator.Error!Run {
        var max_id: u32 = 0;
        maxId(ref.pack, ref.pack.instsOf(ref.func.insts), &max_id);
        const vals = try arena.alloc(Val, max_id + 1);
        @memset(vals, .none);
        const by_id = try arena.alloc(?*const Inst, max_id + 1);
        @memset(by_id, null);
        const stamps = try arena.alloc(u32, max_id + 1);
        @memset(stamps, 0);
        const carries = try arena.alloc(bool, max_id + 1);
        @memset(carries, false);
        var r: Run = .{
            .prog = prog,
            .arena = arena,
            .pack = ref.pack,
            .v = .{ .pack = ref.pack },
            .ty = try .init(arena, ref.pack),
            .func = ref.func,
            .name = ref.pack.str(ref.func.fqn),
            .vals = vals,
            .stamps = stamps,
            .carries = carries,
            .by_id = by_id,
        };
        r.index(ref.pack.instsOf(ref.func.insts));
        return r;
    }

    fn maxId(pack: *const schema.Pack, list: []const Inst, max: *u32) void {
        for (list) |inst| {
            max.* = @max(max.*, inst.id);
            for (pack.bodiesOf(inst)) |b| maxId(pack, pack.instsOf(b.insts), max);
        }
    }

    fn index(r: *Run, list: []const Inst) void {
        for (list) |*inst| {
            r.by_id[inst.id] = inst;
            for (r.v.bodies(inst)) |b| r.index(r.v.insts(b));
        }
    }

    // Results.

    fn execute(r: *Run) Allocator.Error!Result {
        var st: State = .{};
        var complete = true;
        r.exec(r.pack.instsOf(r.func.insts), &st) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => complete = false,
        };
        const arena = r.prog.arena;
        const diags = try arena.alloc(diag.Diag, r.diags.items.len);
        for (diags, r.diags.items) |*out, d| out.* = try r.persist(arena, d);
        var summary = try r.merge(arena);
        summary.complete = complete;
        summary.token_stores = r.token_stored;
        return .{ .name = try arena.dupe(u8, r.name), .diags = diags, .stats = r.stats, .summary = summary };
    }

    fn persist(r: *Run, arena: Allocator, d: diag.Diag) Allocator.Error!diag.Diag {
        _ = r;
        const copied = try arena.alloc(diag.Note, d.notes.len);
        for (copied, d.notes) |*out, n| out.* = .{ .loc = n.loc, .text = try arena.dupe(u8, n.text) };
        var trail: ?*const Trail = null;
        var items: std.ArrayList(Trail) = .empty;
        var at = d.trail;
        while (at) |t| : (at = t.prev) try items.append(arena, t.*);
        var k = items.items.len;
        while (k > 0) {
            k -= 1;
            const node = try arena.create(Trail);
            node.* = .{ .prev = trail, .loc = items.items[k].loc, .what = items.items[k].what };
            trail = node;
        }
        return .{ .kind = d.kind, .loc = d.loc, .text = try arena.dupe(u8, d.text), .notes = copied, .trail = trail };
    }

    /// Counts an assumption once per instruction, however many times the loop around it is run.
    pub fn tally(r: *Run, comptime field: []const u8, inst: *const Inst) Allocator.Error!void {
        const kind: u64 = comptime @intCast(std.meta.fieldIndex(Stats, field).?);
        const gop = try r.tallied.getOrPut(r.arena, (@as(u64, inst.id) << 8) | kind);
        if (!gop.found_existing) @field(r.stats, field) += 1;
    }

    // Findings.

    pub fn report(r: *Run, st: *const State, kind: diag.Kind, loc: schema.LocId, extra: []const diag.Note, comptime fmt: []const u8, args: anytype) Error!void {
        if (r.quiet != 0) return;
        const text = try std.fmt.allocPrint(r.arena, fmt, args);
        const key = try std.fmt.allocPrint(r.arena, "{t}@{d}:{s}", .{ kind, @backingInt(loc), text });
        const gop = try r.seen.getOrPut(r.arena, key);
        if (gop.found_existing) return;
        try r.diags.append(r.arena, .{ .kind = kind, .loc = loc, .text = text, .notes = extra, .trail = st.trail });
    }

    pub fn unsupported(r: *Run, inst: *const Inst, comptime fmt: []const u8, args: anytype) Error {
        const text = try std.fmt.allocPrint(r.arena, fmt, args);
        try r.diags.append(r.arena, .{ .kind = .unsupported, .loc = if (inst.loc != .none) inst.loc else r.cur_loc, .text = text });
        return error.Unsupported;
    }

    pub fn note(r: *Run, loc: schema.LocId, comptime fmt: []const u8, args: anytype) Allocator.Error!diag.Note {
        return .{ .loc = loc, .text = try std.fmt.allocPrint(r.arena, fmt, args) };
    }

    pub fn noteList(r: *Run, items: []const diag.Note) Allocator.Error![]const diag.Note {
        return r.arena.dupe(diag.Note, items);
    }

    // Tokens and identities.

    fn token(r: *Run, site: u32, sub: u32, loc: schema.LocId) Allocator.Error!dom.Id {
        const key = (@as(u64, site) << 32) | sub;
        const gop = try r.token_map.getOrPut(r.arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(r.tokens.items.len);
            try r.tokens.append(r.arena, .{ .site = site, .sub = sub, .loc = loc });
        }
        return gop.value_ptr.*;
    }

    pub fn ident(r: *Run, kind: Kind, a: u32, b: u32) Allocator.Error!dom.Id {
        const key: Ident = .{ .kind = kind, .a = a, .b = b };
        const gop = try r.ident_map.getOrPut(r.arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(r.idents.items.len);
            try r.idents.append(r.arena, key);
        }
        return gop.value_ptr.*;
    }

    /// A new allocation or object of `a`, result `sub`. Each site has two names: the most recent block, and the
    /// summary of every older one. A site that runs again while its block is still alive demotes what the first name
    /// stood for into the summary (in the state and in the values the path computed); a block that was ended is
    /// already a tombstone wherever it is held, so its name is free to use.
    pub fn mint(r: *Run, st: *State, kind: Kind, a: u32, sub: u32) Allocator.Error!dom.Id {
        const cur = try r.ident(kind, a, sub * 2);
        if (st.alloced.has(cur)) try r.demote(st, cur, try r.ident(kind, a, sub * 2 + 1));
        st.alloced = try st.alloced.with(r.arena, cur);
        _ = st.dead.swapRemove(cur);
        return cur;
    }

    /// Whether `v` holds `from` anywhere.
    fn holds(v: Val, from: dom.Id, moved: bool) bool {
        if (v.ids.has(from) or v.obj.has(from) or (moved and v.moved.has(from))) return true;
        if (v.parts) |parts| for (parts) |part| if (holds(part, from, moved)) return true;
        return false;
    }

    /// `v` with `from` replaced by `to`, or with `to` added next to `from` when `keep`.
    fn swapped(r: *Run, v: Val, from: dom.Id, to: dom.Id, keep: bool, moved: bool) Allocator.Error!Val {
        if (!holds(v, from, moved)) return v;
        var out = v;
        for ([_]*Set{ &out.ids, &out.obj, &out.moved }, [_]bool{ true, true, moved }) |set_, on| {
            if (on and set_.has(from)) set_.* = try (if (keep) set_.* else try set_.without(r.arena, from)).with(r.arena, to);
        }
        if (v.parts) |parts| {
            const copy = try r.arena.alloc(Val, parts.len);
            for (copy, parts) |*slot, part| slot.* = try r.swapped(part, from, to, keep, moved);
            out.parts = copy;
        }
        return out;
    }

    /// Every value the path holds: the memory, the values computed so far.
    /// Drops the changed values of definitions that have been replaced since.
    fn pruneOver(r: *Run, st: *State) void {
        var k: usize = 0;
        while (k < st.over.count()) {
            if (st.over.values()[k].stamp != r.stamps[st.over.keys()[k]]) st.over.swapRemoveAt(k) else k += 1;
        }
    }

    fn swapAll(r: *Run, st: *State, from: dom.Id, to: dom.Id, keep: bool, moved: bool) Allocator.Error!void {
        r.pruneOver(st);
        for (st.mem.values()) |*v| v.* = try r.swapped(v.*, from, to, keep, moved);
        for (st.pending.values()) |*v| if (v.ident == from) {
            v.ident = to;
        };
        for (r.carriers.items) |i| {
            if (r.stamps[i] == 0) continue;
            const v = if (st.over.get(i)) |ov| (if (ov.stamp == r.stamps[i]) ov.val else r.vals[i]) else r.vals[i];
            if (!holds(v, from, moved)) continue;
            try st.over.put(r.arena, i, .{ .val = try r.swapped(v, from, to, keep, moved), .stamp = r.stamps[i] });
        }
    }

    fn demote(r: *Run, st: *State, from: dom.Id, to: dom.Id) Allocator.Error!void {
        if (st.alloced.has(to)) st.multi = try st.multi.with(r.arena, to);
        st.alloced = try (try st.alloced.without(r.arena, from)).with(r.arena, to);
        if (r.region_of.get(from)) |regions| {
            const have = r.region_of.get(to) orelse Set.empty;
            try r.region_of.put(r.arena, to, try have.merge(r.arena, regions));
        }
        try r.swapAll(st, from, to, false, true);
    }

    /// The tombstone of `id`: a value that holds it leads into memory that is gone. A soft one (`id` stands for several
    /// blocks, or the end depends on room nobody could read) is only counted when used.
    pub fn tomb(r: *Run, id: dom.Id, soft: bool) Allocator.Error!dom.Id {
        return r.ident(.tomb, id, @intFromBool(soft));
    }

    /// Ends `id` on this path: every value that holds it holds its tombstone from now on.
    pub fn kill(r: *Run, st: *State, id: dom.Id, event: Event) Allocator.Error!void {
        if (r.identRec(id).kind == .tomb) return;
        const soft = event.soft or (st.multi.has(id) and !event.exact);
        var e = event;
        e.soft = soft;
        const t = try r.tomb(id, soft);
        const gop = try r.tomb_events.getOrPut(r.arena, t);
        if (!gop.found_existing) gop.value_ptr.* = e;
        const marked = try st.dead.getOrPut(r.arena, id);
        // Already gone at least as surely: every value holds its tombstone already.
        if (marked.found_existing and (!marked.value_ptr.soft or soft)) return;
        marked.value_ptr.* = e;
        if (!soft) st.alloced = try st.alloced.without(r.arena, id);
        try r.swapAll(st, id, t, soft, false);
    }

    pub fn identRec(r: *Run, id: dom.Id) Ident {
        return r.idents.items[id];
    }

    /// The parameter a place hangs below, when it is rooted at one.
    /// The step to the element at an index: its own place for a constant index (as a field of a struct), the place of
    /// all of them otherwise.
    fn elemStep(r: *Run, at: schema.Operand) u32 {
        if (at.kind != .constant) return dom.elem_step;
        const k = r.v.constant(at);
        return if (k.kind == .int and k.a < (1 << 20)) dom.index_step + @as(u32, @intCast(k.a)) else dom.elem_step;
    }

    pub fn paramOf(r: *Run, pl: PlaceId) ?u32 {
        const rec = r.places.rec(pl);
        return if (rec.kind == .param) rec.n else null;
    }

    pub fn slotOfPlace(r: *Run, pl: PlaceId, kind: SlotKind) Allocator.Error!?Slot {
        const n = r.paramOf(pl) orelse return null;
        return .{ .param = n, .path = try r.places.path(r.arena, pl), .kind = kind };
    }

    /// The slot of the caller's world an identity stands for, if it stands for one.
    pub fn slotOf(r: *Run, id: dom.Id) Allocator.Error!?Slot {
        const rec = r.identRec(id);
        return switch (rec.kind) {
            .init => try r.slotOfPlace(rec.a, switch (rec.b) {
                0 => .value,
                1 => .content,
                else => .view,
            }),
            .object => try r.slotOfPlace(rec.a, .object),
            else => null,
        };
    }

    /// The `k` of `Desc.fresh` for an allocation of this run.
    fn freshIndex(r: *Run, id: dom.Id) Allocator.Error!u32 {
        for (r.fresh_ids.items, 0..) |x, i| if (x == id) return @intCast(i);
        try r.fresh_ids.append(r.arena, id);
        return @intCast(r.fresh_ids.items.len - 1);
    }

    pub fn descsOf(r: *Run, v: Val) Allocator.Error![]const Desc {
        var out: std.ArrayList(Desc) = .empty;
        // Memory that is already gone is only reported as gone when nothing alive is left in the value.
        var live = false;
        for (v.ids.ids) |id| live = live or r.identRec(id).kind != .tomb;
        for ([_]Set{ v.ids, v.obj }, [_]bool{ false, true }) |set_, is_obj| for (set_.ids) |id| {
            const rec = r.identRec(id);
            const d: Desc = .{ .src = switch (rec.kind) {
                .heap => .{ .fresh = try r.freshIndex(id) },
                .init, .object => .{ .from = (try r.slotOf(id)) orelse continue },
                .tomb => if (rec.b == 0 and !live) .gone else continue,
                .local => continue,
            }, .obj = is_obj };
            var dup = false;
            for (out.items) |x| if (x.eql(d)) {
                dup = true;
            };
            if (!dup) try out.append(r.arena, d);
        };
        return out.items;
    }

    fn nameOf(r: *Run, site: u32) []const u8 {
        return r.names.get(site) orelse "(unnamed)";
    }

    fn created(r: *Run, t: dom.Id) Allocator.Error!diag.Note {
        const loc = r.tokens.items[t].loc;
        if (loc == .none) return .{ .loc = .none, .text = try std.fmt.allocPrint(r.arena, "`{s}` is a parameter: this function owns it and must consume it", .{r.tokenName(t)}) };
        return r.note(loc, "`{s}` was created here", .{r.tokenName(t)});
    }

    fn tokenName(r: *Run, t: dom.Id) []const u8 {
        const tok = r.tokens.items[t];
        if (r.names.get(tok.site)) |n| return n;
        if (r.tok_cells.get(t)) |cell| if (r.names.get(cell)) |n| return n;
        return r.tok_names.get(t) orelse "(unnamed)";
    }

    // Values.

    pub fn operand(r: *Run, o: schema.Operand) Val {
        return switch (o.kind) {
            .inst => r.valueOf(o.value),
            .constant => blk: {
                // The address of a global: memory of its own that nothing ends.
                const k = r.v.constant(o);
                if (k.kind == .undef or k.kind == .null or !r.ty.isPointer(k.ty)) break :blk .none;
                const pl = r.places.root(r.arena, .other, o.value) catch break :blk .none;
                break :blk .{ .place = pl, .off = 0 };
            },
            else => .none,
        };
    }

    fn valueOf(r: *Run, id: u32) Val {
        if (r.cur) |st| if (st.over.get(id)) |ov| if (ov.stamp == r.stamps[id]) return ov.val;
        return r.vals[id];
    }

    pub fn arg(r: *Run, inst: *const Inst, i: usize) Val {
        return r.operand(r.v.ops(inst)[i]);
    }

    pub fn operandType(r: *Run, o: schema.Operand) schema.TypeId {
        return switch (o.kind) {
            .inst => if (r.by_id[o.value]) |i| i.ty else .none,
            .constant => r.v.constant(o).ty,
            .none => .none,
        };
    }

    pub fn set(r: *Run, inst: *const Inst, val: Val) void {
        r.defs += 1;
        r.stamps[inst.id] = r.defs;
        // A number points nowhere and holds nothing, whatever it was computed from.
        r.vals[inst.id] = switch (r.ty.kind(inst.ty)) {
            .int, .bool, .float, .@"enum", .error_set, .comptime_int, .comptime_float, .void, .noreturn, .enum_literal => Val.none,
            else => val,
        };
        const v = r.vals[inst.id];
        if (!r.carries[inst.id] and (!v.ids.isEmpty() or !v.obj.isEmpty() or !v.moved.isEmpty() or v.parts != null)) {
            r.carries[inst.id] = true;
            r.carriers.append(r.arena, inst.id) catch {};
        }
    }

    /// A value of type `ty` made of fresh tokens, all of them live.
    fn fresh(r: *Run, st: *State, inst: *const Inst, ty: schema.TypeId, sub: *u32) Error!Val {
        if (!r.ty.hasTokens(ty)) return .none;
        const rec = r.ty.rec(ty);
        switch (rec.kind) {
            .@"struct" => {
                if (r.ty.isLinear(ty)) {
                    const t = try r.token(inst.id, sub.*, inst.loc);
                    sub.* += 1;
                    if (st.live.has(t)) {
                        const earlier = try r.note(r.tokens.items[t].loc, "created here", .{});
                        try r.report(st, .leak, inst.loc, try r.noteList(&.{earlier}), "linear value `{s}` is replaced before it is consumed (this site runs again)", .{r.tokenName(t)});
                    }
                    st.live = try st.live.with(r.arena, t);
                    st.ended = try st.ended.without(r.arena, t);
                    return .{ .toks = try Set.single(r.arena, t) };
                }
                const fields = r.pack.fieldsOf(ty) orelse return r.unsupported(inst, "a value of {s} holds a linear value but the pack lacks its fields", .{r.ty.name(ty)});
                const parts = try r.arena.alloc(Val, fields.len);
                for (parts, fields) |*part, f| part.* = try r.fresh(st, inst, f.ty, sub);
                return Val.aggregate(r.arena, parts);
            },
            .@"union" => return r.unsupported(inst, "a union ({s}) holds a linear value", .{r.ty.name(ty)}),
            .optional, .error_union => return r.fresh(st, inst, rec.child, sub),
            else => return r.unsupported(inst, "an array or vector ({s}) of linear values", .{r.ty.name(ty)}),
        }
    }

    // Memory. A struct whose fields the pack knows lives in memory field by field, so that a copy of it copies the
    // identities of every field and a write to one field leaves the others as they were.

    /// The object identities stored at `pl` (not minted when there are none).
    pub fn objAt(r: *Run, st: *const State, pl: PlaceId) Set {
        const slot = r.places.find(pl, dom.obj_step) orelse return .empty;
        return if (st.mem.get(slot)) |v| v.ids else .empty;
    }

    /// The object identities of the aggregate at `pl`; a new incarnation when it has none yet.
    pub fn ensureObj(r: *Run, st: *State, pl: PlaceId) Allocator.Error!Set {
        const have = r.objAt(st, pl);
        if (!have.isEmpty()) return have;
        const id = try r.mint(st, .object, pl, 0);
        const ids = try Set.single(r.arena, id);
        try st.mem.put(r.arena, try r.places.child(r.arena, pl, dom.obj_step), .{ .ids = ids });
        return ids;
    }

    /// What the caller put at a place that nothing in this run has written: the storage behind it, as one value.
    fn isPlaceholder(r: *Run, v: Val, pl: PlaceId) Allocator.Error!bool {
        return v.ids.ids.len == 1 and v.parts == null and v.toks.isEmpty() and v.ids.ids[0] == try r.ident(.init, pl, 1);
    }

    fn untouched(r: *Run, st: *State, pl: PlaceId) Allocator.Error!bool {
        const v = st.mem.get(pl) orelse return true;
        return r.isPlaceholder(v, pl);
    }

    pub fn readVal(r: *Run, st: *State, pl: PlaceId, ty: schema.TypeId) Allocator.Error!Val {
        return r.readDepth(st, pl, ty, 0);
    }

    fn readDepth(r: *Run, st: *State, pl: PlaceId, ty: schema.TypeId, depth: u32) Allocator.Error!Val {
        if (depth < 6 and try r.untouched(st, pl)) if (r.ty.structFields(ty)) |fields| {
            const parts = try r.arena.alloc(Val, fields.len);
            for (parts, fields, 0..) |*part, f, k| part.* = try r.readDepth(st, try r.places.child(r.arena, pl, @intCast(k)), f.ty, depth + 1);
            var out = try Val.aggregate(r.arena, parts);
            out.obj = r.objAt(st, pl);
            return out;
        };
        var out = try r.readLeaf(st, pl, ty, true);
        out.obj = r.objAt(st, pl);
        return out;
    }

    /// Everything stored at, above or below `pl`, as one value; nothing is made up for what was never touched.
    pub fn peekFlat(r: *Run, st: *State, pl: PlaceId) Allocator.Error!Val {
        return (try r.readLeaf(st, pl, .none, false)).flat();
    }

    /// `key` is a field of `pl`, not one of its elements (what a container holds is not what its storage is) and not
    /// the bookkeeping of the object.
    fn partOf(r: *Run, pl: PlaceId, key: PlaceId, elems: bool) bool {
        if (key == pl) return false;
        var at = key;
        while (at != pl) {
            const rec = r.places.rec(at);
            if ((rec.step == dom.elem_step and !elems) or rec.step == dom.obj_step or rec.step == dom.len_step) return false;
            at = rec.parent;
            if (at == dom.no_place) return false;
        }
        return true;
    }

    pub fn readLeaf(r: *Run, st: *State, pl: PlaceId, ty: schema.TypeId, lazy: bool) Allocator.Error!Val {
        // The elements of an array stored inline are part of the value; those of a slice are not part of the slice.
        const elems = ty != .none and r.ty.kind(ty) != .pointer;
        if (st.mem.get(pl)) |v| {
            // Parts written after the whole was stored are newer than it.
            var out = v;
            var it = st.mem.iterator();
            while (it.next()) |e| {
                if (r.partOf(pl, e.key_ptr.*, elems)) out = try out.flat().join(r.arena, e.value_ptr.flat());
            }
            return out;
        }
        // Stored whole in an ancestor: project the fields down.
        var path: std.ArrayList(u32) = .empty;
        var at = pl;
        while (true) {
            const rec = r.places.rec(at);
            if (rec.parent == dom.no_place) break;
            try path.append(r.arena, rec.step);
            at = rec.parent;
            if (st.mem.get(at)) |whole| {
                if (try r.isPlaceholder(whole, at)) continue;
                var v = whole;
                var k = path.items.len;
                while (k > 0) {
                    k -= 1;
                    const s = path.items[k];
                    v = if (s == dom.elem_step) v.flat() else v.field(s);
                }
                return v;
            }
        }
        // Stored piecewise below: everything under it, as one value.
        var out: Val = .none;
        var found = false;
        var it = st.mem.iterator();
        while (it.next()) |e| {
            if (r.places.contains(pl, e.key_ptr.*) and r.partOf(pl, e.key_ptr.*, elems)) {
                out = try out.join(r.arena, e.value_ptr.flat());
                found = true;
            }
        }
        if (found) return out;
        // What the caller put there: the storage behind a parameter that nothing in this run has touched yet.
        if (lazy and r.paramOf(pl) != null and (ty == .none or r.ty.hasPointers(ty))) {
            const id = try r.ident(.init, pl, 1);
            if (ty != .none and r.ty.isSingle(ty)) try r.pointees.put(r.arena, id, {});
            const v: Val = .{ .ids = try Set.single(r.arena, id) };
            try st.mem.put(r.arena, pl, v);
            return v;
        }
        return out;
    }

    pub fn writeVal(r: *Run, st: *State, pl: PlaceId, val: Val, ty: schema.TypeId) Allocator.Error!void {
        return r.writeDepth(st, pl, val, ty, 0);
    }

    pub fn strongAt(r: *Run, pl: PlaceId) bool {
        const kind = r.places.rec(pl).kind;
        return (kind == .cell or kind == .param) and !r.places.hasElem(pl);
    }

    fn writeDepth(r: *Run, st: *State, pl: PlaceId, val: Val, ty: schema.TypeId, depth: u32) Allocator.Error!void {
        if (depth < 6) if (r.ty.structFields(ty)) |fields| if (val.parts == null or val.parts.?.len == fields.len) {
            if (r.strongAt(pl)) _ = st.mem.swapRemove(pl);
            for (fields, 0..) |f, k| {
                // A number holds nothing, whatever the value it was cut out of held.
                var part: Val = if (r.ty.hasTokens(f.ty) or r.ty.hasPointers(f.ty)) val.field(k) else .none;
                const at = try r.places.child(r.arena, pl, @intCast(k));
                if (val.parts == null) part.ids = try r.notSiblings(part.ids, pl, at);
                try r.writeDepth(st, at, part, f.ty, depth + 1);
            }
            return r.writeObj(st, pl, val.obj);
        };
        try r.writeLeaf(st, pl, val);
        try r.writeObj(st, pl, val.obj);
    }

    /// A struct stored whole from a value that does not say which field holds what: memory known to live in another
    /// field of the same struct is not what this field holds.
    fn notSiblings(r: *Run, ids: Set, whole: PlaceId, field: PlaceId) Allocator.Error!Set {
        var out: Set = .empty;
        for (ids.ids) |id| {
            const rec = r.identRec(id);
            const home: ?PlaceId = switch (rec.kind) {
                .init => rec.a,
                .heap => r.holder_of.get(id),
                else => null,
            };
            if (home) |h| if (r.places.contains(whole, h) and !r.places.contains(field, h)) continue;
            out = try out.with(r.arena, id);
        }
        return out;
    }

    pub fn writeObj(r: *Run, st: *State, pl: PlaceId, obj: Set) Allocator.Error!void {
        const slot = try r.places.child(r.arena, pl, dom.obj_step);
        if (r.strongAt(pl)) {
            // Below a parameter, no object says the caller's is gone and the next use starts a new one.
            if (obj.isEmpty() and r.paramOf(pl) == null) _ = st.mem.swapRemove(slot) else try st.mem.put(r.arena, slot, .{ .ids = obj });
        } else if (!obj.isEmpty()) {
            const old = st.mem.get(slot) orelse Val.none;
            try st.mem.put(r.arena, slot, .{ .ids = try old.ids.merge(r.arena, obj) });
        }
    }

    fn writeLeaf(r: *Run, st: *State, pl: PlaceId, val: Val) Allocator.Error!void {
        return r.writeLeafAs(st, pl, val, r.strongAt(pl));
    }

    pub fn writeLeafAs(r: *Run, st: *State, pl: PlaceId, val: Val, strong: bool) Allocator.Error!void {
        // Whatever was stored below is overwritten.
        if (strong) {
            var k: usize = 0;
            while (k < st.mem.count()) {
                if (st.mem.keys()[k] != pl and r.places.contains(pl, st.mem.keys()[k])) {
                    st.mem.swapRemoveAt(k);
                } else k += 1;
            }
        }
        var stored = val;
        stored.obj = .empty;
        if (r.paramOf(pl) != null) for (val.ids.ids) |id| if (r.identRec(id).kind == .heap) try r.holder_of.put(r.arena, id, pl);
        const gop = try st.mem.getOrPut(r.arena, pl);
        gop.value_ptr.* = if (strong or !gop.found_existing) stored else try gop.value_ptr.join(r.arena, stored);
    }

    pub fn isLocalPtr(r: *Run, p: Val) bool {
        if (p.place) |pl| return r.places.rec(pl).kind == .cell;
        if (p.ids.isEmpty()) return false;
        for (p.ids.ids) |o| if (r.identRec(o).kind != .local) return false;
        return true;
    }

    // Ending.

    fn anyAlt(v: Val) bool {
        if (v.alt) return true;
        if (v.parts) |parts| for (parts) |p| if (anyAlt(p)) return true;
        return false;
    }

    /// Ends the tokens of `val` for `how` (a phrase for the finding): a sink.
    pub fn sink(r: *Run, st: *State, inst: *const Inst, val: Val, comptime how: []const u8, callee: []const u8) Error!void {
        if (anyAlt(val) and val.toks.meets(st.ended))
            return r.unsupported(inst, "a linear value that may be one of several (a join merged them) is consumed, and one of them was consumed before: the checker cannot tell which", .{});
        for (val.toks.ids) |t| {
            if (st.ended.has(t)) {
                var items: std.ArrayList(diag.Note) = .empty;
                if (r.ends.get(t)) |e| try items.append(r.arena, .{ .loc = e.loc, .text = e.text });
                try items.append(r.arena, try r.created(t));
                const maybe = if (st.live.has(t)) "may already have been" else "was already";
                try r.report(st, .double_consume, inst.loc, try r.noteList(items.items), "linear value `{s}` {s} consumed", .{ r.tokenName(t), maybe });
            }
            st.live = try st.live.without(r.arena, t);
            st.ended = try st.ended.with(r.arena, t);
            const text = if (callee.len != 0)
                try std.fmt.allocPrint(r.arena, "first " ++ how ++ " here (`{s}`)", .{callee})
            else
                try std.fmt.allocPrint(r.arena, "first " ++ how ++ " here", .{});
            try r.ends.put(r.arena, t, .{ .loc = inst.loc, .text = text, .trail = st.trail });
        }
    }

    /// A read of `val`: its tokens must not be consumed already, and what it points into must be alive.
    pub fn use(r: *Run, st: *State, inst: *const Inst, val: Val, what: []const u8) Error!void {
        for (val.toks.ids) |t| if (st.ended.has(t)) {
            var items: std.ArrayList(diag.Note) = .empty;
            if (r.ends.get(t)) |e| try items.append(r.arena, .{ .loc = e.loc, .text = e.text });
            try r.report(st, .use_after_consume, inst.loc, try r.noteList(items.items), "linear value `{s}` is {s} after it was consumed", .{ r.tokenName(t), what });
        };
        try r.alive(st, inst, val, what);
    }

    /// A read or a write through `val`: the caller must have what it leads into.
    fn noteDeref(r: *Run, val: Val, what: []const u8) Allocator.Error!void {
        const deref = std.mem.eql(u8, what, "read") or std.mem.eql(u8, what, "write") or std.mem.eql(u8, what, "read and written") or std.mem.eql(u8, what, "written") or std.mem.eql(u8, what, "read by a callee");
        if (!deref) return;
        for (val.ids.ids) |id| {
            const rec = r.identRec(id);
            if (rec.kind != .init or (rec.b == 0 and r.places.rec(rec.a).parent == dom.no_place)) continue;
            const slot = (try r.slotOf(id)) orelse continue;
            if (slot.kind == .view) continue;
            var have = false;
            for (r.derefs.items) |x| if (x.eql(slot)) {
                have = true;
            };
            if (!have) try r.derefs.append(r.arena, slot);
        }
    }

    /// Everything `val` depends on must still exist. A tombstone of a block that stands for several, or of an end that
    /// depends on room nobody could read, is counted and not reported.
    pub fn alive(r: *Run, st: *State, inst: *const Inst, val: Val, what: []const u8) Error!void {
        try r.noteDeref(val, what);
        var soft = false;
        var first: ?dom.Id = null;
        for (val.ids.ids) |o| {
            const rec = r.identRec(o);
            if (rec.kind == .heap or rec.kind == .init) try r.tally("uses", inst);
            if (rec.kind != .tomb) continue;
            try r.tally("uses", inst);
            if (rec.b == 1) {
                soft = true;
            } else if (first == null) first = o;
        }
        const o = first orelse {
            if (soft) try r.tally("maybe_stale", inst);
            return;
        };
        var items: std.ArrayList(diag.Note) = .empty;
        if (st.dead.get(r.identRec(o).a) orelse r.tomb_events.get(o)) |e| try items.append(r.arena, .{ .loc = e.loc, .text = e.text });
        if (try r.origin(r.identRec(o).a)) |where| try items.append(r.arena, where);
        try r.report(st, .use_after_free, inst.loc, try r.noteList(items.items), "memory that was freed or invalidated is used here ({s})", .{what});
    }

    /// Where the pointer that depends on identity `o` came from, for the finding that names it.
    fn origin(r: *Run, o: dom.Id) Allocator.Error!?diag.Note {
        const rec = r.identRec(o);
        switch (rec.kind) {
            .heap => {
                const at = if (r.by_id[rec.a]) |i| i.loc else .none;
                return try r.note(at, "the memory was allocated here", .{});
            },
            .init => if (rec.b == 1) return try r.note(.none, "the storage behind `{s}`", .{r.placeName(rec.a)}),
            else => {},
        }
        return null;
    }

    /// An object (an arena, a container) that was deinitialized must not be touched.
    pub fn objectAlive(r: *Run, st: *State, inst: *const Inst, pl: PlaceId) Error!void {
        return r.objectAliveFrom(st, inst, pl, true);
    }

    /// With `self` false the object at `pl` itself may be dead: a store of the whole of it starts it afresh.
    pub fn objectAliveFrom(r: *Run, st: *State, inst: *const Inst, pl: PlaceId, self: bool) Error!void {
        var at = pl;
        var first = true;
        while (true) : (first = false) {
            if (first and !self) {
                at = r.places.rec(at).parent;
                if (at == dom.no_place) break;
                continue;
            }
            for (r.objAt(st, at).ids) |id| {
                if (r.identRec(id).kind != .tomb or r.identRec(id).b == 1) continue;
                const e = st.dead.get(r.identRec(id).a) orelse r.tomb_events.get(id) orelse continue;
                // What this very call ended is not a use of it.
                if (e.loc == inst.loc) continue;
                var items: std.ArrayList(diag.Note) = .empty;
                try items.append(r.arena, .{ .loc = e.loc, .text = e.text });
                try r.report(st, .use_after_free, inst.loc, try r.noteList(items.items), "`{s}` is used after it was deinitialized", .{r.placeName(at)});
            }
            at = r.places.rec(at).parent;
            if (at == dom.no_place) break;
        }
    }

    // Memory access.

    fn elemType(r: *Run, ty: schema.TypeId) schema.TypeId {
        const pt = r.ty.pointee(ty) orelse return .none;
        const rec = r.ty.rec(pt);
        return if (rec.kind == .array) rec.child else pt;
    }

    /// The number of elements a pointer to a fixed-size array covers; null for a slice or a pointer to one.
    fn coveredLen(r: *Run, ty: schema.TypeId) ?u64 {
        const pt = r.ty.pointee(ty) orelse return null;
        const rec = r.ty.rec(pt);
        return if (rec.kind == .array) rec.len else null;
    }

    /// `@memcpy` needs disjoint memory. Two ranges of one array whose offsets and sizes are constants are known to be
    /// disjoint or not; anything dynamic is left to the safety check.
    fn checkDisjoint(r: *Run, st: *State, inst: *const Inst, dst: Val, src: Val) Error!void {
        const ops = r.v.ops(inst);
        const dp = dst.place orelse return;
        const sp = src.place orelse return;
        if (dp != sp) return;
        const do = dst.off orelse return;
        const so = src.off orelse return;
        const dl: i64 = @intCast(r.coveredLen(r.operandType(ops[0])) orelse return);
        const sl: i64 = @intCast(r.coveredLen(r.operandType(ops[1])) orelse return);
        if (do < so + sl and so < do + dl)
            try r.report(st, .alias, inst.loc, &.{}, "the range [{d}, {d}) is copied onto [{d}, {d}) of `{s}`, which overlaps it", .{ so, so + sl, do, do + dl, r.placeName(dp) });
    }

    pub fn pointeeOf(r: *Run, ptr_ty: schema.TypeId) schema.TypeId {
        return r.ty.pointee(ptr_ty) orelse .none;
    }

    /// The value of a by-value parameter: the identities of what the caller passed, field by field.
    fn paramVal(r: *Run, st: *State, ty: schema.TypeId, pl: PlaceId, depth: u32) Allocator.Error!Val {
        const holder = r.ty.kind(r.ty.payload(ty)) == .@"struct" and !r.ty.isAllocator(ty);
        // A struct without pointers can still be a handle: freeing it frees what the caller gave.
        if (!r.ty.hasPointers(ty)) return if (r.ty.kind(ty) == .@"struct") .{ .ids = try Set.single(r.arena, try r.ident(.init, pl, 0)) } else .none;
        if (depth < 5 and holder) if (r.ty.structFields(ty)) |fields| {
            const parts = try r.arena.alloc(Val, fields.len);
            for (parts, fields, 0..) |*part, f, k| part.* = try r.paramVal(st, f.ty, try r.places.child(r.arena, pl, @intCast(k)), depth + 1);
            var out = try Val.aggregate(r.arena, parts);
            if (r.ty.hasPointers(ty)) out.obj = try Set.single(r.arena, try r.mint(st, .object, pl, 0));
            return out;
        };
        var out: Val = .{ .ids = try Set.single(r.arena, try r.ident(.init, pl, 0)) };
        if (holder and r.ty.hasPointers(ty)) out.obj = try Set.single(r.arena, try r.mint(st, .object, pl, 0));
        return out;
    }

    fn stepArg(r: *Run, inst: *const Inst, st: *State) Error!void {
        const i = r.next_arg;
        r.next_arg += 1;
        var sub: u32 = 0;
        var val = try r.fresh(st, inst, inst.ty, &sub);
        const given: ?[]const u8 = if (r.prog.param_names) |pn| pn.lookup(pn.context, .{ .pack = r.pack, .func = r.func }, i) else null;
        for (val.toks.ids) |t| {
            try r.tok_names.put(r.arena, t, given orelse try std.fmt.allocPrint(r.arena, "parameter {d}", .{i}));
            try r.param_of_tok.put(r.arena, t, i);
        }
        const root = try r.places.root(r.arena, .param, i);
        if (r.ty.isPointer(inst.ty)) {
            val.place = root;
            val.off = 0;
            val.ids = try Set.single(r.arena, try r.ident(.init, root, 0));
        } else if (!r.ty.hasTokens(inst.ty)) {
            val = try r.paramVal(st, inst.ty, root, 0);
        } else if (r.ty.hasPointers(inst.ty) or r.ty.kind(inst.ty) == .@"struct") {
            val.ids = try Set.single(r.arena, try r.ident(.init, root, 0));
        }
        r.set(inst, val);
    }

    pub fn store(r: *Run, inst: *const Inst, st: *State, ptr: Val, val: Val, val_ty: schema.TypeId, undef: bool) Error!void {
        try r.alive(st, inst, ptr, "write");
        try r.escapes(st, inst, val, r.isLocalPtr(ptr), "stored into memory that outlives it");
        if (ptr.place) |pl| {
            try r.objectAliveFrom(st, inst, pl, false);
            try r.dropCapsAt(st, pl);
            const kind = r.places.rec(pl).kind;
            if (kind == .cell) for (val.toks.ids) |t| {
                const gop = try r.tok_cells.getOrPut(r.arena, t);
                if (!gop.found_existing) gop.value_ptr.* = r.places.rec(pl).n;
            };
            if (kind != .cell and !val.toks.isEmpty()) {
                try r.tally("transfers", inst);
                r.noteTokenStored(val);
                try r.sink(st, inst, val, "stored into memory the caller owns", "");
            }
            // Poison is not a fresh object: what ended stays ended.
            const before = r.objAt(st, pl);
            try r.writeVal(st, pl, val, val_ty);
            if (undef) {
                var k: usize = 0;
                while (k < st.mem.count()) {
                    const key = st.mem.keys()[k];
                    if (r.places.rec(key).step == dom.obj_step and st.mem.values()[k].ids.isEmpty() and r.places.contains(pl, key)) st.mem.swapRemoveAt(k) else k += 1;
                }
                if (!before.isEmpty()) try r.writeObj(st, pl, before);
            }
        } else {
            // A store through a pointer into the storage a parameter holds (`list.items[i] = x` by way of a pointer a
            // callee returned) lands below that parameter: not followed in memory, but the summary says it.
            for (ptr.ids.ids) |o| {
                const rec = r.identRec(o);
                const held: PlaceId = switch (rec.kind) {
                    .init => if (rec.b == 1) rec.a else continue,
                    .heap => r.holder_of.get(o) orelse continue,
                    else => continue,
                };
                const at = try r.places.child(r.arena, held, dom.elem_step);
                const gop = try r.elem_stores.getOrPut(r.arena, at);
                gop.value_ptr.* = if (gop.found_existing) try gop.value_ptr.join(r.arena, val.flat()) else val.flat();
            }
            if (!val.toks.isEmpty()) {
                try r.tally("transfers", inst);
                r.noteTokenStored(val);
                try r.sink(st, inst, val, "stored into memory the checker does not track", "");
            }
        }
    }

    /// For the summary: a linear value that came in as a parameter went into memory the function does not own.
    fn noteTokenStored(r: *Run, val: Val) void {
        for (val.toks.ids) |t| if (r.param_of_tok.get(t)) |pi| if (pi < 64) {
            r.token_stored |= @as(u64, 1) << @intCast(pi);
        };
    }

    pub fn load(r: *Run, st: *State, inst: *const Inst, ptr: Val, ty: schema.TypeId) Error!Val {
        var out: Val = .none;
        // A temporary the compiler built to return a fresh value is not a copy of anything the program named.
        const temporary = if (ptr.place) |pl| r.places.rec(pl).kind == .cell and !r.names.contains(r.places.rec(pl).n) else false;
        if (r.ty.isPinned(ty) and !temporary) try r.report(st, .pinned_copy, inst.loc, &.{}, "a value of the pinned type `{s}` is copied by value; pass a pointer to it", .{r.ty.name(ty)});
        if (ptr.place) |pl| {
            try r.objectAlive(st, inst, pl);
            out = try r.readVal(st, pl, ty);
            if (r.places.rec(pl).kind != .cell and r.ty.hasTokens(ty))
                return r.unsupported(inst, "a linear value read out of memory this function does not own", .{});
            const wrapped = r.ty.kind(ty) == .optional or r.ty.kind(ty) == .error_union;
            if (out.src == null and r.ty.kind(r.ty.payload(ty)) == .@"struct") out.src = pl;
            if (wrapped) out.from = pl;
            if (r.ty.hasPointers(ty) and r.ty.kind(r.ty.payload(ty)) == .@"struct" and !r.ty.isAllocator(r.ty.payload(ty)) and out.obj.isEmpty())
                out.obj = try r.ensureObj(st, pl);
        } else if (r.ty.hasTokens(ty)) {
            return r.unsupported(inst, "a linear value read through a pointer the checker cannot follow", .{});
        }
        if (ptr.many or (ptr.place != null and r.places.hasElem(ptr.place.?))) out.many = true;
        // A number read out of a stale handle is data, not a use of what the handle names.
        switch (r.ty.kind(ty)) {
            .int, .bool, .float, .@"enum", .error_set => return Val.none,
            else => {},
        }
        return out;
    }

    /// A pointer, slice, or an optional or error union of one: the result itself points somewhere.
    pub fn topLevelPointer(r: *Run, ty: schema.TypeId) bool {
        return switch (r.ty.kind(ty)) {
            .pointer => true,
            .optional, .error_union => r.topLevelPointer(r.ty.rec(ty).child),
            else => false,
        };
    }

    /// `ids` in the storage fields of a value of type `ty` and nowhere else (not in the allocator it was given, nor in
    /// the table of functions it calls through); a flat value when the fields of the type are not known.
    pub fn inStorage(r: *Run, ty: schema.TypeId, ids: Set, depth: u32) Allocator.Error!Val {
        if (r.ty.isAllocator(r.ty.payload(ty))) return .none;
        if (depth < 5) if (r.ty.structFields(ty)) |fields| {
            const parts = try r.arena.alloc(Val, fields.len);
            for (parts, fields) |*part, f| part.* = try r.inStorage(f.ty, ids, depth + 1);
            return Val.aggregate(r.arena, parts);
        };
        const at = r.ty.payload(ty);
        return if (r.ty.isStorage(ty) or r.ty.kind(at) == .@"struct" or r.ty.kind(at) == .array) .{ .ids = ids } else .none;
    }

    /// A value of struct type `ty` whose allocator fields hold `given` and whose other fields hold `held`; null when the
    /// fields of the type are not known.
    pub fn byField(r: *Run, ty: schema.TypeId, given: Set, held: Set, depth: u32) Allocator.Error!?Val {
        if (depth >= 5) return null;
        if (r.ty.isAllocator(r.ty.payload(ty))) return .{ .ids = given };
        const fields = r.ty.structFields(ty) orelse return null;
        const parts = try r.arena.alloc(Val, fields.len);
        for (parts, fields) |*part, f| part.* = (try r.byField(f.ty, given, held, depth + 1)) orelse if (r.ty.hasPointers(f.ty)) Val{ .ids = held } else Val.none;
        return try Val.aggregate(r.arena, parts);
    }

    pub fn escapes(r: *Run, st: *State, inst: *const Inst, val: Val, into_local: bool, how: []const u8) Error!void {
        return r.escapesInto(st, inst, val, into_local, how, null);
    }

    /// A pointer to a stack slot must not end up where the function's caller can reach it. With a `container` place
    /// the escape is only pending: removing the entry again clears it.
    pub fn escapesInto(r: *Run, st: *State, inst: *const Inst, val: Val, into_local: bool, how: []const u8, container: ?PlaceId) Error!void {
        if (into_local) return;
        for (val.ids.ids) |o| {
            const rec = r.identRec(o);
            if (rec.kind != .local) continue;
            if (container != null) {
                const gop = try st.pending.getOrPut(r.arena, o);
                if (!gop.found_existing) gop.value_ptr.* = .{ .loc = inst.loc, .ident = o, .site = inst.id };
                continue;
            }
            const slot = r.names.get(rec.a) orelse "a local";
            try r.report(st, .escape_local, inst.loc, &.{}, "a pointer to `{s}` is {s}", .{ slot, how });
        }
    }

    pub fn placeName(r: *Run, pl: PlaceId) []const u8 {
        const rec = r.places.rec(pl);
        if (rec.parent == dom.no_place) return switch (rec.kind) {
            .cell => r.names.get(rec.n) orelse "a local",
            .param => r.paramName(rec.n),
            .heap => "an allocation",
            .other => "memory",
        };
        const base = r.placeName(rec.parent);
        if (rec.step == dom.elem_step) return std.fmt.allocPrint(r.arena, "{s}[]", .{base}) catch base;
        if (r.field_names.get(pl)) |f| return std.fmt.allocPrint(r.arena, "{s}.{s}", .{ base, f }) catch base;
        return std.fmt.allocPrint(r.arena, "{s}.{d}", .{ base, rec.step }) catch base;
    }

    fn paramName(r: *Run, i: u32) []const u8 {
        if (r.prog.param_names) |pn| if (pn.lookup(pn.context, .{ .pack = r.pack, .func = r.func }, i)) |n| return n;
        return std.fmt.allocPrint(r.arena, "parameter {d}", .{i}) catch "a parameter";
    }

    // Room.

    pub fn dropCapsAt(r: *Run, st: *State, pl: PlaceId) Allocator.Error!void {
        var k: usize = 0;
        while (k < st.caps.count()) {
            if (r.places.overlaps(st.caps.keys()[k], pl)) st.caps.swapRemoveAt(k) else k += 1;
        }
    }

    // Ending identities.

    /// Ends `id`; one that stands for several allocations stays, and the end is counted.
    pub fn end(r: *Run, st: *State, inst: *const Inst, id: dom.Id, event: Event) Allocator.Error!void {
        try r.tally("ends", inst);
        if (st.multi.has(id) and !event.exact) try r.tally("summarized", inst);
        try r.kill(st, id, event);
    }

    /// The allocations that came from the objects `objs` end with them.
    pub fn endRegion(r: *Run, st: *State, inst: *const Inst, objs: Set, event: Event) Allocator.Error!void {
        var it = r.region_of.iterator();
        while (it.next()) |e| if (e.value_ptr.meets(objs)) try r.end(st, inst, e.key_ptr.*, event);
    }

    /// The payload exists: what the call that made it moved is gone.
    fn present(r: *Run, st: *State, p: Pred) Error!void {
        var subject = p.subject;
        if (p.ptr) subject = if (subject.place) |pl| try r.readVal(st, pl, p.ty) else .none;
        try r.applyMoved(st, subject);
    }

    pub fn applyMoved(r: *Run, st: *State, val: Val) Error!void {
        for (val.moved.ids) |o| {
            const event = r.moved_events.get(o) orelse continue;
            try r.kill(st, o, event);
        }
    }

    /// On this path the optional or error union of `p` holds no payload, so its tokens and pointers do not exist.
    fn absent(r: *Run, st: *State, p: Pred) Error!void {
        var subject = p.subject;
        var at: ?PlaceId = subject.from;
        if (p.ptr) {
            at = subject.place;
            subject = if (subject.place) |pl| try r.readVal(st, pl, p.ty) else .none;
        }
        st.live = try st.live.minus(r.arena, subject.toks);
        if (at) |pl| if (r.strongAt(pl)) try r.writeVal(st, pl, .none, p.ty);
    }

    // The summary.

    /// What the function does, from what each of its `ret` instructions showed.
    fn merge(r: *Run, arena: Allocator) Allocator.Error!Summary {
        var out: Summary = .{};
        const snaps = r.snaps.values();
        if (snaps.len == 0) return out;
        var kills: std.ArrayList(Slot) = .empty;
        var writes: std.ArrayList(Write) = .empty;
        var counts: std.ArrayList(usize) = .empty;
        var goes_counts: std.ArrayList(usize) = .empty;
        var leaves: std.ArrayList(Leaf) = .empty;
        var frees: u64 = ~@as(u64, 0);
        var moves: u64 = ~@as(u64, 0);
        var place: ?Slot = null;
        var place_ok = true;
        for (snaps, 0..) |s, n| {
            frees &= s.frees;
            moves &= s.moves;
            for (s.kills) |k| {
                var have = false;
                for (kills.items) |x| if (x.eql(k)) {
                    have = true;
                };
                if (!have) try kills.append(arena, try dupeSlot(arena, k));
            }
            for (s.ret) |l| {
                var at: ?usize = null;
                for (leaves.items, 0..) |x, i| if (std.mem.eql(u32, x.path, l.path)) {
                    at = i;
                };
                if (at) |i| {
                    leaves.items[i].descs = try mergeDescs(arena, leaves.items[i].descs, l.descs);
                } else try leaves.append(arena, .{ .path = try arena.dupe(u32, l.path), .descs = try dupeDescs(arena, l.descs) });
            }
            if (n == 0) {
                place = s.ret_place;
            } else if ((place == null) != (s.ret_place == null) or (place != null and !place.?.eql(s.ret_place.?))) place_ok = false;
            for (s.writes) |w| {
                var at: ?usize = null;
                for (writes.items, 0..) |x, i| if (x.into.eql(w.into)) {
                    at = i;
                };
                const goes: usize = @intFromBool(!s.failed);
                if (at) |i| {
                    writes.items[i].descs = try mergeDescs(arena, writes.items[i].descs, w.descs);
                    counts.items[i] += 1;
                    goes_counts.items[i] += goes;
                } else {
                    try writes.append(arena, .{ .into = try dupeSlot(arena, w.into), .descs = try dupeDescs(arena, w.descs), .must = false });
                    try counts.append(arena, 1);
                    try goes_counts.append(arena, goes);
                }
            }
        }
        // What a function does on every path that goes on (the failing ones hand back an error, and the caller's `try`
        // does not follow them) is what it does, except for the blocks it makes: the failing paths leave the old one.
        var going: usize = 0;
        for (snaps) |s| going += @intFromBool(!s.failed);
        for (writes.items, counts.items, goes_counts.items) |*w, c, g| {
            var makes = false;
            for (w.descs) |d| makes = makes or d.src == .fresh;
            w.must = if (makes or going == 0) c == snaps.len else g == going;
        }
        out.kills = kills.items;
        out.writes = writes.items;
        out.ret = leaves.items;
        canonicalOrder(&out);
        // A result that may be any of a great many allocations is one that stands for them all.
        const many = try arena.alloc(bool, r.fresh_ids.items.len);
        @memset(many, false);
        for (leaves.items) |*l| l.descs = capFresh(arena, l.descs, many);
        for (writes.items) |*w| w.descs = capFresh(arena, w.descs, many);
        // Only the allocations that flow out, numbered by where they first appear.
        const used = try arena.alloc(u32, r.fresh_ids.items.len);
        @memset(used, std.math.maxInt(u32));
        var count: u32 = 0;
        for (out.ret) |l| {
            for (l.descs) |*d| count = renumber(d, used, count);
        }
        for (out.writes) |w| {
            for (w.descs) |*d| count = renumber(d, used, count);
        }
        const fresh_list = try arena.alloc(Fresh, count);
        for (used, r.fresh_ids.items, many) |new, id, is_many| {
            if (new == std.math.maxInt(u32)) continue;
            var regions: std.ArrayList(Slot) = .empty;
            if (r.region_of.get(id)) |objs| for (objs.ids) |o| if (try r.slotOf(o)) |sl| try regions.append(arena, try dupeSlot(arena, sl));
            fresh_list[new] = .{ .regions = regions.items, .many = is_many };
        }
        for (out.ret) |l| std.mem.sort(Desc, @constCast(l.descs), {}, lessDesc);
        for (out.writes) |w| std.mem.sort(Desc, @constCast(w.descs), {}, lessDesc);
        out.frees = frees;
        out.moves = moves;
        const derefs = try arena.alloc(Slot, r.derefs.items.len);
        for (derefs, r.derefs.items) |*d, x| d.* = try dupeSlot(arena, x);
        std.mem.sort(Slot, derefs, {}, lessSlot);
        out.derefs = derefs;
        out.ret_place = if (place_ok) if (place) |p| try dupeSlot(arena, p) else null else null;
        out.fresh = fresh_list;
        // Two pointer parameters of one type are taken not to overlap; say so when something is done through them.
        if (kills.items.len + writes.items.len != 0) {
            const params = r.pack.t.params[r.func.params.off..][0..r.func.params.len];
            for (params, 0..) |a, i| {
                const pa = r.ty.pointee(a.ty) orelse continue;
                if (r.ty.rec(a.ty).flags.is_const) continue;
                for (params[i + 1 ..]) |b| {
                    const pb = r.ty.pointee(b.ty) orelse continue;
                    if (!r.ty.rec(b.ty).flags.is_const and r.ty.kind(pa) == .@"struct" and std.mem.eql(u8, r.ty.name(pa), r.ty.name(pb))) {
                        r.stats.alias_params = 1;
                    }
                }
            }
        }
        return out;
    }

    /// The kills, writes and results of a summary in one order, so that two runs that found the same thing compare equal.
    fn canonicalOrder(out: *Summary) void {
        std.mem.sort(Slot, @constCast(out.kills), {}, lessSlot);
        std.mem.sort(Write, @constCast(out.writes), {}, lessWrite);
        std.mem.sort(Leaf, @constCast(out.ret), {}, lessLeaf);
        for (out.ret) |l| std.mem.sort(Desc, @constCast(l.descs), {}, lessDesc);
        for (out.writes) |w| std.mem.sort(Desc, @constCast(w.descs), {}, lessDesc);
    }

    fn capFresh(arena: Allocator, descs: []const Desc, many: []bool) []const Desc {
        var n: usize = 0;
        for (descs) |d| n += @intFromBool(d.src == .fresh);
        if (n <= 12) return descs;
        var out: std.ArrayList(Desc) = .empty;
        var kept = false;
        for (descs) |d| {
            if (d.src != .fresh) {
                out.append(arena, d) catch return descs;
            } else if (!kept) {
                kept = true;
                many[d.src.fresh] = true;
                out.append(arena, d) catch return descs;
            }
        }
        return out.items;
    }

    /// Gives the fresh allocation of `d` the next number if it has none; returns the count so far.
    fn renumber(d: *const Desc, used: []u32, count: u32) u32 {
        if (d.src != .fresh) return count;
        const k = d.src.fresh;
        if (used[k] != std.math.maxInt(u32)) {
            @constCast(d).src = .{ .fresh = used[k] };
            return count;
        }
        used[k] = count;
        @constCast(d).src = .{ .fresh = count };
        return count + 1;
    }

    fn lessSlot(_: void, a: Slot, b: Slot) bool {
        if (a.param != b.param) return a.param < b.param;
        if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
        return std.mem.order(u32, a.path, b.path) == .lt;
    }

    fn lessWrite(_: void, a: Write, b: Write) bool {
        return lessSlot({}, a.into, b.into);
    }

    fn lessLeaf(_: void, a: Leaf, b: Leaf) bool {
        return std.mem.order(u32, a.path, b.path) == .lt;
    }

    fn lessDesc(_: void, a: Desc, b: Desc) bool {
        if (a.obj != b.obj) return !a.obj;
        const ta = @intFromEnum(std.meta.activeTag(a.src));
        const tb = @intFromEnum(std.meta.activeTag(b.src));
        if (ta != tb) return ta < tb;
        return switch (a.src) {
            .from => |x| lessSlot({}, x, b.src.from),
            .fresh => |x| x < b.src.fresh,
            .gone => false,
        };
    }

    fn dupeSlot(arena: Allocator, s: Slot) Allocator.Error!Slot {
        return .{ .param = s.param, .path = try arena.dupe(u32, s.path), .kind = s.kind };
    }

    fn dupeDescs(arena: Allocator, ds: []const Desc) Allocator.Error![]const Desc {
        const out = try arena.alloc(Desc, ds.len);
        for (out, ds) |*o, d| o.* = .{ .src = switch (d.src) {
            .from => |s| .{ .from = try dupeSlot(arena, s) },
            .fresh => |k| .{ .fresh = k },
            .gone => .gone,
        }, .obj = d.obj };
        return out;
    }

    fn mergeDescs(arena: Allocator, a: []const Desc, b: []const Desc) Allocator.Error![]const Desc {
        var out: std.ArrayList(Desc) = .empty;
        try out.appendSlice(arena, a);
        for (b) |d| {
            var have = false;
            for (a) |x| if (x.eql(d)) {
                have = true;
            };
            if (!have) try out.append(arena, (try dupeDescs(arena, &.{d}))[0]);
        }
        return out.items;
    }

    fn leavesOf(r: *Run, out: *std.ArrayList(Leaf), v: Val, path: []const u32, depth: u32) Allocator.Error!void {
        if (v.parts) |parts| if (depth < 6) {
            for (parts, 0..) |p, k| {
                const sub = try r.arena.alloc(u32, path.len + 1);
                @memcpy(sub[0..path.len], path);
                sub[path.len] = @intCast(k);
                try r.leavesOf(out, p, sub, depth + 1);
            }
            if (!v.obj.isEmpty()) {
                const sub = try r.arena.alloc(u32, path.len + 1);
                @memcpy(sub[0..path.len], path);
                sub[path.len] = dom.obj_step;
                try out.append(r.arena, .{ .path = sub, .descs = try r.descsOf(.{ .obj = v.obj }) });
            }
            return;
        };
        const descs = try r.descsOf(v);
        if (descs.len != 0 or path.len == 0) try out.append(r.arena, .{ .path = path, .descs = descs });
    }

    /// Memory that holds nothing but the end of what the caller put there: the kill says so, and the caller's own
    /// tombstone must not be written over.
    fn onlyOwnTombs(r: *Run, v: Val, key: PlaceId) bool {
        if (v.ids.isEmpty() or !v.toks.isEmpty()) return false;
        for (v.ids.ids) |id| {
            const rec = r.identRec(id);
            if (rec.kind != .tomb) return false;
            const of = r.identRec(rec.a);
            const own = if (r.places.rec(key).step == dom.obj_step) of.kind == .object and of.a == r.places.rec(key).parent else of.kind == .init and of.a == key;
            if (!own) return false;
        }
        return true;
    }

    /// Records what this `ret` shows of the function: what it ended, what the memory below its parameters holds, and
    /// where the result comes from.
    fn snapshot(r: *Run, inst: *const Inst, st: *State, val: Val) Allocator.Error!void {
        var kills: std.ArrayList(Slot) = .empty;
        var it = st.dead.iterator();
        while (it.next()) |e| {
            // The caller's names for blocks that stand for several are not the callee's to end.
            if (e.value_ptr.soft or (e.value_ptr.exact and st.multi.has(e.key_ptr.*))) continue;
            const id = e.key_ptr.*;
            const rec = r.identRec(id);
            // The parameter's own value is a free when it is one on every path (below).
            if (rec.kind == .init and rec.b == 0 and r.places.rec(rec.a).parent == dom.no_place) continue;
            if (try r.slotOf(id)) |s| try kills.append(r.arena, s);
        }
        var frees: u64 = 0;
        for (st.freed.ids) |id| {
            const rec = r.identRec(id);
            if (rec.kind == .init and rec.b == 0) {
                const n = r.places.rec(rec.a).n;
                if (n < 64) frees |= @as(u64, 1) << @intCast(n);
            }
        }
        var moves: u64 = 0;
                for (val.moved.ids) |id| {
            const rec = r.identRec(id);
            if (rec.kind == .init and rec.b == 0 and r.places.rec(rec.a).parent == dom.no_place) {
                const n = r.places.rec(rec.a).n;
                if (n < 64) moves |= @as(u64, 1) << @intCast(n);
            }
        }
        var leaves: std.ArrayList(Leaf) = .empty;
        try r.leavesOf(&leaves, val, &.{}, 0);
        const ret_place: ?Slot = if (val.place) |pl| try r.slotOfPlace(pl, .content) else null;
        var writes: std.ArrayList(SnapWrite) = .empty;
        for (st.mem.keys(), st.mem.values()) |key, v| {
            if (r.paramOf(key) == null) continue;
            const rec = r.places.rec(key);
            if (onlyOwnTombs(r, v, key)) continue;
            if (rec.step == dom.obj_step) {
                const into = (try r.slotOfPlace(rec.parent, .object)) orelse continue;
                const descs = try r.descsOf(.{ .obj = v.ids });
                if (descs.len == 1 and descs[0].src == .from and descs[0].src.from.eql(into)) continue;
                try writes.append(r.arena, .{ .into = into, .descs = descs });
                continue;
            }
            // Nothing in this run touched it: what the caller put there is still there.
            if (v.ids.ids.len == 1 and v.ids.ids[0] == try r.ident(.init, key, 1) and v.toks.isEmpty() and v.parts == null) continue;
            const into = (try r.slotOfPlace(key, .content)) orelse continue;
            try writes.append(r.arena, .{ .into = into, .descs = try r.descsOf(v) });
        }
        for (r.elem_stores.keys(), r.elem_stores.values()) |key, v| {
            const into = (try r.slotOfPlace(key, .content)) orelse continue;
            try writes.append(r.arena, .{ .into = into, .descs = try r.descsOf(v) });
        }
        try r.snaps.put(r.arena, inst.id, .{ .kills = kills.items, .frees = frees, .moves = moves, .ret = leaves.items, .ret_place = ret_place, .writes = writes.items, .failed = r.returnsError(inst) });
    }

    fn ret(r: *Run, inst: *const Inst, st: *State, val: Val) Error!void {
        try r.use(st, inst, val, "returned");
        for (val.ids.ids) |o| {
            const rec = r.identRec(o);
            if (rec.kind == .local) {
                const slot = r.names.get(rec.a) orelse "a local";
                try r.report(st, .escape_local, inst.loc, &.{}, "a pointer to `{s}` is returned, but `{s}` ends with the function", .{ slot, slot });
            }
        }
        for (st.pending.values()) |p| {
            const slot = r.names.get(r.identRec(p.ident).a) orelse "a local";
            const where: diag.Note = .{ .loc = inst.loc, .text = "it is still there when the function returns here" };
            try r.report(st, .escape_local, p.loc, try r.noteList(&.{where}), "a pointer to `{s}` is stored into a container that outlives it", .{slot});
        }
        try r.snapshot(inst, st, val);
        // Handing the value to the caller ends the function's ownership of its tokens.
        st.live = try st.live.minus(r.arena, val.toks);
        for (st.live.ids) |t| {
            const made = try r.created(t);
            try r.report(st, .leak, inst.loc, try r.noteList(&.{made}), "linear value `{s}` is not consumed on this path", .{r.tokenName(t)});
        }
        st.alive = false;
    }

    /// Whether this `ret` hands back an error (`return error.X`, the failing branch of a `try`).
    fn returnsError(r: *Run, inst: *const Inst) bool {
        const ops = r.v.ops(inst);
        if (ops.len == 0) return false;
        return switch (ops[0].kind) {
            .inst => if (r.by_id[ops[0].value]) |def| def.tag == .wrap_errunion_err else false,
            .constant => r.v.constant(ops[0]).kind == .@"error",
            .none => false,
        };
    }

    fn call(r: *Run, inst: *const Inst, st: *State) Error!void {
        return calls.call(r, inst, st);
    }

    pub fn callName(r: *Run, inst: *const Inst) []const u8 {
        return r.v.attrStr(inst, .callee) orelse "a call";
    }

    pub fn freshTokens(r: *Run, st: *State, inst: *const Inst, sub: *u32) Error!Val {
        return r.fresh(st, inst, inst.ty, sub);
    }

    pub fn noteTokensOf(r: *Run, a: Val) void {
        for (a.toks.ids) |t| if (r.param_of_tok.get(t)) |pi| if (pi < 64) {
            r.token_stored |= @as(u64, 1) << @intCast(pi);
        };
    }

    // Control flow.

    fn exec(r: *Run, list: []const Inst, st: *State) Error!void {
        for (list) |*inst| {
            if (!st.alive) return;
            try r.step(inst, st);
        }
    }

    fn step(r: *Run, inst: *const Inst, st: *State) Error!void {
        const outer = r.cur;
        r.cur = st;
        defer r.cur = outer;
        r.stats.insts += 1;
        if (inst.loc != .none) r.cur_loc = inst.loc;
        if (inst.ty == .none) return r.unsupported(inst, "instruction {t} is not decoded by the exporter", .{inst.tag});
        switch (inst.tag) {
            .dbg_stmt, .dbg_empty_stmt, .save_err_return_trace_index, .set_err_return_trace => {},
            .dbg_var_val, .dbg_var_ptr => {
                const o = r.v.ops(inst)[0];
                if (o.kind == .inst) if (r.v.attrStr(inst, .name)) |n| {
                    const gop = try r.names.getOrPut(r.arena, o.value);
                    if (!gop.found_existing) gop.value_ptr.* = n;
                    for (r.vals[o.value].toks.ids) |t| {
                        const named = try r.tok_names.getOrPut(r.arena, t);
                        if (!named.found_existing) named.value_ptr.* = n;
                    }
                };
            },
            .dbg_arg_inline => {
                const o = r.v.ops(inst)[0];
                r.set(inst, r.operand(o));
                if (o.kind == .inst) if (r.v.attrStr(inst, .name)) |n| {
                    const gop = try r.names.getOrPut(r.arena, o.value);
                    if (!gop.found_existing) gop.value_ptr.* = n;
                };
            },

            .arg => try r.stepArg(inst, st),
            .alloc, .ret_ptr => {
                const cell = try r.places.root(r.arena, .cell, inst.id);
                _ = st.mem.swapRemove(cell);
                var i: usize = 0;
                while (i < st.mem.count()) {
                    if (r.places.contains(cell, st.mem.keys()[i])) st.mem.swapRemoveAt(i) else i += 1;
                }
                const local = try r.ident(.local, inst.id, 0);
                r.set(inst, .{ .place = cell, .ids = try Set.single(r.arena, local), .off = 0 });
            },
            .store, .store_safe => {
                const dst = r.arg(inst, 0);
                const stored = r.v.ops(inst)[1];
                const undef = stored.kind == .constant and r.v.constant(stored).kind == .undef;
                try r.store(inst, st, dst, r.arg(inst, 1), r.operandType(stored), undef);
                // A container made of a constant (`.empty`) holds nothing and has no room.
                if (dst.place) |pl| {
                    if (r.v.ops(inst)[1].kind == .constant and r.isContainer(r.operandType(r.v.ops(inst)[1])))
                        try st.caps.put(r.arena, pl, .{ .cap_lb = 0, .len_ub = 0 })
                    else if (r.arg(inst, 1).room) |n| try st.caps.put(r.arena, pl, .{ .cap_lb = n, .len_ub = 0 });
                }
            },
            .load => {
                const p = r.arg(inst, 0);
                try r.alive(st, inst, p, "read");
                r.set(inst, try r.load(st, inst, p, inst.ty));
            },

            .ptr_slice_len_ptr => {
                var v = r.arg(inst, 0);
                if (v.place) |pl| v.place = try r.places.child(r.arena, pl, dom.len_step);
                r.set(inst, v);
            },
            .ptr_cast, .bit_cast, .bit_cast_safe, .addrspace_cast, .slice_ptr, .array_to_slice, .slice, .ptr_slice_ptr_ptr => {
                if (r.ty.hasPointers(inst.ty) or r.ty.hasTokens(inst.ty)) {
                    var v = r.arg(inst, 0);
                    // An offset counts elements: a cast to another element type changes the unit.
                    if (r.elemType(r.operandType(r.v.ops(inst)[0])) != r.elemType(inst.ty)) v.off = null;
                    r.set(inst, v);
                } else r.set(inst, .none);
            },
            .ptr_from_int => {
                // A pointer made of a constant (an undefined or comptime-known address) leads nowhere; one made of a
                // computed integer has lost where it came from.
                if (r.v.ops(inst)[0].kind != .constant) return r.unsupported(inst, "a pointer made from an integer", .{});
                r.set(inst, .none);
            },
            .ptr_add, .ptr_sub => {
                var p = r.arg(inst, 0);
                const by = r.v.ops(inst)[1];
                p.off = if (p.off != null and by.kind == .constant and r.v.constant(by).kind == .int) blk: {
                    const n: i64 = @bitCast(r.v.constant(by).a);
                    break :blk if (inst.tag == .ptr_add) p.off.? +% n else p.off.? -% n;
                } else null;
                r.set(inst, p);
            },
            .slice_elem_ptr, .ptr_elem_ptr => {
                var p = r.arg(inst, 0);
                p.off = null;
                const elem = r.elemStep(r.v.ops(inst)[1]);
                p.many = elem == dom.elem_step;
                if (p.place) |pl| {
                    p.ids = try p.ids.with(r.arena, try r.ident(.init, pl, 2));
                    p.place = try r.places.child(r.arena, pl, elem);
                }
                r.set(inst, p);
            },
            .struct_field_ptr, .struct_field_ptr_index_0, .struct_field_ptr_index_1, .struct_field_ptr_index_2, .struct_field_ptr_index_3 => {
                const field: u32 = switch (inst.tag) {
                    .struct_field_ptr => r.v.attr(inst, .field) orelse return r.unsupported(inst, "struct_field_ptr without a field", .{}),
                    .struct_field_ptr_index_0 => 0,
                    .struct_field_ptr_index_1 => 1,
                    .struct_field_ptr_index_2 => 2,
                    else => 3,
                };
                var p = r.arg(inst, 0);
                if (p.place) |pl| {
                    p.place = r.up_of.get(pl) orelse try r.places.child(r.arena, pl, field);
                    if (r.up_of.contains(pl)) return r.set(inst, p);
                    if (r.ty.pointee(r.operandType(r.v.ops(inst)[0]))) |container| {
                        var buf: [32]u8 = undefined;
                        const name = r.ty.fieldName(&buf, container, field);
                        const gop = try r.field_names.getOrPut(r.arena, p.place.?);
                        if (!gop.found_existing) gop.value_ptr.* = try r.arena.dupe(u8, name);
                    }
                }
                r.set(inst, p);
            },
            .agg_field_val => {
                const base = r.arg(inst, 0);
                r.set(inst, base.field(r.v.attr(inst, .field) orelse return r.unsupported(inst, "agg_field_val without a field", .{})));
            },
            .aggregate_init => {
                const rec = r.ty.rec(inst.ty);
                const ops = r.v.ops(inst);
                if (rec.kind == .array or rec.kind == .vector) {
                    var all: Val = .none;
                    for (ops) |o| all = try all.join(r.arena, r.operand(o).flat());
                    if (!all.toks.isEmpty()) return r.unsupported(inst, "an array ({s}) of linear values", .{r.ty.name(inst.ty)});
                    r.set(inst, all);
                } else {
                    const parts = try r.arena.alloc(Val, ops.len);
                    for (parts, ops) |*part, o| part.* = r.operand(o);
                    r.set(inst, try Val.aggregate(r.arena, parts));
                }
            },
            .union_init => {
                const v = r.arg(inst, 0);
                if (!v.toks.isEmpty()) return r.unsupported(inst, "a union ({s}) holds a linear value", .{r.ty.name(inst.ty)});
                r.set(inst, v);
            },
            .array_elem_val, .slice_elem_val, .ptr_elem_val => {
                const base = r.arg(inst, 0);
                try r.alive(st, inst, base, "read");
                if (inst.tag == .array_elem_val) {
                    var v = base.flat();
                    v.place = null;
                    v.many = true;
                    r.set(inst, v);
                } else {
                    var p = base;
                    if (p.place) |pl| p.place = try r.places.child(r.arena, pl, r.elemStep(r.v.ops(inst)[1]));
                    r.set(inst, try r.load(st, inst, p, inst.ty));
                }
            },
            .wrap_optional, .optional_payload, .wrap_errunion_payload, .error_cast, .unwrap_errunion_payload, .optional_payload_ptr, .optional_payload_ptr_set, .unwrap_errunion_payload_ptr, .errunion_payload_ptr_set => {
                r.set(inst, r.arg(inst, 0));
            },
            .wrap_errunion_err, .unwrap_errunion_err => r.set(inst, .none),

            .is_null, .is_non_null, .is_err, .is_non_err, .is_null_ptr, .is_non_null_ptr, .is_err_ptr, .is_non_err_ptr => {
                const present_if_true = switch (inst.tag) {
                    .is_non_null, .is_non_err, .is_non_null_ptr, .is_non_err_ptr => true,
                    else => false,
                };
                const ptr = switch (inst.tag) {
                    .is_null_ptr, .is_non_null_ptr, .is_err_ptr, .is_non_err_ptr => true,
                    else => false,
                };
                if (ptr) try r.alive(st, inst, r.arg(inst, 0), "read");
                const subject_ty = r.operandType(r.v.ops(inst)[0]);
                try r.preds.put(r.arena, inst.id, .{ .subject = r.arg(inst, 0), .ptr = ptr, .present_if_true = present_if_true, .ty = if (ptr) r.pointeeOf(subject_ty) else subject_ty });
                r.set(inst, .none);
            },
            .not => {
                const o = r.v.ops(inst)[0];
                if (o.kind == .inst) if (r.preds.get(o.value)) |p| {
                    var negated = p;
                    negated.present_if_true = !p.present_if_true;
                    try r.preds.put(r.arena, inst.id, negated);
                };
                r.set(inst, .none);
            },

            .block, .dbg_inline_block => try r.block(inst, st),
            .loop => try r.loop(inst, st),
            .br => {
                const target = r.v.attr(inst, .target) orelse return r.unsupported(inst, "br without a target", .{});
                const ctx = r.blocks.get(target) orelse return r.unsupported(inst, "br to a block that is not open", .{});
                const val = if (r.v.ops(inst).len != 0) r.arg(inst, 0) else Val.none;
                try ctx.incoming.append(r.arena, .{ .state = st.*, .val = val });
                st.alive = false;
            },
            .repeat => {
                const target = r.v.attr(inst, .target) orelse return r.unsupported(inst, "repeat without a target", .{});
                const ctx = r.loops.get(target) orelse return r.unsupported(inst, "repeat outside its loop", .{});
                try ctx.back.append(r.arena, st.*);
                st.alive = false;
            },
            .cond_br => try r.condBr(inst, st),
            .switch_br => try r.switchBr(inst, st),
            .@"try", .try_cold, .try_ptr, .try_ptr_cold => try r.tryOp(inst, st),
            .ret, .ret_safe => try r.ret(inst, st, r.arg(inst, 0)),
            .ret_load => {
                const p = r.arg(inst, 0);
                try r.ret(inst, st, try r.load(st, inst, p, r.pointeeOf(r.operandType(r.v.ops(inst)[0]))));
            },
            .unreach, .trap => st.alive = false,
            .call, .call_always_tail, .call_never_tail, .call_never_inline => try r.call(inst, st),

            .memcpy, .memmove => {
                const dst = r.arg(inst, 0);
                const src = r.arg(inst, 1);
                if (inst.tag == .memcpy) try r.checkDisjoint(st, inst, dst, src);
                try r.alive(st, inst, dst, "write");
                try r.alive(st, inst, src, "read");
                var content: Val = if (src.place) |pl| (try r.readVal(st, pl, r.pointeeOf(r.operandType(r.v.ops(inst)[1])))).flat() else .none;
                if (!content.toks.isEmpty()) return r.unsupported(inst, "a copy of linear values", .{});
                content.place = null;
                content.obj = .empty;
                try r.store(inst, st, dst, content, .none, false);
            },
            .memset, .memset_safe => {
                try r.alive(st, inst, r.arg(inst, 0), "write");
            },
            .atomic_store_unordered, .atomic_store_monotonic, .atomic_store_release, .atomic_store_seq_cst => {
                const stored = r.v.ops(inst)[1];
                try r.store(inst, st, r.arg(inst, 0), r.arg(inst, 1), r.operandType(stored), false);
            },
            .atomic_load => {
                const p = r.arg(inst, 0);
                try r.alive(st, inst, p, "read");
                r.set(inst, try r.load(st, inst, p, inst.ty));
            },
            .atomic_rmw, .cmpxchg_weak, .cmpxchg_strong => {
                try r.alive(st, inst, r.arg(inst, 0), "read and written");
                if (r.ty.hasPointers(inst.ty)) return r.unsupported(inst, "an atomic update of a pointer", .{});
                r.set(inst, .none);
            },
            .tag_name, .error_name => r.set(inst, .none),
            .set_union_tag => try r.alive(st, inst, r.arg(inst, 0), "written"),
            .err_return_trace => r.set(inst, .none),

            .field_parent_ptr => {
                // The parent is one level up from the field: the place when the pointer names a field, else only
                // the identities (an operation on it is applied to everything those own).
                var p = r.arg(inst, 0);
                p.off = null;
                p.many = false;
                if (p.place) |pl| {
                    const up = r.places.rec(pl);
                    if (up.parent != dom.no_place and up.step != dom.elem_step and up.step != dom.obj_step) {
                        p.place = up.parent;
                    } else {
                        // A parent nobody named: the field pointer it came from is what `&parent.field` leads back to.
                        const parent = try r.places.root(r.arena, .other, pl);
                        try r.up_of.put(r.arena, parent, pl);
                        p.place = parent;
                    }
                }
                r.set(inst, p);
            },
            .assembly => return r.unsupported(inst, "inline assembly", .{}),
            .loop_switch_br => try r.loopSwitch(inst, st),
            .switch_dispatch => {
                const target = r.v.attr(inst, .target) orelse return r.unsupported(inst, "switch_dispatch without a target", .{});
                const ctx = r.loops.get(target) orelse return r.unsupported(inst, "switch_dispatch outside its switch loop", .{});
                try ctx.back.append(r.arena, st.*);
                st.alive = false;
            },

            .prefetch, .unwrap_errunion_err_ptr => {
                try r.alive(st, inst, r.arg(inst, 0), "read");
                r.set(inst, .none);
            },
            else => {
                switch (r.ty.kind(inst.ty)) {
                    .int, .bool, .float, .void, .noreturn, .@"enum", .error_set, .comptime_int, .comptime_float, .undefined, .null, .type, .enum_literal, .vector => {
                        // A pointer operand of an instruction nothing above models may be read or written through.
                        if (!r.addressOnly(inst.tag)) for (r.v.ops(inst)) |o| {
                            if (r.ty.isPointer(r.operandType(o))) return r.unsupported(inst, "instruction {t} takes a pointer", .{inst.tag});
                        };
                        r.set(inst, .none);
                    },
                    else => return r.unsupported(inst, "instruction {t} of type {s}", .{ inst.tag, r.ty.name(inst.ty) }),
                }
            },
        }
    }

    /// Instructions that take a pointer or a slice and look at the address or the length only.
    fn addressOnly(r: *Run, tag: schema.Tag) bool {
        _ = r;
        return switch (tag) {
            .int_from_ptr, .slice_len, .cmp_eq, .cmp_neq, .cmp_lt, .cmp_lte, .cmp_gt, .cmp_gte, .cmp_eq_optimized, .cmp_neq_optimized, .cmp_lt_optimized, .cmp_lte_optimized, .cmp_gt_optimized, .cmp_gte_optimized => true,
            else => false,
        };
    }

    /// Whether a value of this type is one of std's containers (made of a constant it is empty).
    fn isContainer(r: *Run, ty: schema.TypeId) bool {
        var buf: [512]u8 = undefined;
        return r.ty.kind(ty) == .@"struct" and spec.family(spec.stripped(&buf, r.ty.name(ty))) != null;
    }

    fn block(r: *Run, inst: *const Inst, st: *State) Error!void {
        const bodies = r.v.bodies(inst);
        if (bodies.len != 1) return r.unsupported(inst, "a block with {d} bodies", .{bodies.len});
        const ctx = try r.arena.create(BlockCtx);
        ctx.* = .{};
        try r.blocks.put(r.arena, inst.id, ctx);
        const entry = st.trail;
        try r.exec(r.v.insts(bodies[0]), st);
        if (st.alive) try ctx.incoming.append(r.arena, .{ .state = st.*, .val = .none });
        var out: ?State = null;
        var val: Val = .none;
        for (ctx.incoming.items) |inc| {
            out = if (out) |o| try o.join(r.arena, inc.state, entry) else inc.state;
            val = try val.join(r.arena, inc.val);
        }
        _ = r.blocks.remove(inst.id);
        if (out) |o| {
            st.* = o;
            r.set(inst, val);
        } else st.alive = false;
    }

    fn loop(r: *Run, inst: *const Inst, st: *State) Error!void {
        const bodies = r.v.bodies(inst);
        if (bodies.len != 1) return r.unsupported(inst, "a loop with {d} bodies", .{bodies.len});
        const ctx = try r.arena.create(LoopCtx);
        ctx.* = .{};
        try r.loops.put(r.arena, inst.id, ctx);
        const entry = try st.clone(r.arena);
        var head = try entry.clone(r.arena);
        var saved: std.ArrayList(struct { id: u32, len: usize }) = .empty;
        var it = r.blocks.iterator();
        while (it.next()) |e| try saved.append(r.arena, .{ .id = e.key_ptr.*, .len = e.value_ptr.*.incoming.items.len });

        r.quiet += 1;
        var rounds: u32 = 0;
        while (true) {
            rounds += 1;
            if (rounds > 16) {
                r.quiet -= 1;
                return r.unsupported(inst, "a loop whose facts do not settle", .{});
            }
            ctx.back.clearRetainingCapacity();
            for (saved.items) |s| r.blocks.get(s.id).?.incoming.shrinkRetainingCapacity(s.len);
            var run = try head.clone(r.arena);
            try r.exec(r.v.insts(bodies[0]), &run);
            var next = head;
            next = try next.join(r.arena, entry, entry.trail);
            for (ctx.back.items) |b| next = try next.join(r.arena, b, entry.trail);
            next.alive = true;
            if (next.eql(head)) break;
            head = next;
        }
        r.quiet -= 1;
        // The last round again, now with the settled facts and with findings on.
        ctx.back.clearRetainingCapacity();
        for (saved.items) |s| r.blocks.get(s.id).?.incoming.shrinkRetainingCapacity(s.len);
        var run = try head.clone(r.arena);
        try r.exec(r.v.insts(bodies[0]), &run);
        _ = r.loops.remove(inst.id);
        st.alive = false;
    }

    fn condBr(r: *Run, inst: *const Inst, st: *State) Error!void {
        r.pruneOver(st);
        const bodies = r.v.bodies(inst);
        if (bodies.len != 2) return r.unsupported(inst, "a branch with {d} bodies", .{bodies.len});
        const c = r.v.ops(inst)[0];
        var take_then = true;
        var take_else = true;
        if (c.kind == .constant) {
            const k = r.v.constant(c);
            if (k.kind == .bool) {
                take_then = k.a != 0;
                take_else = !take_then;
            }
        }
        const pred: ?Pred = if (c.kind == .inst) r.preds.get(c.value) else null;
        const decision = !(r.endsInUnreachable(bodies[0]) or r.endsInUnreachable(bodies[1]));
        // The failing side of a safety check never returns: nothing it does reaches the rest of the function.
        if (take_then and !r.endsInUnreachable(bodies[0])) {
            var s = try st.clone(r.arena);
            if (decision) s.trail = try r.push(st.trail, inst.loc, .then);
            if (pred) |p| if (p.present_if_true) try r.present(&s, p) else try r.absent(&s, p);
            try r.exec(r.v.insts(bodies[0]), &s);
        }
        if (take_else and !r.endsInUnreachable(bodies[1])) {
            var s = st.*;
            if (decision) s.trail = try r.push(st.trail, inst.loc, .@"else");
            if (pred) |p| if (p.present_if_true) try r.absent(&s, p) else try r.present(&s, p);
            try r.exec(r.v.insts(bodies[1]), &s);
        }
        st.alive = false;
    }

    /// A body that ends in `unreachable` is the failing side of a safety check.
    fn endsInUnreachable(r: *Run, body: schema.Body) bool {
        const list = r.v.insts(body);
        return list.len != 0 and list[list.len - 1].tag == .unreach;
    }

    fn switchBr(r: *Run, inst: *const Inst, st: *State) Error!void {
        for (r.v.bodies(inst)) |b| {
            var s = try st.clone(r.arena);
            s.trail = try r.push(st.trail, inst.loc, .case);
            try r.exec(r.v.insts(b), &s);
        }
        st.alive = false;
    }

    fn push(r: *Run, prev: ?*const Trail, loc: schema.LocId, what: @FieldType(Trail, "what")) Allocator.Error!*const Trail {
        const node = try r.arena.create(Trail);
        node.* = .{ .prev = prev, .loc = loc, .what = what };
        return node;
    }

    /// A labeled switch loop: every case runs from the state at the head, `continue :label` goes back to the head.
    fn loopSwitch(r: *Run, inst: *const Inst, st: *State) Error!void {
        const bodies = r.v.bodies(inst);
        const ctx = try r.arena.create(LoopCtx);
        ctx.* = .{};
        try r.loops.put(r.arena, inst.id, ctx);
        const entry = try st.clone(r.arena);
        var head = try entry.clone(r.arena);
        var saved: std.ArrayList(struct { id: u32, len: usize }) = .empty;
        var it = r.blocks.iterator();
        while (it.next()) |e| try saved.append(r.arena, .{ .id = e.key_ptr.*, .len = e.value_ptr.*.incoming.items.len });

        r.quiet += 1;
        var rounds: u32 = 0;
        while (true) {
            rounds += 1;
            if (rounds > 16) {
                r.quiet -= 1;
                return r.unsupported(inst, "a switch loop whose facts do not settle", .{});
            }
            ctx.back.clearRetainingCapacity();
            for (saved.items) |s| r.blocks.get(s.id).?.incoming.shrinkRetainingCapacity(s.len);
            for (bodies) |b| {
                var run = try head.clone(r.arena);
                run.trail = try r.push(head.trail, inst.loc, .case);
                try r.exec(r.v.insts(b), &run);
            }
            var next = head;
            next = try next.join(r.arena, entry, entry.trail);
            for (ctx.back.items) |b| next = try next.join(r.arena, b, entry.trail);
            next.alive = true;
            if (next.eql(head)) break;
            head = next;
        }
        r.quiet -= 1;
        ctx.back.clearRetainingCapacity();
        for (saved.items) |s| r.blocks.get(s.id).?.incoming.shrinkRetainingCapacity(s.len);
        for (bodies) |b| {
            var run = try head.clone(r.arena);
            run.trail = try r.push(head.trail, inst.loc, .case);
            try r.exec(r.v.insts(b), &run);
        }
        _ = r.loops.remove(inst.id);
        st.alive = false;
    }

    fn tryOp(r: *Run, inst: *const Inst, st: *State) Error!void {
        const bodies = r.v.bodies(inst);
        if (bodies.len != 1) return r.unsupported(inst, "a try with {d} bodies", .{bodies.len});
        const eu = r.arg(inst, 0);
        // A container operation that ran out of memory left the container as it was.
        const before = if (r.v.ops(inst)[0].kind == .inst) r.pre_state.get(r.v.ops(inst)[0].value) else null;
        var failed = if (before) |b| try b.clone(r.arena) else try st.clone(r.arena);
        failed.trail = try r.push(st.trail, inst.loc, .@"error");
        var subject = eu;
        if (inst.tag == .try_ptr or inst.tag == .try_ptr_cold) subject = if (eu.place) |pl| try r.readVal(st, pl, r.pointeeOf(r.operandType(r.v.ops(inst)[0]))) else .none;
        failed.live = try failed.live.minus(r.arena, subject.toks);
        // A call that failed did not do what it was asked to: nothing it stores is there.
        const operand_ref = r.v.ops(inst)[0];
        if (operand_ref.kind == .inst) {
            var k: usize = 0;
            while (k < failed.pending.count()) {
                if (failed.pending.values()[k].site == operand_ref.value) failed.pending.swapRemoveAt(k) else k += 1;
            }
        }
        if (operand_ref.kind == .inst) if (r.cancels.get(operand_ref.value)) |cancel| {
            var items: std.ArrayList(diag.Note) = .empty;
            if (st.dead.get(r.identRec(cancel.tomb).a)) |e| try items.append(r.arena, .{ .loc = e.loc, .text = e.text });
            try r.report(st, .double_free, inst.loc, try r.noteList(items.items), "memory is freed twice", .{});
        };
        try r.exec(r.v.insts(bodies[0]), &failed);
        if (failed.alive) return r.unsupported(inst, "the error path of a try falls through", .{});
        try r.applyMoved(st, subject);
        r.set(inst, eu);
    }
};
