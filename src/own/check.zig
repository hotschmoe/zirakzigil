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
};

pub const Kill = struct { param: u32, path: []const u32, ends: bool };

/// Parameter `from` (or something it points to) is stored at `path` below what parameter `into` points to.
pub const Store = struct { from: u32, into: u32, path: []const u32 };

/// The result depends on parameter `param` (`stored`: on what was read out of it, not the parameter itself),
/// at `path` below what it points to.
pub const RetRef = struct { param: u32, path: []const u32, stored: bool };

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

pub const Program = struct {
    gpa: Allocator,
    /// Holds the results: lives as long as the program.
    arena: Allocator,
    funcs: std.StringHashMapUnmanaged(Ref) = .empty,
    results: std.StringHashMapUnmanaged(*Result) = .empty,
    /// Functions being analyzed: a call back into one of them (recursion) is modeled, not read.
    busy: std.StringHashMapUnmanaged(void) = .empty,
    /// Effects the project gives its own functions in an `ownership` manifest, by declared name.
    annotations: std.StringHashMapUnmanaged(spec.Effect) = .empty,
    /// Names of parameters, which the packs do not carry; set by whoever has the sources.
    param_names: ?ParamNames = null,

    pub fn init(gpa: Allocator, arena: Allocator, packs: []const *const schema.Pack) Allocator.Error!Program {
        var p: Program = .{ .gpa = gpa, .arena = arena };
        for (packs) |pack| for (pack.t.funcs) |f| {
            const gop = try p.funcs.getOrPut(arena, pack.str(f.fqn));
            if (!gop.found_existing) gop.value_ptr.* = .{ .pack = pack, .func = f };
        };
        return p;
    }

    pub fn analyze(p: *Program, ref: Ref) Allocator.Error!*const Result {
        const key = try std.fmt.allocPrint(p.arena, "{s}#{x}", .{ ref.pack.str(ref.func.fqn), ref.func.id });
        if (p.results.get(key)) |done| return done;
        try p.busy.put(p.arena, key, {});
        defer _ = p.busy.remove(key);
        var scratch: std.heap.ArenaAllocator = .init(p.gpa);
        defer scratch.deinit();
        var run: Run = try .init(p, scratch.allocator(), ref);
        const out = try p.arena.create(Result);
        out.* = try run.execute();
        try p.results.put(p.arena, key, out);
        return out;
    }

    /// What a call to `ref` does, read from its body; null while it is being analyzed (recursion) or when its
    /// run was cut short.
    fn summaryOf(p: *Program, ref: Ref) Allocator.Error!?Summary {
        const key = try std.fmt.allocPrint(p.arena, "{s}#{x}", .{ ref.pack.str(ref.func.fqn), ref.func.id });
        if (p.busy.contains(key)) return null;
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
};

const Owner = struct { kind: OwnerKind, n: u32, place: PlaceId };

const Event = struct { loc: schema.LocId, text: []const u8, trail: ?*const diag.Trail };

const Pending = struct { loc: schema.LocId, place: PlaceId, site: u32 };

const Pred = struct { subject: Val, ptr: bool, present_if_true: bool };

const Trail = diag.Trail;

const State = struct {
    alive: bool = true,
    mem: std.AutoArrayHashMapUnmanaged(PlaceId, Val) = .empty,
    live: Set = .empty,
    ended: Set = .empty,
    /// Owners that no longer exist, and why (the first cause on this path).
    dead: std.AutoArrayHashMapUnmanaged(dom.Id, Event) = .empty,
    /// Stack slots whose address went into a container that outlives them: fine if the entry is removed before
    /// the function returns (a registry for the duration of a call).
    pending: std.AutoArrayHashMapUnmanaged(dom.Id, Pending) = .empty,
    trail: ?*const Trail = null,

    fn clone(s: State, arena: Allocator) Allocator.Error!State {
        var c = s;
        c.mem = try s.mem.clone(arena);
        c.dead = try s.dead.clone(arena);
        c.pending = try s.pending.clone(arena);
        return c;
    }

    /// The state after either of two paths. `entry` is the trail where they split.
    fn join(a: State, arena: Allocator, b: State, entry: ?*const Trail) Allocator.Error!State {
        if (!a.alive) return b;
        if (!b.alive) return a;
        var out = try a.clone(arena);
        out.trail = entry;
        out.live = try a.live.merge(arena, b.live);
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
    frees: u64 = 0,
    stores: std.ArrayList(Store) = .empty,
    ret_refs: std.ArrayList(RetRef) = .empty,
    ret_alloc: bool = false,
    blocks: std.AutoHashMapUnmanaged(u32, *BlockCtx) = .empty,
    loops: std.AutoHashMapUnmanaged(u32, *LoopCtx) = .empty,
    preds: std.AutoHashMapUnmanaged(u32, Pred) = .empty,
    ends: std.AutoHashMapUnmanaged(dom.Id, Event) = .empty,
    diags: std.ArrayList(diag.Diag) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    stats: Stats = .{},
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
            .summary = .{ .complete = complete, .ret = try r.persistRefs(arena), .ret_alloc = r.ret_alloc, .kills = kills, .frees = r.frees, .stores = try r.persistStores(arena) },
        };
    }

    fn persistStores(r: *Run, arena: Allocator) Allocator.Error![]const Store {
        const out = try arena.alloc(Store, r.stores.items.len);
        for (out, r.stores.items) |*slot, s| slot.* = .{ .from = s.from, .into = s.into, .path = try arena.dupe(u32, s.path) };
        return out;
    }

    fn persistRefs(r: *Run, arena: Allocator) Allocator.Error![]const RetRef {
        const out = try arena.alloc(RetRef, r.ret_refs.items.len);
        for (out, r.ret_refs.items) |*slot, ref| slot.* = .{ .param = ref.param, .path = try arena.dupe(u32, ref.path), .stored = ref.stored };
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
                r.set(inst, .{ .place = cell, .owners = try Set.single(r.arena, local), .off = 0 });
            },
            .store, .store_safe => try r.store(inst, st, r.arg(inst, 0), r.arg(inst, 1), r.operandType(r.v.ops(inst)[1])),
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
            .tag_name, .error_name => r.set(inst, .none),
            .set_union_tag, .err_return_trace => {
                if (inst.tag == .err_return_trace) r.set(inst, .none);
            },

            .field_parent_ptr => r.set(inst, .{ .owners = r.arg(inst, 0).owners }),
            .assembly => return r.unsupported(inst, "inline assembly", .{}),
            .loop_switch_br, .switch_dispatch => return r.unsupported(inst, "a labeled switch loop", .{}),

            else => {
                switch (r.ty.kind(inst.ty)) {
                    .int, .bool, .float, .void, .noreturn, .@"enum", .error_set, .comptime_int, .comptime_float, .undefined, .null, .type, .enum_literal, .vector => r.set(inst, .none),
                    else => return r.unsupported(inst, "instruction {t} of type {s}", .{ inst.tag, r.ty.name(inst.ty) }),
                }
            },
        }
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
        for (val.toks.ids) |t| try r.tok_names.put(r.arena, t, given orelse try std.fmt.allocPrint(r.arena, "parameter {d}", .{i}));
        const param_owner = try r.owner(.param, i, dom.no_place);
        if (r.ty.isPointer(inst.ty)) {
            val.place = try r.places.root(r.arena, .param, i);
            val.off = 0;
            val.owners = try val.owners.with(r.arena, param_owner);
        } else if (r.ty.hasPointers(inst.ty)) {
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
            if (pred) |p| if (!p.present_if_true) try r.absent(&s, p);
            try r.exec(r.v.insts(bodies[0]), &s);
        }
        if (take_else) {
            var s = try st.clone(r.arena);
            if (decision) s.trail = try r.push(st.trail, inst.loc, .@"else");
            if (pred) |p| if (p.present_if_true) try r.absent(&s, p);
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
        r.set(inst, eu);
    }

    fn store(r: *Run, inst: *const Inst, st: *State, ptr: Val, val: Val, val_ty: schema.TypeId) Error!void {
        _ = val_ty;
        try r.alive(st, inst, ptr, "write");
        try r.escapes(st, inst, val, r.isLocalPtr(ptr), "stored into memory that outlives it");
        if (ptr.place) |pl| {
            try r.objectAlive(st, inst, pl);
            const kind = r.places.rec(pl).kind;
            if (kind == .cell) for (val.toks.ids) |t| {
                const gop = try r.tok_cells.getOrPut(r.arena, t);
                if (!gop.found_existing) gop.value_ptr.* = r.places.rec(pl).n;
            };
            if (kind != .cell and !val.toks.isEmpty()) {
                r.stats.transfers += 1;
                try r.sink(st, inst, val, "stored into memory the caller owns", "");
            }
            try r.noteStores(pl, val);
            try r.writePlace(st, pl, val);
            // A new value in the place of an object (`arena = .init(gpa)`) starts it afresh.
            for (r.owners.items, 0..) |o, id| {
                if (o.kind == .object and r.places.contains(pl, o.place)) st.revive(@intCast(id));
            }
        } else if (!val.toks.isEmpty()) {
            r.stats.transfers += 1;
            try r.sink(st, inst, val, "stored into memory the checker does not track", "");
        }
    }

    /// For the summary: a value that came in through a parameter is stored below another parameter.
    fn noteStores(r: *Run, into: PlaceId, val: Val) Allocator.Error!void {
        const root = r.places.rec(into);
        if (root.kind != .param) return;
        for (val.owners.ids) |o| {
            const rec = r.owners.items[o];
            if (rec.kind != .param or rec.n == root.n) continue;
            const path = try r.places.path(r.arena, into);
            var known = false;
            for (r.stores.items) |q| known = known or (q.from == rec.n and q.into == root.n and std.mem.eql(u32, q.path, path));
            if (!known) try r.stores.append(r.arena, .{ .from = rec.n, .into = root.n, .path = path });
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
            if (ptr.place) |pl| if (r.topLevelPointer(ty)) {
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
        try r.alive(st, inst, out, "read");
        return out;
    }

    fn isInsertion(callee: []const u8) bool {
        const dot = std.mem.lastIndexOfScalar(u8, callee, '.') orelse 0;
        const method = callee[if (dot == 0) 0 else dot + 1 ..];
        const stores = [_][]const u8{ "append", "put", "insert", "add", "push", "enqueue", "getOrPut", "ensure", "resize", "reserve", "expand" };
        for (stores) |s| if (std.mem.startsWith(u8, method, s)) return true;
        return false;
    }

    fn noteRet(r: *Run, ref: RetRef) Allocator.Error!void {
        for (r.ret_refs.items) |q| {
            if (q.param == ref.param and q.stored == ref.stored and std.mem.eql(u32, q.path, ref.path)) return;
        }
        try r.ret_refs.append(r.arena, ref);
    }

    fn ret(r: *Run, inst: *const Inst, st: *State, val: Val) Error!void {
        try r.use(st, inst, val, "returned");
        for (val.owners.ids) |o| {
            const rec = r.owners.items[o];
            switch (rec.kind) {
                .local => {
                    const slot = r.names.get(rec.n) orelse "a local";
                    try r.report(st, .escape_local, inst.loc, &.{}, "a pointer to `{s}` is returned, but `{s}` ends with the function", .{ slot, slot });
                },
                .param => try r.noteRet(.{ .param = rec.n, .path = &.{}, .stored = false }),
                .buffer, .object => {
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
        const known: ?Ref = r.prog.funcs.get(callee);
        const effect: spec.Effect = r.prog.annotations.get(declared) orelse spec.lookup(declared);
        const summary: ?Summary = if (known) |ref| try r.prog.summaryOf(ref) else null;

        const n = ops.len - 1;
        const args = try r.arena.alloc(Val, n);
        const arg_tys = try r.arena.alloc(schema.TypeId, n);
        for (args, arg_tys, ops[1..]) |*a, *t, o| {
            a.* = r.operand(o);
            t.* = r.operandType(o);
        }
        // The argument a free names is not a use but the end of one.
        const freed: ?usize = switch (effect) {
            .free => if (n > 1) n - 1 else null,
            .realloc => if (n > 1) 1 else null,
            else => null,
        };
        var derived: Val = .none;
        for (args, arg_tys, 0..) |a, aty, i| {
            if (freed == null or freed.? != i) try r.alive(st, inst, a, "passed to a call");
            if (r.ty.isPointer(aty)) {
                if (a.place) |pl| {
                    const content = try r.readPlace(st, pl);
                    if (!content.toks.isEmpty()) {
                        if (known == null)
                            return r.unsupported(inst, "a pointer to a linear value is passed to {s}, which is not analyzed", .{callee});
                        try r.use(st, inst, content, "borrowed");
                    }
                }
            }
            if (!a.toks.isEmpty() and !r.ty.isPointer(aty)) try r.sink(st, inst, a, "passed on", callee);
            derived.owners = try derived.owners.merge(r.arena, a.owners);
        }
        if (r.ty.kind(inst.ty) == .noreturn) {
            st.alive = false;
            return;
        }
        if (known == null and effect == .none and (r.ty.hasPointers(inst.ty) or anyPointerLike(r, arg_tys))) r.stats.unknown_calls += 1;

        var sub: u32 = 0;
        var res = try r.fresh(st, inst, inst.ty, &sub);
        const text = try std.fmt.allocPrint(r.arena, "`{s}`", .{declared});
        switch (effect) {
            .none, .reads => {},
            .alloc, .realloc, .releases => {
                if (effect == .realloc) try r.freeAllocations(st, inst, args[1], text);
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
            .free => if (freed) |i| try r.freeAllocations(st, inst, args[i], text),
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
                try r.invalidate(st, inst, args[0], text, false);
                try r.storeArgs(st, inst, args);
                try r.learnBacking(st, args, arg_tys);
            },
        }
        if (effect == .none or effect == .reads) {
            if (summary) |s| try r.applySummary(st, inst, s, args);
            if (r.ty.hasPointers(inst.ty)) {
                var owners: Set = .empty;
                var allocates = false;
                if (summary) |s| {
                    allocates = s.ret_alloc;
                    for (s.ret) |ref| {
                        if (ref.param >= args.len) continue;
                        owners = try owners.merge(r.arena, try r.dependsOn(st, inst, args[ref.param], ref.path, ref.stored));
                    }
                    // A handle (a value with owners but no pointers) names what the result points to.
                    for (args, arg_tys) |a, aty| if (!r.ty.hasPointers(aty) and !r.ty.isPointer(aty)) {
                        owners = try owners.merge(r.arena, a.owners);
                    };
                } else {
                    // Nothing is known of the callee. Given an allocator, the result is an allocation from it
                    // (who received the allocator that made the slice); otherwise it may point into any argument.
                    allocates = r.hasAllocator(arg_tys);
                    if (!allocates) for (args, arg_tys) |a, aty| {
                        const holds = if (r.ty.pointee(aty)) |pt| r.ty.hasPointers(pt) else false;
                        if (!r.topLevelPointer(inst.ty)) {
                            // A struct returned by value is a copy of what was stored: its pointers lead elsewhere.
                            if (!holds) owners = try owners.merge(r.arena, a.owners);
                            continue;
                        }
                        // A pointer into something that holds pointers (a context, a table) is the callee's business;
                        // a container of std is known to hand out pointers into its buffer.
                        var dep = a;
                        if (holds and effect != .reads) dep.place = null;
                        // A container method that takes the container by value (`getPtr`) still hands out its buffer.
                        if (effect == .reads and dep.place == null) dep.place = a.src;
                        owners = try owners.merge(r.arena, try r.dependsOn(st, inst, dep, &.{}, holds));
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
        if (a.place) |pl| {
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
    fn applySummary(r: *Run, st: *State, inst: *const Inst, s: Summary, args: []const Val) Error!void {
        for (s.kills) |k| {
            if (k.param >= args.len) continue;
            var place = args[k.param].place orelse args[k.param].src orelse continue;
            for (k.path) |down| place = try r.places.child(r.arena, place, down);
            const text = try std.fmt.allocPrint(r.arena, "`{s}` {s} `{s}` here", .{ r.callName(inst), if (k.ends) "ends" else "invalidates pointers into", r.placeName(place) });
            try r.killPlace(st, place, k.ends, inst.loc, text);
        }
        for (s.stores) |put| {
            if (put.from >= args.len or put.into >= args.len) continue;
            const value: Val = .{ .owners = args[put.from].owners };
            const dst = args[put.into];
            try r.escapes(st, inst, value, r.isLocalPtr(dst), "stored by the callee into memory that outlives it");
            if (dst.place) |base| if (r.isLocalPtr(dst)) {
                var at = base;
                for (put.path) |down| at = try r.places.child(r.arena, at, down);
                const old = st.mem.get(at) orelse Val.none;
                try st.mem.put(r.arena, at, try old.join(r.arena, value));
            };
        }
        for (args, 0..) |a, i| {
            if (i >= 64 or s.frees & (@as(u64, 1) << @intCast(i)) == 0) continue;
            try r.freeAllocations(st, inst, a, r.callName(inst));
        }
    }

    fn callName(r: *Run, inst: *const Inst) []const u8 {
        return r.v.attrStr(inst, .callee) orelse "a call";
    }

    /// An operation on the object `obj` points to that makes pointers into it stale (`ends`: the object itself
    /// is gone too).
    fn invalidate(r: *Run, st: *State, inst: *const Inst, obj: Val, what: []const u8, ends: bool) Error!void {
        const pl = obj.place orelse obj.src orelse return;
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
        if (r.places.rec(pl).kind == .param) {
            const path = try r.places.path(r.arena, pl);
            try r.kills.append(r.arena, .{ .param = r.places.rec(pl).n, .path = path, .ends = ends });
        }
    }

    /// Ends the buffers (and, for `ends`, the objects) at and below `pl`, and those above it that hold it.
    fn killPlace(r: *Run, st: *State, pl: PlaceId, ends: bool, loc: schema.LocId, text: []const u8) Error!void {
        for (r.owners.items, 0..) |o, id| {
            const hit = switch (o.kind) {
                .buffer => r.places.overlaps(o.place, pl),
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
        }
    }

    /// Ends what the arena at `pl` handed out, not the arena.
    fn killRegion(r: *Run, st: *State, pl: PlaceId, loc: schema.LocId, text: []const u8) Error!void {
        for (r.owners.items, 0..) |o, id| {
            if (o.kind != .heap or o.place == dom.no_place or !r.places.contains(pl, o.place)) continue;
            try st.die(r.arena, @intCast(id), .{ .loc = loc, .text = text, .trail = st.trail });
        }
    }

    /// `free(x)`: the allocations `x` points into end; a second free is a finding.
    fn freeAllocations(r: *Run, st: *State, inst: *const Inst, val: Val, what: []const u8) Error!void {
        for (val.owners.ids) |o| {
            const rec = r.owners.items[o];
            switch (rec.kind) {
                .heap => {
                    if (st.dead.contains(o)) {
                        var items: std.ArrayList(diag.Note) = .empty;
                        if (st.dead.get(o)) |e| try items.append(r.arena, .{ .loc = e.loc, .text = e.text });
                        try r.report(st, .double_free, inst.loc, try r.noteList(items.items), "memory is freed twice", .{});
                    }
                    const text = try std.fmt.allocPrint(r.arena, "first freed here by {s}", .{what});
                    try st.die(r.arena, o, .{ .loc = inst.loc, .text = text, .trail = st.trail });
                },
                .param => if (r.isParamItself(val, rec.n)) {
                    if (rec.n < 64) r.frees |= @as(u64, 1) << @intCast(rec.n);
                    const text = try std.fmt.allocPrint(r.arena, "freed here by {s}", .{what});
                    try st.die(r.arena, o, .{ .loc = inst.loc, .text = text, .trail = st.trail });
                },
                else => {},
            }
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
