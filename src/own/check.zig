//! The ownership checker. One function is run abstractly over its AIR (structured control flow, joined at
//! the end of every construct, loops iterated to a fixed point); the run tracks
//!
//!   linear tokens   every `zv.Linear` value a path creates, receives or gets back from a call is a token;
//!                   a token is live until a sink ends it: passing it by value, returning it, storing it into
//!                   memory the function does not own. Ending an ended token, or leaving a live one, is a finding.
//!   owners          what a pointer's validity hangs on: a stack slot, an allocation, a region (an arena), the
//!                   buffer behind a container field, a parameter. An operation ends owners (`free`, `deinit`, an
//!                   invalidating method); using a value that depends on an ended owner is a finding.
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
const Set = dom.Set;
const Val = dom.Val;
const PlaceId = dom.PlaceId;
const Places = dom.Places;
const Inst = schema.Inst;

pub const Ref = struct { pack: *const schema.Pack, func: schema.Func };

pub const Stats = struct {
    insts: u32 = 0,
    /// Calls to functions that are not in the packs and that the checker has no model of: they are assumed
    /// to neither end owners nor keep their arguments.
    unknown_calls: u32 = 0,
    /// Tokens handed to memory the function does not own: ownership passes on, the checker stops following it.
    transfers: u32 = 0,
    /// Container methods nobody wrote down and whose body is not in the packs: assumed to invalidate.
    unmodelled: u32 = 0,
    /// Operations on a container or allocation the checker cannot name a place for: their effects are not applied.
    blind: u32 = 0,
    /// `resize` or `remap` with a length the checker cannot show to be non-zero: assumed not to free.
    dynamic_len: u32 = 0,
};

/// What a caller needs to know about a function it calls, read from the function itself.
pub const Summary = struct {
    /// False when the run stopped early: a caller falls back to the model of a function it cannot read.
    complete: bool = true,
    /// What the result may point into or depend on, below the parameters.
    ret: []const RetRef = &.{},
    /// The result is a new allocation (a wrapper around an allocator call).
    ret_alloc: bool = false,
    /// Pointers into these places (below a parameter) are stale after the call.
    kills: []const Kill = &.{},
    /// Bit i: the allocation or handle behind parameter i is freed.
    frees: u64 = 0,
    /// Values that arrive in one parameter and are stored below another one.
    stores: []const Store = &.{},
    /// Bit i: a linear value passed in parameter i is stored into memory the function does not own.
    token_stores: u64 = 0,
    /// The result is the pointer passed as this parameter, possibly cast (`mem.asBytes`).
    ret_same: ?u32 = null,
    /// A guess made while the function's own body is read (recursion), not something the body showed.
    assumed: bool = false,
    /// Bit i: the function returns the result of a `realloc` or `remap` of parameter i, so the allocation is gone
    /// when the result holds a payload.
    moves: u64 = 0,

    pub fn eql(a: Summary, b: Summary) bool {
        if (a.complete != b.complete or a.ret_alloc != b.ret_alloc or a.frees != b.frees or a.token_stores != b.token_stores or a.moves != b.moves) return false;
        if (a.ret.len != b.ret.len or a.kills.len != b.kills.len or a.stores.len != b.stores.len) return false;
        for (a.ret, b.ret) |x, y| if (x.param != y.param or x.stored != y.stored or x.interior != y.interior or !std.mem.eql(u32, x.path, y.path)) return false;
        for (a.kills, b.kills) |x, y| if (x.param != y.param or x.ends != y.ends or !std.mem.eql(u32, x.path, y.path)) return false;
        for (a.stores, b.stores) |x, y| {
            if (x.from != y.from or x.into != y.into or !std.mem.eql(u32, x.path, y.path)) return false;
            if ((x.from_path == null) != (y.from_path == null) or x.moves != y.moves) return false;
            if (x.from_path) |xp| if (!std.mem.eql(u32, xp, y.from_path.?)) return false;
        }
        if (a.ret_same != b.ret_same) return false;
        return true;
    }
};

pub const Kill = struct { param: u32, path: []const u32, ends: bool };

/// Parameter `from` (or something it points to) is stored at `path` below what parameter `into` points to.
/// With `from_path`, what is stored is the storage that was read at that path below parameter `from` (`swap` moves
/// the buffer of one container into another), not the parameter itself.
/// `moves`: the storage went (`swap`), not a copy of the pointers that lead to it.
pub const Store = struct { from: u32, into: u32, path: []const u32, from_path: ?[]const u32 = null, moves: bool = false };

/// The result depends on parameter `param` (`stored`: on what was read out of it, not the parameter itself),
/// at `path` below what it points to.
/// `interior`: the pointer that comes back points inside what the parameter points to (a field, an element), not at it.
pub const RetRef = struct { param: u32, path: []const u32, stored: bool, interior: bool = false };

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
    /// Every function by name: instances of one generic function share it, so a call picks by the types it passes.
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
        var p: Program = .{ .gpa = gpa, .arena = arena };
        for (packs) |pack| for (pack.t.funcs) |f| {
            const gop = try p.funcs.getOrPut(arena, pack.str(f.fqn));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, .{ .pack = pack, .func = f });
        };
        return p;
    }

    /// The function a call names. Several functions of one name are instances of a generic function: the one whose
    /// parameters have the types of the arguments is meant, and when that does not settle it the call is unknown.
    fn resolve(p: *Program, name: []const u8, pack: *const schema.Pack, arg_tys: []const schema.TypeId) ?Ref {
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
            if (found) |f| if (f.func.id != cand.func.id) return null;
            found = cand;
        }
        return found;
    }

    pub fn analyze(p: *Program, ref: Ref) Allocator.Error!*const Result {
        const key = try std.fmt.allocPrint(p.arena, "{s}#{x}", .{ ref.pack.str(ref.func.fqn), ref.func.id });
        if (p.results.get(key)) |done| return done;
        if (p.tentative.get(key)) |t| {
            for (t.on) |k| try p.consulted.put(p.arena, k, {});
            return t.result;
        }
        var outer = p.consulted;
        p.consulted = .empty;
        // Start from the most optimistic summary: everything is freed, nothing is invalidated. Recursion that
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
    fn summaryOf(p: *Program, ref: Ref) Allocator.Error!?Summary {
        const key = try std.fmt.allocPrint(p.arena, "{s}#{x}", .{ ref.pack.str(ref.func.fqn), ref.func.id });
        if (p.busy.get(key)) |assumed| {
            try p.consulted.put(p.arena, key, {});
            return assumed;
        }
        const done = try p.analyze(ref);
        return if (done.summary.complete) done.summary else null;
    }
};

const Error = Allocator.Error || error{Unsupported};

const Token = struct { site: u32, sub: u32, loc: schema.LocId };

const OwnerKind = enum {
    /// A stack slot (`n` is its `alloc`). Pointers to it must not leave the function.
    local,
    /// The memory behind parameter `n`: the caller's.
    param,
    /// An allocation made at call `n`.
    heap,
    /// The storage a pointer read out of `place` points into (`n` is the instruction that read it).
    buffer,
    /// The object stored at `place` (an arena, a container): while it lives, what it handed out is valid.
    object,
    /// Storage that was read at `place` and moved by the call `n` into another object (`mem.swap`): it ends with
    /// whatever ends it at `place`, and with the object it moved into.
    moved,
};

const Owner = struct { kind: OwnerKind, n: u32, place: PlaceId };

const Event = struct { loc: schema.LocId, text: []const u8, trail: ?*const diag.Trail };

const Pending = struct { loc: schema.LocId, place: PlaceId, site: u32 };

/// `cap_lb`: the container holds at least this many elements without reallocating. `len_ub`: it holds at most this
/// many now, when that is known.
const Cap = struct { cap_lb: u64 = 0, len_ub: ?u64 = null };

const Pred = struct { subject: Val, ptr: bool, present_if_true: bool };

const Trail = diag.Trail;

const State = struct {
    alive: bool = true,
    mem: std.AutoArrayHashMapUnmanaged(PlaceId, Val) = .empty,
    live: Set = .empty,
    ended: Set = .empty,
    /// Parameters freed on every path that led here (the dead set is the paths' union).
    freed: Set = .empty,
    /// Owners that no longer exist, and why (the first cause on this path).
    dead: std.AutoArrayHashMapUnmanaged(dom.Id, Event) = .empty,
    /// Stack slots whose address went into a container that outlives them: fine if the entry is removed before
    /// the function returns (a registry for the duration of a call).
    pending: std.AutoArrayHashMapUnmanaged(dom.Id, Pending) = .empty,
    /// What is known of the room in a container (an array list, a hash map) at a place: how many elements fit without
    /// reallocating, and how many are in it at most. A place without an entry is known to hold nothing of the sort.
    caps: std.AutoArrayHashMapUnmanaged(PlaceId, Cap) = .empty,
    trail: ?*const Trail = null,

    fn clone(s: State, arena: Allocator) Allocator.Error!State {
        var c = s;
        c.mem = try s.mem.clone(arena);
        c.dead = try s.dead.clone(arena);
        c.pending = try s.pending.clone(arena);
        c.caps = try s.caps.clone(arena);
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
        var pending_it = b.pending.iterator();
        while (pending_it.next()) |e| {
            const gop = try out.pending.getOrPut(arena, e.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = e.value_ptr.*;
        }
        var dead_it = b.dead.iterator();
        while (dead_it.next()) |e| {
            const gop = try out.dead.getOrPut(arena, e.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = e.value_ptr.*;
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
        return out;
    }

    fn die(s: *State, arena: Allocator, id: dom.Id, event: Event) Allocator.Error!void {
        const gop = try s.dead.getOrPut(arena, id);
        if (!gop.found_existing) gop.value_ptr.* = event;
    }

    fn revive(s: *State, id: dom.Id) void {
        _ = s.dead.swapRemove(id);
    }

    fn eql(a: State, b: State) bool {
        if (a.alive != b.alive) return false;
        if (!a.alive) return true;
        if (!a.live.eql(b.live) or !a.ended.eql(b.ended)) return false;
        if (!a.freed.eql(b.freed)) return false;
        if (a.caps.count() != b.caps.count()) return false;
        var caps_it = a.caps.iterator();
        while (caps_it.next()) |e| {
            const other = b.caps.get(e.key_ptr.*) orelse return false;
            if (e.value_ptr.cap_lb != other.cap_lb or e.value_ptr.len_ub != other.len_ub) return false;
        }
        if (a.pending.count() != b.pending.count()) return false;
        for (a.pending.keys()) |k| if (!b.pending.contains(k)) return false;
        if (a.dead.count() != b.dead.count()) return false;
        for (a.dead.keys()) |k| if (!b.dead.contains(k)) return false;
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

const Run = struct {
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
    owners: std.ArrayList(Owner) = .empty,
    owner_map: std.AutoHashMapUnmanaged(Owner, dom.Id) = .empty,
    vals: []Val,
    by_id: []?*const Inst,
    names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    tok_names: std.AutoHashMapUnmanaged(dom.Id, []const u8) = .empty,
    /// The first stack slot a token was stored into: a variable named after it.
    tok_cells: std.AutoHashMapUnmanaged(dom.Id, u32) = .empty,
    /// Names of the fields places stand for.
    field_names: std.AutoHashMapUnmanaged(PlaceId, []const u8) = .empty,
    /// For the summary: what the function does to what its parameters point into.
    kills: std.ArrayList(Kill) = .empty,
    /// Parameters freed on every path that returns (a conditional free is not one the caller can rely on).
    frees_all: u64 = ~@as(u64, 0),
    moves_all: u64 = ~@as(u64, 0),
    any_ret: bool = false,
    stores: std.ArrayList(Store) = .empty,
    ret_refs: std.ArrayList(RetRef) = .empty,
    ret_alloc: bool = false,
    /// For the summary: bit i is set when a linear value that came in as parameter i went into memory the function
    /// does not own.
    token_stored: u64 = 0,
    /// For the summary: the parameter the result is the pointer of, on every path that returns.
    ret_same: ?u32 = null,
    ret_same_conflict: bool = false,
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
        var r: Run = .{
            .prog = prog,
            .arena = arena,
            .pack = ref.pack,
            .v = .{ .pack = ref.pack },
            .ty = try .init(arena, ref.pack),
            .func = ref.func,
            .name = ref.pack.str(ref.func.fqn),
            .vals = vals,
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
        const kills = try arena.alloc(Kill, r.kills.items.len);
        for (kills, r.kills.items) |*out, k| out.* = .{ .param = k.param, .path = try arena.dupe(u32, k.path), .ends = k.ends };
        return .{
            .name = try arena.dupe(u8, r.name),
            .diags = diags,
            .stats = r.stats,
            .summary = .{ .complete = complete, .ret = try r.persistRefs(arena), .ret_alloc = r.ret_alloc, .kills = kills, .frees = if (r.any_ret) r.frees_all else 0, .stores = try r.persistStores(arena), .token_stores = r.token_stored, .moves = if (r.any_ret) r.moves_all else 0, .ret_same = if (r.ret_same_conflict) null else r.ret_same },
        };
    }

    fn persistStores(r: *Run, arena: Allocator) Allocator.Error![]const Store {
        const out = try arena.alloc(Store, r.stores.items.len);
        for (out, r.stores.items) |*slot, s| slot.* = .{
            .from = s.from,
            .into = s.into,
            .path = try arena.dupe(u32, s.path),
            .from_path = if (s.from_path) |fp| try arena.dupe(u32, fp) else null,
            .moves = s.moves,
        };
        return out;
    }

    fn persistRefs(r: *Run, arena: Allocator) Allocator.Error![]const RetRef {
        const out = try arena.alloc(RetRef, r.ret_refs.items.len);
        for (out, r.ret_refs.items) |*slot, ref| slot.* = .{ .param = ref.param, .path = try arena.dupe(u32, ref.path), .stored = ref.stored, .interior = ref.interior };
        return out;
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
    fn tally(r: *Run, comptime field: []const u8, inst: *const Inst) Allocator.Error!void {
        const kind: u64 = comptime @intCast(std.meta.fieldIndex(Stats, field).?);
        const gop = try r.tallied.getOrPut(r.arena, (@as(u64, inst.id) << 8) | kind);
        if (!gop.found_existing) @field(r.stats, field) += 1;
    }

    // Findings.

    fn report(r: *Run, st: *const State, kind: diag.Kind, loc: schema.LocId, extra: []const diag.Note, comptime fmt: []const u8, args: anytype) Error!void {
        if (r.quiet != 0) return;
        const text = try std.fmt.allocPrint(r.arena, fmt, args);
        const key = try std.fmt.allocPrint(r.arena, "{t}@{d}:{s}", .{ kind, @backingInt(loc), text });
        const gop = try r.seen.getOrPut(r.arena, key);
        if (gop.found_existing) return;
        try r.diags.append(r.arena, .{ .kind = kind, .loc = loc, .text = text, .notes = extra, .trail = st.trail });
    }

    fn reportAt(r: *Run, st: *const State, kind: diag.Kind, loc: schema.LocId, extra: []const diag.Note, comptime fmt: []const u8, args: anytype) Error!void {
        return r.report(st, kind, loc, extra, fmt, args);
    }

    fn unsupported(r: *Run, inst: *const Inst, comptime fmt: []const u8, args: anytype) Error {
        const text = try std.fmt.allocPrint(r.arena, fmt, args);
        try r.diags.append(r.arena, .{ .kind = .unsupported, .loc = if (inst.loc != .none) inst.loc else r.cur_loc, .text = text });
        return error.Unsupported;
    }

    fn note(r: *Run, loc: schema.LocId, comptime fmt: []const u8, args: anytype) Allocator.Error!diag.Note {
        return .{ .loc = loc, .text = try std.fmt.allocPrint(r.arena, fmt, args) };
    }

    fn noteList(r: *Run, items: []const diag.Note) Allocator.Error![]const diag.Note {
        return r.arena.dupe(diag.Note, items);
    }

    // Tokens and owners.

    fn token(r: *Run, site: u32, sub: u32, loc: schema.LocId) Allocator.Error!dom.Id {
        const key = (@as(u64, site) << 32) | sub;
        const gop = try r.token_map.getOrPut(r.arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(r.tokens.items.len);
            try r.tokens.append(r.arena, .{ .site = site, .sub = sub, .loc = loc });
        }
        return gop.value_ptr.*;
    }

    fn owner(r: *Run, kind: OwnerKind, n: u32, place: PlaceId) Allocator.Error!dom.Id {
        const key: Owner = .{ .kind = kind, .n = n, .place = place };
        const gop = try r.owner_map.getOrPut(r.arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(r.owners.items.len);
            try r.owners.append(r.arena, key);
        }
        return gop.value_ptr.*;
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

    fn operand(r: *Run, o: schema.Operand) Val {
        return switch (o.kind) {
            .inst => r.vals[o.value],
            else => .none,
        };
    }

    fn arg(r: *Run, inst: *const Inst, i: usize) Val {
        return r.operand(r.v.ops(inst)[i]);
    }

    fn operandType(r: *Run, o: schema.Operand) schema.TypeId {
        return switch (o.kind) {
            .inst => if (r.by_id[o.value]) |i| i.ty else .none,
            .constant => r.v.constant(o).ty,
            .none => .none,
        };
    }

    fn set(r: *Run, inst: *const Inst, val: Val) void {
        // A number points nowhere and holds nothing, whatever it was computed from.
        r.vals[inst.id] = switch (r.ty.kind(inst.ty)) {
            .int, .bool, .float, .@"enum", .error_set, .comptime_int, .comptime_float, .void, .noreturn, .enum_literal => Val.none,
            else => val,
        };
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

    // Memory.

    fn readPlace(r: *Run, st: *const State, place: PlaceId) Allocator.Error!Val {
        if (st.mem.get(place)) |v| {
            // Parts written after the whole was stored are newer than it.
            var out = v;
            var it = st.mem.iterator();
            while (it.next()) |e| {
                if (e.key_ptr.* != place and r.places.contains(place, e.key_ptr.*)) out = try out.flat().join(r.arena, e.value_ptr.flat());
            }
            return out;
        }
        // Stored whole in an ancestor: project the fields down.
        var path: std.ArrayList(u32) = .empty;
        var at = place;
        while (true) {
            const rec = r.places.rec(at);
            if (rec.parent == dom.no_place) break;
            try path.append(r.arena, rec.step);
            at = rec.parent;
            if (st.mem.get(at)) |whole| {
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
        var it = st.mem.iterator();
        while (it.next()) |e| {
            if (r.places.contains(place, e.key_ptr.*)) out = try out.join(r.arena, e.value_ptr.flat());
        }
        return out;
    }

    fn writePlace(r: *Run, st: *State, place: PlaceId, val: Val) Allocator.Error!void {
        const root = r.places.rec(place);
        const strong = root.kind == .cell and !r.places.hasElem(place);
        // Whatever was stored below is overwritten.
        if (strong) {
            var k: usize = 0;
            while (k < st.mem.count()) {
                if (st.mem.keys()[k] != place and r.places.contains(place, st.mem.keys()[k])) {
                    st.mem.swapRemoveAt(k);
                } else k += 1;
            }
        }
        const gop = try st.mem.getOrPut(r.arena, place);
        gop.value_ptr.* = if (strong or !gop.found_existing) val else try gop.value_ptr.join(r.arena, val);
    }

    fn isLocalPtr(r: *Run, p: Val) bool {
        if (p.place) |pl| return r.places.rec(pl).kind == .cell;
        if (p.owners.isEmpty()) return false;
        for (p.owners.ids) |o| if (r.owners.items[o].kind != .local) return false;
        return true;
    }

    // Ending.

    fn anyAlt(v: Val) bool {
        if (v.alt) return true;
        if (v.parts) |parts| for (parts) |p| if (anyAlt(p)) return true;
        return false;
    }

    /// Ends the tokens of `val` for `how` (a phrase for the finding): a sink.
    fn sink(r: *Run, st: *State, inst: *const Inst, val: Val, comptime how: []const u8, callee: []const u8) Error!void {
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
    fn use(r: *Run, st: *State, inst: *const Inst, val: Val, what: []const u8) Error!void {
        for (val.toks.ids) |t| if (st.ended.has(t)) {
            var items: std.ArrayList(diag.Note) = .empty;
            if (r.ends.get(t)) |e| try items.append(r.arena, .{ .loc = e.loc, .text = e.text });
            try r.report(st, .use_after_consume, inst.loc, try r.noteList(items.items), "linear value `{s}` is {s} after it was consumed", .{ r.tokenName(t), what });
        };
        try r.alive(st, inst, val, what);
    }

    /// Everything `val` depends on must still exist.
    fn alive(r: *Run, st: *State, inst: *const Inst, val: Val, what: []const u8) Error!void {
        for (val.owners.ids) |o| {
            if (!st.dead.contains(o)) continue;
            var items: std.ArrayList(diag.Note) = .empty;
            if (st.dead.get(o)) |e| try items.append(r.arena, .{ .loc = e.loc, .text = e.text });
            if (try r.origin(o)) |where| try items.append(r.arena, where);
            try r.report(st, .use_after_free, inst.loc, try r.noteList(items.items), "memory that was freed or invalidated is used here ({s})", .{what});
        }
    }

    /// Where the pointer that depends on owner `o` came from, for the finding that names it.
    fn origin(r: *Run, o: dom.Id) Allocator.Error!?diag.Note {
        const rec = r.owners.items[o];
        switch (rec.kind) {
            .buffer => {
                const at = if (r.by_id[rec.n]) |i| i.loc else .none;
                return try r.note(at, "the pointer was read from `{s}` here", .{r.placeName(rec.place)});
            },
            .moved => {
                const at = if (r.by_id[rec.n]) |i| i.loc else .none;
                return try r.note(at, "the storage of `{s}` was moved here", .{r.placeName(rec.place)});
            },
            .heap => {
                const at = if (r.by_id[rec.n]) |i| i.loc else .none;
                return try r.note(at, "the memory was allocated here", .{});
            },
            else => return null,
        }
    }

    // Control flow.

    fn exec(r: *Run, list: []const Inst, st: *State) Error!void {
        for (list) |*inst| {
            if (!st.alive) return;
            try r.step(inst, st);
        }
    }

    fn step(r: *Run, inst: *const Inst, st: *State) Error!void {
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
                const local = try r.owner(.local, inst.id, dom.no_place);
                st.revive(local);
                // A slot that is made again (in a loop) holds a new object.
                for (r.owners.items, 0..) |o, id| {
                    if (o.kind == .object and r.places.contains(cell, o.place)) st.revive(@intCast(id));
                }
                r.set(inst, .{ .place = cell, .owners = try Set.single(r.arena, local), .off = 0 });
            },
            .store, .store_safe => {
                const dst = r.arg(inst, 0);
                try r.store(inst, st, dst, r.arg(inst, 1), r.operandType(r.v.ops(inst)[1]));
                // A container made of a constant (`.empty`) holds nothing and has no room.
                if (dst.place) |pl| if (r.v.ops(inst)[1].kind == .constant and r.isContainer(r.operandType(r.v.ops(inst)[1])))
                    try st.caps.put(r.arena, pl, .{ .cap_lb = 0, .len_ub = 0 });
            },
            .load => {
                const p = r.arg(inst, 0);
                try r.alive(st, inst, p, "read");
                r.set(inst, try r.load(st, inst, p, inst.ty));
            },

            .ptr_cast, .bit_cast, .bit_cast_safe, .addrspace_cast, .slice_ptr, .array_to_slice, .slice, .ptr_slice_ptr_ptr, .ptr_slice_len_ptr => {
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
                p.many = true;
                if (p.place) |pl| p.place = try r.places.child(r.arena, pl, dom.elem_step);
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
                    p.place = try r.places.child(r.arena, pl, field);
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
                    if (p.place) |pl| p.place = try r.places.child(r.arena, pl, dom.elem_step);
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
                try r.preds.put(r.arena, inst.id, .{ .subject = r.arg(inst, 0), .ptr = ptr, .present_if_true = present_if_true });
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
                try ctx.incoming.append(r.arena, .{ .state = try st.clone(r.arena), .val = val });
                st.alive = false;
            },
            .repeat => {
                const target = r.v.attr(inst, .target) orelse return r.unsupported(inst, "repeat without a target", .{});
                const ctx = r.loops.get(target) orelse return r.unsupported(inst, "repeat outside its loop", .{});
                try ctx.back.append(r.arena, try st.clone(r.arena));
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
                var content: Val = if (src.place) |pl| (try r.readPlace(st, pl)).flat() else .none;
                if (!content.toks.isEmpty()) return r.unsupported(inst, "a copy of linear values", .{});
                content.place = null;
                try r.store(inst, st, dst, content, .none);
            },
            .memset, .memset_safe => {
                try r.alive(st, inst, r.arg(inst, 0), "write");
            },
            .atomic_store_unordered, .atomic_store_monotonic, .atomic_store_release, .atomic_store_seq_cst => {
                try r.alive(st, inst, r.arg(inst, 0), "write");
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
                // the owners (an operation on it is applied to everything those own).
                var p = r.arg(inst, 0);
                p.off = null;
                p.many = false;
                if (p.place) |pl| {
                    const up = r.places.rec(pl);
                    p.place = if (up.parent != dom.no_place and up.step != dom.elem_step and up.step != dom.backing_step) up.parent else null;
                }
                r.set(inst, p);
            },
            .assembly => return r.unsupported(inst, "inline assembly", .{}),
            .loop_switch_br, .switch_dispatch => return r.unsupported(inst, "a labeled switch loop", .{}),

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

    /// What a pointer or slice points at, looking through an array to its element.
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

    fn pointeeOf(r: *Run, ptr_ty: schema.TypeId) schema.TypeId {
        return r.ty.pointee(ptr_ty) orelse .none;
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
        const param_owner = try r.owner(.param, i, dom.no_place);
        if (r.ty.isPointer(inst.ty)) {
            val.place = try r.places.root(r.arena, .param, i);
            val.off = 0;
            val.owners = try val.owners.with(r.arena, param_owner);
        } else if (r.ty.hasPointers(inst.ty) or r.ty.kind(inst.ty) == .@"struct") {
            // A struct without pointers can still be a handle: freeing it frees what the caller gave.
            val.owners = try val.owners.with(r.arena, param_owner);
        }
        r.set(inst, val);
    }

    fn block(r: *Run, inst: *const Inst, st: *State) Error!void {
        const bodies = r.v.bodies(inst);
        if (bodies.len != 1) return r.unsupported(inst, "a block with {d} bodies", .{bodies.len});
        const ctx = try r.arena.create(BlockCtx);
        ctx.* = .{};
        try r.blocks.put(r.arena, inst.id, ctx);
        const entry = st.trail;
        try r.exec(r.v.insts(bodies[0]), st);
        if (st.alive) try ctx.incoming.append(r.arena, .{ .state = try st.clone(r.arena), .val = .none });
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
            var next = entry;
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
        if (take_then) {
            var s = try st.clone(r.arena);
            if (decision) s.trail = try r.push(st.trail, inst.loc, .then);
            if (pred) |p| if (p.present_if_true) try r.present(&s, p) else try r.absent(&s, p);
            try r.exec(r.v.insts(bodies[0]), &s);
        }
        if (take_else) {
            var s = try st.clone(r.arena);
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

    /// On this path the optional or error union of `p` holds no payload, so its tokens do not exist.
    fn absent(r: *Run, st: *State, p: Pred) Error!void {
        var subject = p.subject;
        if (p.ptr) subject = if (subject.place) |pl| try r.readPlace(st, pl) else .none;
        st.live = try st.live.minus(r.arena, subject.toks);
    }

    fn tryOp(r: *Run, inst: *const Inst, st: *State) Error!void {
        const bodies = r.v.bodies(inst);
        if (bodies.len != 1) return r.unsupported(inst, "a try with {d} bodies", .{bodies.len});
        const eu = r.arg(inst, 0);
        var failed = try st.clone(r.arena);
        failed.trail = try r.push(st.trail, inst.loc, .@"error");
        var subject = eu;
        if (inst.tag == .try_ptr or inst.tag == .try_ptr_cold) subject = if (eu.place) |pl| try r.readPlace(st, pl) else .none;
        failed.live = try failed.live.minus(r.arena, subject.toks);
        // A call that failed did not do what it was asked to: nothing it stores is there.
        const operand_ref = r.v.ops(inst)[0];
        if (operand_ref.kind == .inst) {
            var k: usize = 0;
            while (k < failed.pending.count()) {
                if (failed.pending.values()[k].site == operand_ref.value) failed.pending.swapRemoveAt(k) else k += 1;
            }
        }
        try r.exec(r.v.insts(bodies[0]), &failed);
        if (failed.alive) return r.unsupported(inst, "the error path of a try falls through", .{});
        try r.applyMoved(st, subject);
        r.set(inst, eu);
    }

    fn store(r: *Run, inst: *const Inst, st: *State, ptr: Val, val: Val, val_ty: schema.TypeId) Error!void {
        _ = val_ty;
        try r.alive(st, inst, ptr, "write");
        try r.escapes(st, inst, val, r.isLocalPtr(ptr), "stored into memory that outlives it");
        if (ptr.place) |pl| {
            try r.objectAlive(st, inst, pl);
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
            try r.noteStores(pl, val);
            try r.writePlace(st, pl, val);
            // A new value in the place of an object (`arena = .init(gpa)`) starts it afresh.
            for (r.owners.items, 0..) |o, id| {
                if (o.kind == .object and r.places.contains(pl, o.place)) st.revive(@intCast(id));
            }
        } else {
            // A store through a pointer into the storage behind a parameter's field (`list.items[i] = x` by way of a
            // pointer a callee returned) lands below that parameter.
            for (ptr.owners.ids) |o| {
                const rec = r.owners.items[o];
                if (rec.kind == .buffer) try r.noteStores(try r.places.child(r.arena, rec.place, dom.elem_step), val);
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

    /// For the summary: a value that came in through a parameter is stored below another parameter.
    fn noteStores(r: *Run, into: PlaceId, val: Val) Allocator.Error!void {
        const root = r.places.rec(into);
        if (root.kind != .param) return;
        for (val.owners.ids) |o| {
            const rec = r.owners.items[o];
            var from: u32 = undefined;
            var from_path: ?[]const u32 = null;
            var moves = false;
            switch (rec.kind) {
                .param => {
                    if (rec.n == root.n) continue;
                    from = rec.n;
                },
                .buffer, .moved => {
                    const at = r.places.rec(rec.place);
                    if (at.kind != .param or at.n == root.n) continue;
                    from = at.n;
                    from_path = try r.places.path(r.arena, rec.place);
                    moves = rec.kind == .moved;
                },
                else => continue,
            }
            const path = try r.places.path(r.arena, into);
            var known = false;
            for (r.stores.items) |q| {
                if (q.from != from or q.into != root.n or !std.mem.eql(u32, q.path, path)) continue;
                if ((q.from_path == null) != (from_path == null) or q.moves != moves) continue;
                if (from_path) |fp| if (!std.mem.eql(u32, fp, q.from_path.?)) continue;
                known = true;
            }
            if (!known) try r.stores.append(r.arena, .{ .from = from, .into = root.n, .path = path, .from_path = from_path, .moves = moves });
        }
    }

    fn withoutLocals(r: *Run, s: Set) Allocator.Error!Set {
        var out = s;
        for (s.ids) |o| if (r.owners.items[o].kind == .local) {
            out = try out.without(r.arena, o);
        };
        return out;
    }

    /// An object (an arena, a container) that was deinitialized must not be touched.
    fn objectAlive(r: *Run, st: *State, inst: *const Inst, pl: PlaceId) Error!void {
        for (r.owners.items, 0..) |o, id| {
            if (o.kind != .object or !r.places.contains(o.place, pl) or !st.dead.contains(@intCast(id))) continue;
            var items: std.ArrayList(diag.Note) = .empty;
            if (st.dead.get(@intCast(id))) |e| try items.append(r.arena, .{ .loc = e.loc, .text = e.text });
            try r.report(st, .use_after_free, inst.loc, try r.noteList(items.items), "`{s}` is used after it was deinitialized", .{r.placeName(o.place)});
        }
    }

    fn load(r: *Run, st: *State, inst: *const Inst, ptr: Val, ty: schema.TypeId) Error!Val {
        var out: Val = .none;
        // A temporary the compiler built to return a fresh value is not a copy of anything the program named.
        const temporary = if (ptr.place) |pl| r.places.rec(pl).kind == .cell and !r.names.contains(r.places.rec(pl).n) else false;
        if (r.ty.isPinned(ty) and !temporary) try r.report(st, .pinned_copy, inst.loc, &.{}, "a value of the pinned type `{s}` is copied by value; pass a pointer to it", .{r.ty.name(ty)});
        if (ptr.place) |pl| {
            try r.objectAlive(st, inst, pl);
            out = try r.readPlace(st, pl);
            if (r.places.rec(pl).kind != .cell and r.ty.hasTokens(ty))
                return r.unsupported(inst, "a linear value read out of memory this function does not own", .{});
            if (out.src == null and r.ty.kind(ty) == .@"struct") out.src = pl;
        } else if (r.ty.hasTokens(ty)) {
            return r.unsupported(inst, "a linear value read through a pointer the checker cannot follow", .{});
        }
        if (r.ty.hasPointers(ty)) {
            // What was stored carries its own owners; a pointer found in memory nobody stored into depends on
            // the storage it was read from, which is not the stack slot or parameter that holds its address.
            // A struct read out of memory is a copy of what was stored: only a pointer or slice itself points into it.
            // A pointer or slice read from a place points into storage the place holds. So does a struct read from a
            // field (the header of a container, an iterator): its pointers are those of the fields. An element read out
            // of an array or slice is a copy of what was stored there, whose pointers lead elsewhere.
            if (ptr.place) |pl| if (r.topLevelPointer(ty) or !r.places.hasElem(pl)) {
                out.owners = try out.owners.with(r.arena, try r.bufferOwner(st, inst.id, pl));
            };
            // Memory a container got from an allocator depends on it.
            if (ptr.place) |pl| {
                var at = pl;
                while (true) {
                    if (r.places.find(at, dom.backing_step)) |slot| if (st.mem.get(slot)) |b| {
                        out.owners = try out.owners.merge(r.arena, b.owners);
                    };
                    at = r.places.rec(at).parent;
                    if (at == dom.no_place) break;
                }
            }
        }
        if (ptr.many or (ptr.place != null and r.places.hasElem(ptr.place.?))) out.many = true;
        // A number read out of a stale handle is data, not a use of what the handle names.
        switch (r.ty.kind(ty)) {
            .int, .bool, .float, .@"enum", .error_set => return Val.none,
            else => {},
        }
        try r.alive(st, inst, out, "read");
        return out;
    }

    fn isInsertion(callee: []const u8) bool {
        const dot = std.mem.lastIndexOfScalar(u8, callee, '.') orelse 0;
        const method = callee[if (dot == 0) 0 else dot + 1..];
        const stores = [_][]const u8{ "append", "put", "insert", "add", "push", "enqueue", "getOrPut", "ensure", "resize", "reserve", "expand" };
        for (stores) |s| if (std.mem.startsWith(u8, method, s)) return true;
        return false;
    }

    fn noteRet(r: *Run, ref: RetRef) Allocator.Error!void {
        for (r.ret_refs.items) |q| {
            if (q.param == ref.param and q.stored == ref.stored and q.interior == ref.interior and std.mem.eql(u32, q.path, ref.path)) return;
        }
        try r.ret_refs.append(r.arena, ref);
    }

    fn ret(r: *Run, inst: *const Inst, st: *State, val: Val) Error!void {
        var freed_here: u64 = 0;
        for (st.freed.ids) |o| {
            const rec = r.owners.items[o];
            if (rec.kind == .param and rec.n < 64) freed_here |= @as(u64, 1) << @intCast(rec.n);
        }
        r.frees_all &= freed_here;
        var moved_here: u64 = 0;
        for (val.moved.ids) |o| {
            const rec = r.owners.items[o];
            if (rec.kind == .param and rec.n < 64) moved_here |= @as(u64, 1) << @intCast(rec.n);
        }
        r.moves_all &= moved_here;
        r.any_ret = true;
        try r.use(st, inst, val, "returned");
        if (val.place) |pl| {
            const rec = r.places.rec(pl);
            const same: ?u32 = if (rec.kind == .param and rec.parent == dom.no_place) rec.n else null;
            if (same == null or (r.ret_same != null and r.ret_same.? != same.?)) r.ret_same_conflict = true else r.ret_same = same;
        } else r.ret_same_conflict = true;
        for (val.owners.ids) |o| {
            const rec = r.owners.items[o];
            switch (rec.kind) {
                .local => {
                    const slot = r.names.get(rec.n) orelse "a local";
                    try r.report(st, .escape_local, inst.loc, &.{}, "a pointer to `{s}` is returned, but `{s}` ends with the function", .{ slot, slot });
                },
                .param => {
                    const inside = if (val.place) |pl| r.places.rec(pl).parent != dom.no_place else false;
                    try r.noteRet(.{ .param = rec.n, .path = &.{}, .stored = false, .interior = inside });
                },
                .buffer, .object, .moved => {
                    const root = r.places.rec(rec.place);
                    if (root.kind == .param) try r.noteRet(.{ .param = root.n, .path = try r.places.path(r.arena, rec.place), .stored = true });
                },
                .heap => r.ret_alloc = true,
            }
        }
        for (st.pending.keys(), st.pending.values()) |o, p| {
            const slot = r.names.get(r.owners.items[o].n) orelse "a local";
            const where: diag.Note = .{ .loc = inst.loc, .text = "it is still there when the function returns here" };
            try r.reportAt(st, .escape_local, p.loc, try r.noteList(&.{where}), "a pointer to `{s}` is stored into a container that outlives it", .{slot});
        }
        // Handing the value to the caller ends the function's ownership of its tokens.
        st.live = try st.live.minus(r.arena, val.toks);
        for (st.live.ids) |t| {
            const made = try r.created(t);
            try r.report(st, .leak, inst.loc, try r.noteList(&.{made}), "linear value `{s}` is not consumed on this path", .{r.tokenName(t)});
        }
        st.alive = false;
    }

    fn call(r: *Run, inst: *const Inst, st: *State) Error!void {
        // A call through a function pointer is a call to a function nothing is known of.
        const callee = r.v.attrStr(inst, .callee) orelse "(call through a function pointer)";
        const ops = r.v.ops(inst);
        var name_buf: [512]u8 = undefined;
        const declared = spec.stripped(&name_buf, callee);
        const n = ops.len - 1;
        const args = try r.arena.alloc(Val, n);
        const arg_tys = try r.arena.alloc(schema.TypeId, n);
        for (args, arg_tys, ops[1..]) |*a, *t, o| {
            a.* = r.operand(o);
            t.* = r.operandType(o);
        }
        const known: ?Ref = r.prog.resolve(callee, r.pack, arg_tys);
        var effect: spec.Effect = r.prog.annotations.get(declared) orelse spec.lookup(declared);
        const body: ?Summary = if (known) |ref| try r.prog.summaryOf(ref) else null;

        // A container method of std is read from its body when the pack has one; the documented model covers the rest.
        var model: spec.Model = .{};
        var summary: ?Summary = null;
        const container_call = effect == .container;
        if (container_call) {
            model = spec.container(declared);
            if (model.effect == .ends) {
                effect = .ends;
            } else if (body != null) {
                effect = .none;
                summary = body;
            } else effect = switch (model.effect) {
                .releases => .releases,
                else => if (model.kill != .none) .invalidates else .reads,
            };
        } else if (effect == .none or effect == .reads) summary = body;

        // `remap` to nothing is a free; `resize` to nothing too, to anything else it leaves the memory where it is.
        if (effect == .realloc and std.mem.endsWith(u8, declared, "remap") and r.constantArg(ops, 2, 0)) effect = .free;
        var resize_frees = false;
        if (effect == .resize) {
            const at = spec.lenArg(declared);
            resize_frees = r.constantArg(ops, at, 0);
            if (!resize_frees and !(at < n and ops[1 + at].kind == .constant)) try r.tally("dynamic_len", inst);
        }
        // The argument a free names is not a use but the end of one.
        const freed: ?usize = switch (effect) {
            .free => if (n > 1) (if (std.mem.endsWith(u8, declared, "rawFree") or std.mem.endsWith(u8, declared, "remap")) 1 else n - 1) else null,
            .realloc => if (n > 1) 1 else null,
            .resize => if (resize_frees and n > 1) 1 else null,
            else => null,
        };
        var derived: Val = .none;
        for (args, arg_tys, 0..) |a, aty, i| {
            const ends_here = freed != null and freed.? == i;
            if (!ends_here and effect != .query) try r.alive(st, inst, a, "passed to a call");
            if (r.ty.isPointer(aty)) {
                if (a.place) |pl| {
                    const content = try r.readPlace(st, pl);
                    if (!content.toks.isEmpty()) {
                        if (known == null)
                            return r.unsupported(inst, "a pointer to a linear value is passed to {s}, which is not analyzed", .{callee});
                        try r.use(st, inst, content, "borrowed");
                    }
                    // What the callee can read through the pointer must still exist.
                    if (!ends_here and effect != .query) try r.alive(st, inst, content, "reached through a pointer passed to a call");
                }
            }
            if (!a.toks.isEmpty() and !r.ty.isPointer(aty)) {
                try r.sink(st, inst, a, "passed on", callee);
                try r.noteTokenPassed(inst, a, i, known, body, declared);
            }
            derived.owners = try derived.owners.merge(r.arena, a.owners);
        }
        if (r.ty.kind(inst.ty) == .noreturn) {
            st.alive = false;
            return;
        }
        if (effect == .none and (known == null or body == null) and (r.ty.hasPointers(inst.ty) or anyPointerLike(r, arg_tys))) try r.tally("unknown_calls", inst);
        if (container_call and !model.modelled and body == null) try r.tally("unmodelled", inst);
        var sub: u32 = 0;
        var res = try r.fresh(st, inst, inst.ty, &sub);
        const text = try std.fmt.allocPrint(r.arena, "`{s}`", .{declared});

        // How much room the container has before and after, and whether this call can still reallocate.
        var room_proven = false;
        if (container_call) {
            room_proven = try r.room(st, ops, args, model);
        } else try r.dropCaps(st, args, arg_tys);
        const skip_kills = container_call and room_proven;

        switch (effect) {
            .none, .reads, .query, .container => {},
            .alloc, .realloc, .releases => {
                if (effect == .realloc) {
                    var moved: Set = .empty;
                    try r.endAllocations(st, inst, args[1], text, &moved);
                    res.moved = moved;
                }
                // From an arena: the allocation ends with it, or when it is reset.
                var region: PlaceId = dom.no_place;
                if (n > 0) for (args[0].owners.ids) |o| if (r.owners.items[o].kind == .object) {
                    region = r.owners.items[o].place;
                };
                const heap = try r.owner(.heap, inst.id, region);
                st.revive(heap);
                var owners = try Set.single(r.arena, heap);
                if (effect != .releases and n > 0) for (args[0].owners.ids) |o| {
                    // Only a buffer on the stack (a fixed-buffer allocator over a local array) outlives nothing else.
                    if (r.owners.items[o].kind == .local) owners = try owners.with(r.arena, o);
                };
                res.owners = owners;
                res.place = try r.places.root(r.arena, .heap, inst.id);
                if (effect == .releases) try r.invalidate(st, inst, args[0], text, false);
            },
            .handle => {
                const slot = try r.owner(.heap, inst.id, dom.no_place);
                st.revive(slot);
                res.owners = try Set.single(r.arena, slot);
            },
            .free, .resize => if (freed) |i| try r.endAllocations(st, inst, args[i], text, null),
            .swap => if (n >= 2) {
                // The two objects trade contents: what one held is now reached through the other.
                const pointee = r.pointeeOf(arg_tys[0]);
                var first = try r.load(st, inst, args[0], pointee);
                var second = try r.load(st, inst, args[1], pointee);
                first.owners = try r.moveStorage(st, first.owners, args[0]);
                second.owners = try r.moveStorage(st, second.owners, args[1]);
                try r.store(inst, st, args[0], second, pointee);
                try r.store(inst, st, args[1], first, pointee);
            },
            .allocator_of => if (n > 0) {
                const pl = args[0].place orelse args[0].src;
                if (pl) |p| {
                    const obj = try r.owner(.object, 0, p);
                    st.revive(obj);
                    res.owners = try (try r.readPlace(st, p)).owners.with(r.arena, obj);
                } else res.owners = args[0].owners;
            },
            .ends => if (n > 0) try r.invalidate(st, inst, args[0], text, true),
            .resets => if (n > 0) if (args[0].place orelse args[0].src) |pl| {
                const note_text = try std.fmt.allocPrint(r.arena, "{s} gives back what `{s}` handed out here", .{ text, r.placeName(pl) });
                try r.killRegion(st, pl, inst.loc, note_text);
            },
            .invalidates => if (n > 0) {
                if (!room_proven) try r.invalidate(st, inst, args[0], text, false);
                try r.storeArgs(st, inst, args);
                try r.learnBacking(st, args, arg_tys);
            },
        }
        if (container_call and n > 0) {
            // Elements that move or go away are stale even when the storage stays; a removal ends a pending entry.
            if (summary != null) {
                if (model.kill == .shift) try r.invalidate(st, inst, args[0], text, false);
                try r.learnBacking(st, args, arg_tys);
            }
            if (spec.removes(declared)) try r.dropPending(st, args[0]);
        }
        if (effect == .none or effect == .reads or (container_call and effect == .invalidates)) {
            if (summary) |s| try r.applySummary(st, inst, s, args, skip_kills, known != null and r.isLibrary(known.?));
            if (summary) |s| if (s.moves != 0) {
                var moved: Set = res.moved;
                for (args, 0..) |a, i| {
                    if (i < 64 and s.moves & (@as(u64, 1) << @intCast(i)) != 0) try r.endAllocations(st, inst, a, text, &moved);
                }
                res.moved = moved;
            };
            if (summary) |s| if (s.ret_same) |k| if (k < args.len) {
                res.place = args[k].place;
            };
            // A handle holds no pointer but names an allocation: a callee that returns one hands out a new owner.
            const hands_out = if (summary) |s| s.ret_alloc else false;
            if (r.ty.hasPointers(inst.ty) or hands_out) {
                var owners: Set = .empty;
                var allocates = false;
                if (summary) |s| {
                    allocates = s.ret_alloc;
                    for (s.ret) |ref| {
                        if (ref.param >= args.len) continue;
                        const given = args[ref.param];
                        if (!ref.stored and !ref.interior and given.place != null) {
                            // The pointer itself comes back (`iterator` hands out `self`): it is good while the
                            // object it points to exists, whatever happens to the storage the object holds.
                            owners = try owners.merge(r.arena, given.owners);
                            owners = try owners.with(r.arena, try r.owner(.object, 0, given.place.?));
                        } else owners = try owners.merge(r.arena, try r.dependsOn(st, inst, given, ref.path, ref.stored));
                    }
                    // What the documented model says the result points into, where the body's pointer arithmetic
                    // over one block (a hash map's header, metadata, keys and values) hides it.
                    if (container_call and (model.ptr != .none or model.adopts)) owners = try owners.merge(r.arena, try r.containerResult(st, inst, model, args, arg_tys));
                    // A handle (a value with owners but no pointers) names what the result points to.
                    for (args, arg_tys) |a, aty| if (!r.ty.hasPointers(aty) and !r.ty.isPointer(aty)) {
                        owners = try owners.merge(r.arena, a.owners);
                    };
                } else if (container_call and (model.ptr != .none or model.adopts)) {
                    owners = try r.containerResult(st, inst, model, args, arg_tys);
                } else {
                    // Nothing is known of the callee. Given an allocator, the result is an allocation from it
                    // (who received the allocator that made the slice); otherwise it may point into any argument,
                    // and a struct it returns may hold pointers into what an argument holds (a view, an iterator).
                    allocates = r.hasAllocator(arg_tys);
                    // A method the model knows hands out nothing of the container (`get` copies a value).
                    const known_value = container_call and model.modelled;
                    if (!allocates and !known_value) for (args, arg_tys) |a, aty| {
                        const holds = if (r.ty.pointee(aty)) |pt| r.ty.hasPointers(pt) else false;
                        var dep = a;
                        // A pointer into something that holds pointers (a context, a table) is the callee's business,
                        // unless the callee is known to hand out its storage.
                        if (holds and effect != .reads and r.topLevelPointer(inst.ty)) dep.place = null;
                        if (dep.place == null) dep.place = a.src;
                        owners = try owners.merge(r.arena, try r.dependsOn(st, inst, dep, &.{}, holds));
                        if (a.place) |pl| owners = try owners.merge(r.arena, try r.storageOwners(st, pl));
                    };
                }
                if (allocates) {
                    var region: PlaceId = dom.no_place;
                    var from: Val = .none;
                    for (args, arg_tys) |a, aty| if (r.ty.isAllocator(aty)) {
                        from = a;
                        for (a.owners.ids) |o| if (r.owners.items[o].kind == .object) {
                            region = r.owners.items[o].place;
                        };
                    };
                    const heap = try r.owner(.heap, inst.id, region);
                    st.revive(heap);
                    owners = try owners.with(r.arena, heap);
                    for (from.owners.ids) |o| if (r.owners.items[o].kind == .local) {
                        owners = try owners.with(r.arena, o);
                    };
                }
                res.owners = owners;
            }
        }
        r.set(inst, res);
    }

    /// What was read from the place `from` points to, as storage that moves along with the value: it is now reached
    /// through wherever the value is stored, and ends with the object it is stored in.
    fn moveStorage(r: *Run, st: *State, owners: Set, from: Val) Allocator.Error!Set {
        const pl = from.place orelse return owners;
        var out: Set = .empty;
        for (owners.ids) |o| {
            const rec = r.owners.items[o];
            if (rec.kind == .buffer and rec.place == pl) {
                // The read of this very call: the same storage under another name.
                const gone = try r.owner(.moved, rec.n, pl);
                st.revive(gone);
                out = try out.with(r.arena, gone);
            } else out = try out.with(r.arena, o);
        }
        return out;
    }

    /// Whether argument `at` is the constant `value`.
    fn constantArg(r: *Run, ops: []const schema.Operand, at: usize, value: u64) bool {
        if (at + 1 >= ops.len) return false;
        const o = ops[1 + at];
        if (o.kind != .constant) return false;
        const k = r.v.constant(o);
        return k.kind == .int and k.a == value;
    }

    /// A linear value went into a call: when the callee keeps it in memory the checker does not follow, that is a
    /// transfer. A callee of the project counted it in its own run; std and the callees without a body did not.
    fn noteTokenPassed(r: *Run, inst: *const Inst, a: Val, at: usize, known: ?Ref, body: ?Summary, declared: []const u8) Allocator.Error!void {
        if (std.mem.startsWith(u8, declared, "zv.")) return;
        const bit: u64 = if (at < 64) @as(u64, 1) << @intCast(at) else 0;
        var stored = true;
        if (body) |b| {
            stored = b.token_stores & bit != 0;
            if (stored) for (a.toks.ids) |t| if (r.param_of_tok.get(t)) |pi| if (pi < 64) {
                r.token_stored |= @as(u64, 1) << @intCast(pi);
            };
            if (!r.isLibrary(known.?)) return;
        }
        if (!stored) return;
        try r.tally("transfers", inst);
        for (a.toks.ids) |t| if (r.param_of_tok.get(t)) |pi| if (pi < 64) {
            r.token_stored |= @as(u64, 1) << @intCast(pi);
        };
    }

    /// A function of std: not part of what is being checked, so its own run is not counted.
    fn isLibrary(r: *Run, ref: Ref) bool {
        _ = r;
        const file = ref.pack.t.files[@backingInt(ref.func.file)];
        return std.mem.eql(u8, ref.pack.str(file.module), "std");
    }

    /// The owners of what the callee can read through a pointer to `pl`: allocations and storage that were stored there.
    fn storageOwners(r: *Run, st: *State, pl: PlaceId) Allocator.Error!Set {
        const content = try r.readPlace(st, pl);
        var out: Set = .empty;
        for (content.owners.ids) |o| switch (r.owners.items[o].kind) {
            .buffer, .heap, .moved => out = try out.with(r.arena, o),
            else => {},
        };
        return out;
    }

    /// The result of a container method from the documented model (no body in the packs).
    fn containerResult(r: *Run, st: *State, inst: *const Inst, model: spec.Model, args: []const Val, tys: []const schema.TypeId) Allocator.Error!Set {
        var out: Set = .empty;
        if (model.adopts) {
            for (args, tys) |a, t| if (!r.ty.isAllocator(t)) {
                out = try out.merge(r.arena, a.owners);
            };
            return out;
        }
        if (args.len == 0) return out;
        switch (model.ptr) {
            .none => {},
            .storage => {
                var a = args[0];
                if (a.place == null) a.place = a.src;
                out = try r.dependsOn(st, inst, a, &.{}, true);
            },
            .self => out = args[0].owners,
            .content => for (args, tys) |a, t| {
                out = try out.merge(r.arena, try r.withoutLocals(a.owners));
                if (r.ty.isPointer(t)) if (a.place) |pl| {
                    out = try out.merge(r.arena, try r.storageOwners(st, pl));
                };
            },
        }
        return out;
    }

    /// Updates what is known of the room in the container the first argument points to, and says whether the call
    /// is known not to reallocate.
    fn room(r: *Run, st: *State, ops: []const schema.Operand, args: []const Val, model: spec.Model) Allocator.Error!bool {
        if (args.len == 0) return false;
        const pl = args[0].place orelse args[0].src orelse return false;
        const cur = st.caps.get(pl) orelse Cap{};
        var next = cur;
        var proven = false;
        const count = r.countArg(ops);
        switch (model.count) {
            .keep => {},
            .drop => {
                try r.dropCapsAt(st, pl);
                return false;
            },
            .insert1 => {
                proven = cur.len_ub != null and cur.len_ub.? + 1 <= cur.cap_lb;
                next.len_ub = if (cur.len_ub) |l| l + 1 else null;
            },
            // The contract of these methods: the room is there, nothing is reallocated.
            .insert1_assume => {
                proven = true;
                next.len_ub = if (cur.len_ub) |l| l + 1 else null;
            },
            .many => next.len_ub = null,
            .many_assume => {
                proven = true;
                next.len_ub = null;
            },
            .total => if (count) |c| {
                proven = c <= cur.cap_lb;
                next.cap_lb = @max(cur.cap_lb, c);
            },
            .unused => if (count) |c| {
                proven = cur.len_ub != null and cur.len_ub.? + c <= cur.cap_lb;
                next.cap_lb = @max(cur.cap_lb, c);
            },
        }
        // Only a method that can reallocate has a reallocation to rule out.
        proven = proven and (model.kill == .grow or model.count == .insert1_assume or model.count == .many_assume);
        if (next.cap_lb == 0 and next.len_ub == null) {
            _ = st.caps.swapRemove(pl);
        } else try st.caps.put(r.arena, pl, next);
        return proven;
    }

    /// The constant in the last integer argument of a call (the count of `ensureTotalCapacity`), if it is one.
    fn countArg(r: *Run, ops: []const schema.Operand) ?u64 {
        var i = ops.len;
        while (i > 1) {
            i -= 1;
            if (r.ty.kind(r.operandType(ops[i])) != .int) continue;
            if (ops[i].kind != .constant) return null;
            const k = r.v.constant(ops[i]);
            return if (k.kind == .int) k.a else null;
        }
        return null;
    }

    /// A call that can write through a pointer to a container leaves nothing known of its room.
    fn dropCaps(r: *Run, st: *State, args: []const Val, tys: []const schema.TypeId) Allocator.Error!void {
        if (st.caps.count() == 0) return;
        for (args, tys) |a, t| if (r.ty.isPointer(t)) if (a.place) |pl| {
            if (!r.places.hasElem(pl)) try r.dropCapsAt(st, pl);
        };
    }

    fn dropCapsAt(r: *Run, st: *State, pl: PlaceId) Allocator.Error!void {
        var k: usize = 0;
        while (k < st.caps.count()) {
            if (r.places.overlaps(st.caps.keys()[k], pl)) st.caps.swapRemoveAt(k) else k += 1;
        }
    }

    /// A removal from the container at `obj` ends the entries that were put into it for the duration of a call.
    fn dropPending(r: *Run, st: *State, obj: Val) Allocator.Error!void {
        const pl = obj.place orelse obj.src orelse return;
        var k: usize = 0;
        while (k < st.pending.count()) {
            if (r.places.overlaps(st.pending.values()[k].place, pl)) st.pending.swapRemoveAt(k) else k += 1;
        }
    }

    /// A pointer, slice, or an optional or error union of one: the result itself points somewhere.
    fn topLevelPointer(r: *Run, ty: schema.TypeId) bool {
        return switch (r.ty.kind(ty)) {
            .pointer => true,
            .optional, .error_union => r.topLevelPointer(r.ty.rec(ty).child),
            else => false,
        };
    }

    /// A container that grew with an allocator holds memory from it: it ends with an arena, or the stack buffer
    /// of a fixed-buffer allocator.
    fn learnBacking(r: *Run, st: *State, args: []const Val, tys: []const schema.TypeId) Error!void {
        const pl = args[0].place orelse return;
        var owners: Set = .empty;
        for (args[1..], tys[1..]) |a, t| if (r.ty.isAllocator(t)) {
            for (a.owners.ids) |o| switch (r.owners.items[o].kind) {
                .object, .local => owners = try owners.with(r.arena, o),
                else => {},
            };
        };
        if (owners.isEmpty()) return;
        const slot = try r.places.child(r.arena, pl, dom.backing_step);
        const old = st.mem.get(slot) orelse Val.none;
        try st.mem.put(r.arena, slot, .{ .owners = try old.owners.merge(r.arena, owners) });
    }

    fn hasAllocator(r: *Run, tys: []const schema.TypeId) bool {
        for (tys) |t| if (r.ty.isAllocator(t)) return true;
        return false;
    }

    /// What a result that depends on argument `a` depends on: the argument's own owners and the storage behind
    /// `path` below the place it points to. A pointer to something that holds pointers (a container, an iterator)
    /// hands out what is stored in it, which does not live in the stack slot that holds the container.
    fn dependsOn(r: *Run, st: *State, inst: *const Inst, a: Val, path: []const u32, strip_locals: bool) Allocator.Error!Set {
        var out = a.owners;
        if (strip_locals) out = try r.withoutLocals(out);
        if (a.place orelse a.src) |pl| {
            var at = pl;
            for (path) |down| at = try r.places.child(r.arena, at, down);
            out = try out.with(r.arena, try r.bufferOwner(st, inst.id, at));
        }
        return out;
    }

    /// The owner of the storage that pointers read from `pl` at `site` point into; it is fresh, so alive.
    fn bufferOwner(r: *Run, st: *State, site: u32, pl: PlaceId) Allocator.Error!dom.Id {
        const buf = try r.owner(.buffer, site, pl);
        st.revive(buf);
        return buf;
    }

    fn anyPointerLike(r: *Run, tys: []const schema.TypeId) bool {
        for (tys) |t| if (r.ty.isPointer(t) or r.ty.hasPointers(t)) return true;
        return false;
    }

    /// What the callee does to what its arguments point into, from its summary.
    fn applySummary(r: *Run, st: *State, inst: *const Inst, s: Summary, args: []const Val, room_proven: bool, library: bool) Error!void {
        if (s.assumed) {
            // Only what the intersection over the paths needs: the parameters a recursive call hands on and frees.
            for (args, 0..) |a, i| {
                if (i >= 64 or s.frees & (@as(u64, 1) << @intCast(i)) == 0) continue;
                for (a.owners.ids) |o| {
                    const rec = r.owners.items[o];
                    if (rec.kind == .param and r.isParamItself(a, rec.n)) st.freed = try st.freed.with(r.arena, o);
                }
            }
            return;
        }
        for (s.kills) |k| {
            // A call that is known not to reallocate (room was made) moves nothing, whatever its body may do.
            if (room_proven and !k.ends) continue;
            if (k.param >= args.len) continue;
            const named = try r.targets(args[k.param], k.path);
            if (named.len == 0) {
                try r.tally("blind", inst);
                continue;
            }
            for (named) |place| {
                const text = try std.fmt.allocPrint(r.arena, "`{s}` {s} `{s}` here", .{ r.callName(inst), if (k.ends) "ends" else "invalidates pointers into", r.placeName(place) });
                try r.killPlace(st, place, k.ends, inst.loc, text);
                try r.noteKill(place, k.ends);
            }
        }
        for (s.stores) |put| {
            if (put.from >= args.len or put.into >= args.len) continue;
            // `getOrPut` hands back the slot for the caller to fill in, which is where a key is replaced by an owned
            // copy: the key it was given is not kept.
            if (library and put.from_path == null and std.mem.indexOf(u8, r.callName(inst), "getOrPut") != null) continue;
            var value: Val = .{ .owners = args[put.from].owners };
            if (put.from_path) |fp| {
                // The storage read below the parameter moved: it is now reached through where it was stored.
                value = .none;
                if (args[put.from].place orelse args[put.from].src) |base| {
                    var from_at = base;
                    for (fp) |down| from_at = try r.places.child(r.arena, from_at, down);
                    const kept = try r.owner(if (put.moves) .moved else .buffer, inst.id, from_at);
                    st.revive(kept);
                    value.owners = try Set.single(r.arena, kept);
                }
            }
            const dst = args[put.into];
            // An entry of a container that holds a pointer to a local may be taken out again before the return.
            if (library) {
                try r.escapesInto(st, inst, value, r.isLocalPtr(dst), "stored by the callee into memory that outlives it", dst.place);
            } else try r.escapes(st, inst, value, r.isLocalPtr(dst), "stored by the callee into memory that outlives it");
            if (dst.place) |base| {
                var at = base;
                for (put.path) |down| at = try r.places.child(r.arena, at, down);
                try r.noteStores(at, value);
                // What std's containers hold is not followed (an element is one of many); storage that moved is.
                if (r.isLocalPtr(dst) and (put.from_path != null or !library)) {
                    const old = st.mem.get(at) orelse Val.none;
                    try st.mem.put(r.arena, at, try old.join(r.arena, value));
                }
            }
        }
        for (args, 0..) |a, i| {
            if (i >= 64 or s.frees & (@as(u64, 1) << @intCast(i)) == 0) continue;
            try r.endAllocations(st, inst, a, r.callName(inst), null);
        }
    }

    fn callName(r: *Run, inst: *const Inst) []const u8 {
        return r.v.attrStr(inst, .callee) orelse "a call";
    }

    /// The places a callee's effect on `val` (and `path` below what it points to) applies to: the place itself when
    /// the checker knows it, else everything the owners of the value own. Empty when nothing can be named.
    fn targets(r: *Run, val: Val, path: []const u32) Allocator.Error![]const PlaceId {
        var out: std.ArrayList(PlaceId) = .empty;
        if (val.place orelse val.src) |base| {
            var at = base;
            for (path) |down| at = try r.places.child(r.arena, at, down);
            try out.append(r.arena, at);
            return out.items;
        }
        for (val.owners.ids) |o| {
            const rec = r.owners.items[o];
            const root: PlaceId = switch (rec.kind) {
                .local => try r.places.root(r.arena, .cell, rec.n),
                .param => try r.places.root(r.arena, .param, rec.n),
                .heap => try r.places.root(r.arena, .heap, rec.n),
                // The storage a pointer was read from is not a place of its own: nothing to name.
                .buffer, .object, .moved => continue,
            };
            if (root == dom.no_place) continue;
            if (std.mem.indexOfScalar(PlaceId, out.items, root) == null) try out.append(r.arena, root);
        }
        return out.items;
    }

    /// For the summary: the call ended or invalidated pointers below a parameter.
    fn noteKill(r: *Run, pl: PlaceId, ends: bool) Allocator.Error!void {
        if (r.places.rec(pl).kind != .param) return;
        const path = try r.places.path(r.arena, pl);
        const n = r.places.rec(pl).n;
        for (r.kills.items) |k| if (k.param == n and k.ends == ends and std.mem.eql(u32, k.path, path)) return;
        try r.kills.append(r.arena, .{ .param = n, .path = path, .ends = ends });
    }

    /// An operation on the object `obj` points to that makes pointers into it stale (`ends`: the object itself
    /// is gone too).
    fn invalidate(r: *Run, st: *State, inst: *const Inst, obj: Val, what: []const u8, ends: bool) Error!void {
        const places = try r.targets(obj, &.{});
        if (places.len == 0) {
            try r.tally("blind", inst);
            return;
        }
        for (places) |pl| try r.invalidateAt(st, inst, pl, what, ends);
    }

    fn invalidateAt(r: *Run, st: *State, inst: *const Inst, pl: PlaceId, what: []const u8, ends: bool) Error!void {
        if (!isInsertion(r.callName(inst))) {
            var k: usize = 0;
            while (k < st.pending.count()) {
                if (r.places.overlaps(st.pending.values()[k].place, pl)) st.pending.swapRemoveAt(k) else k += 1;
            }
        }
        // The object itself must still exist.
        const owner_id = try r.owner(.object, 0, pl);
        if (st.dead.contains(owner_id)) {
            var items: std.ArrayList(diag.Note) = .empty;
            if (st.dead.get(owner_id)) |e| try items.append(r.arena, .{ .loc = e.loc, .text = e.text });
            try r.report(st, .use_after_free, inst.loc, try r.noteList(items.items), "`{s}` is used after it was deinitialized", .{r.placeName(pl)});
        }
        const text = try std.fmt.allocPrint(r.arena, "{s} {s} `{s}` here", .{ what, if (ends) "ends" else "invalidates pointers into", r.placeName(pl) });
        try r.killPlace(st, pl, ends, inst.loc, text);
        try r.noteKill(pl, ends);
    }

    /// Ends the buffers (and, for `ends`, the objects) at and below `pl`, and those above it that hold it. An object
    /// that ends takes the allocations it holds with it (a list built by `fromOwnedSlice`).
    fn killPlace(r: *Run, st: *State, pl: PlaceId, ends: bool, loc: schema.LocId, text: []const u8) Error!void {
        for (r.owners.items, 0..) |o, id| {
            const hit = switch (o.kind) {
                .buffer, .moved => r.places.overlaps(o.place, pl),
                .object => if (ends) r.places.contains(pl, o.place) else false,
                .heap => ends and o.place != dom.no_place and r.places.contains(pl, o.place),
                else => false,
            };
            if (!hit) continue;
            try st.die(r.arena, @intCast(id), .{ .loc = loc, .text = text, .trail = st.trail });
        }
        if (ends) {
            const obj = try r.owner(.object, 0, pl);
            try st.die(r.arena, obj, .{ .loc = loc, .text = text, .trail = st.trail });
            for ((try r.readPlace(st, pl)).owners.ids) |o| {
                const rec = r.owners.items[o];
                switch (rec.kind) {
                    .heap => try st.die(r.arena, o, .{ .loc = loc, .text = text, .trail = st.trail }),
                    // Storage that moved into the object goes with it.
                    .moved => if (!r.places.overlaps(rec.place, pl)) {
                        try r.killPlace(st, rec.place, false, loc, text);
                        try r.noteKill(rec.place, false);
                    },
                    else => {},
                }
            }
        }
    }

    /// Ends what the arena at `pl` handed out, not the arena.
    fn killRegion(r: *Run, st: *State, pl: PlaceId, loc: schema.LocId, text: []const u8) Error!void {
        for (r.owners.items, 0..) |o, id| {
            if (o.kind != .heap or o.place == dom.no_place or !r.places.contains(pl, o.place)) continue;
            try st.die(r.arena, @intCast(id), .{ .loc = loc, .text = text, .trail = st.trail });
        }
    }

    /// `free(x)`: the allocations `x` points into end, and the storage `x` was read from with them; a second free
    /// is a finding. With `deferred`, nothing ends yet: the owners that do when the call succeeds are collected
    /// (`realloc` on an error that came back leaves the old memory alone).
    fn endAllocations(r: *Run, st: *State, inst: *const Inst, val: Val, what: []const u8, deferred: ?*Set) Error!void {
        // One of many (an element read out of an array): the site names them all, and only one was freed.
        if (val.many) return;
        for (val.owners.ids) |o| {
            const rec = r.owners.items[o];
            switch (rec.kind) {
                .heap => {
                    if (st.dead.contains(o)) {
                        var items: std.ArrayList(diag.Note) = .empty;
                        if (st.dead.get(o)) |e| try items.append(r.arena, .{ .loc = e.loc, .text = e.text });
                        try r.report(st, .double_free, inst.loc, try r.noteList(items.items), "memory is freed twice", .{});
                    }
                    try r.endOne(st, inst, o, what, deferred);
                },
                .param => if (r.isParamItself(val, rec.n)) {
                    if (deferred == null) st.freed = try st.freed.with(r.arena, o);
                    try r.endOne(st, inst, o, what, deferred);
                },
                .buffer, .moved => {
                    try r.noteKill(rec.place, false);
                    try r.endOne(st, inst, o, what, deferred);
                },
                else => {},
            }
        }
    }

    fn endOne(r: *Run, st: *State, inst: *const Inst, o: dom.Id, what: []const u8, deferred: ?*Set) Error!void {
        const text = try std.fmt.allocPrint(r.arena, "first freed here by {s}", .{what});
        const event: Event = .{ .loc = inst.loc, .text = text, .trail = st.trail };
        if (deferred) |collected| {
            collected.* = try collected.with(r.arena, o);
            try r.moved_events.put(r.arena, o, event);
            return;
        }
        try r.endNow(st, o, event);
    }

    fn endNow(r: *Run, st: *State, o: dom.Id, event: Event) Error!void {
        const rec = r.owners.items[o];
        if (rec.kind == .buffer or rec.kind == .moved) {
            // The storage went: so did every pointer read from it.
            try r.killPlace(st, rec.place, false, event.loc, event.text);
        } else try st.die(r.arena, o, event);
    }

    /// The payload exists: what the call that made it moved is gone.
    fn present(r: *Run, st: *State, p: Pred) Error!void {
        var subject = p.subject;
        if (p.ptr) subject = if (subject.place) |pl| try r.readPlace(st, pl) else .none;
        try r.applyMoved(st, subject);
    }

    fn applyMoved(r: *Run, st: *State, val: Val) Error!void {
        for (val.moved.ids) |o| {
            const event = r.moved_events.get(o) orelse continue;
            try r.endNow(st, o, event);
        }
    }

    /// Whether `val` is parameter `n`, or all that is known of it is that it comes from nothing else: freeing it
    /// frees what the caller passed.
    fn isParamItself(r: *Run, val: Val, n: u32) bool {
        if (val.place) |pl| return r.places.rec(pl).kind == .param and r.places.rec(pl).n == n;
        var params: usize = 0;
        for (val.owners.ids) |o| if (r.owners.items[o].kind == .param) {
            params += 1;
        };
        return params == 1;
    }

    /// The arguments of a container operation flow into the container: a pointer to a local that goes into
    /// memory the caller owns outlives the local.
    fn storeArgs(r: *Run, st: *State, inst: *const Inst, args: []const Val) Error!void {
        // `appendSlice` and its kin copy the elements, not the slice they are read from.
        const callee = r.callName(inst);
        // `getOrPut` hands back the slot for the caller to fill in, which is where a key is replaced by an owned copy.
        if (std.mem.indexOf(u8, callee, "getOrPut") != null) return;
        if (std.mem.indexOf(u8, callee, "Slice") != null or std.mem.indexOf(u8, callee, "NTimes") != null or std.mem.indexOf(u8, callee, "Many") != null) return;
        const self_val = args[0];
        const into_local = r.isLocalPtr(self_val);
        for (args[1..]) |a| {
            try r.escapesInto(st, inst, a, into_local, "stored into a container that outlives it", self_val.place);
            if (self_val.place) |pl| try r.noteStores(pl, a);
        }
    }

    /// A pointer to a stack slot must not end up where the function's caller can reach it.
    fn escapes(r: *Run, st: *State, inst: *const Inst, val: Val, into_local: bool, how: []const u8) Error!void {
        return r.escapesInto(st, inst, val, into_local, how, null);
    }

    /// With a `container` place the escape is only pending: removing the entry again clears it.
    fn escapesInto(r: *Run, st: *State, inst: *const Inst, val: Val, into_local: bool, how: []const u8, container: ?PlaceId) Error!void {
        if (into_local) return;
        for (val.owners.ids) |o| {
            const rec = r.owners.items[o];
            if (rec.kind != .local) continue;
            if (container) |pl| {
                const gop = try st.pending.getOrPut(r.arena, o);
                if (!gop.found_existing) gop.value_ptr.* = .{ .loc = inst.loc, .place = pl, .site = inst.id };
                continue;
            }
            const slot = r.names.get(rec.n) orelse "a local";
            try r.report(st, .escape_local, inst.loc, &.{}, "a pointer to `{s}` is {s}", .{ slot, how });
        }
    }

    fn placeName(r: *Run, pl: PlaceId) []const u8 {
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
};
