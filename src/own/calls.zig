//! Calls: what the callee's effect (the table of `spec.zig` for allocator primitives and documented container
//! semantics, the summary of its body for everything the packs hold) does to the identities of the caller.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zv_air = @import("zv_air");
const schema = zv_air.schema;
const spec = @import("spec.zig");
const dom = @import("domain.zig");
const diag = @import("diag.zig");
const check = @import("check.zig");
const Set = dom.Set;
const Val = dom.Val;
const PlaceId = dom.PlaceId;
const Inst = schema.Inst;
const Run = check.Run;
const State = check.State;
const Summary = check.Summary;
const Slot = check.Slot;
const Desc = check.Desc;
const Event = check.Event;
const Error = check.Error;
const Ref = check.Ref;

pub fn call(r: *Run, inst: *const Inst, st: *State) Error!void {
    // A call through a function pointer is a call to a function nothing is known of.
    const direct = r.v.attrStr(inst, .callee);
    const callee = direct orelse "(call through a function pointer)";
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
    const known: ?Ref = if (direct != null) r.prog.resolve(callee, r.pack, arg_tys) else null;
    var effect: spec.Effect = if (direct != null) r.prog.annotations.get(declared) orelse spec.lookup(declared) else .none;
    const body: ?Summary = if (known) |ref| try r.prog.summaryOf(ref) else null;

    // A container method of std is read from its body when the pack has one; the documented model covers the rest.
    var model: spec.Model = .{};
    var summary: ?Summary = null;
    const container_call = effect == .container;
    if (container_call) {
        model = spec.container(declared);
        summary = body;
        if (model.effect == .ends) {
            effect = .ends;
        } else if (model.effect == .releases and body == null) {
            effect = .releases;
        } else if (body != null) {
            effect = .none;
        } else effect = .container;
    } else if (effect == .none or effect == .reads) summary = body;

    // `remap` to nothing is a free; `resize` to nothing too, to anything else it leaves the memory where it is.
    if (effect == .realloc and std.mem.endsWith(u8, declared, "remap") and constantArg(r, ops, 2, 0)) effect = .free;
    var resize_frees = false;
    if (effect == .resize) {
        const at = spec.lenArg(declared);
        resize_frees = constantArg(r, ops, at, 0);
        if (!resize_frees and !(at < n and ops[1 + at].kind == .constant)) try r.tally("dynamic_len", inst);
    }
    // The argument a free names is not a use but the end of one.
    const freed: ?usize = switch (effect) {
        .free, .cancel => if (n > 1) (if (std.mem.endsWith(u8, declared, "rawFree") or std.mem.endsWith(u8, declared, "remap")) 1 else n - 1) else if (n == 1 and std.mem.startsWith(u8, declared, "heap.memory_pool.")) 0 else null,
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
                const content = try r.peekFlat(st, pl);
                if (!content.toks.isEmpty()) {
                    if (known == null)
                        return r.unsupported(inst, "a pointer to a linear value is passed to {s}, which is not analyzed", .{callee});
                    try r.use(st, inst, content, "borrowed");
                }
            }
        }
        if (!a.toks.isEmpty() and !r.ty.isPointer(aty)) {
            try r.sink(st, inst, a, "passed on", callee);
            try noteTokenPassed(r, inst, a, i, known, body, declared);
        }
        derived.ids = try derived.ids.merge(r.arena, a.ids);
    }
    if (r.ty.kind(inst.ty) == .noreturn) {
        st.alive = false;
        return;
    }
    if (effect == .none and (known == null or body == null) and (r.ty.hasPointers(inst.ty) or anyPointerLike(r, arg_tys))) try r.tally("unknown_calls", inst);
    if (container_call and !model.modelled and body == null) try r.tally("unmodelled", inst);
    // The state to take on the error path: a growth that failed changed nothing.
    if (r.ty.kind(inst.ty) == .error_union and (container_call or (summary != null and known != null and isLibrary(known.?) and summary.?.kills.len != 0))) {
        var tokens = false;
        for (args) |a| tokens = tokens or !a.toks.isEmpty();
        if (!tokens) try r.pre_state.put(r.arena, inst.id, try st.clone(r.arena));
    }
    var sub: u32 = 0;
    var res = try freshTokens(r, st, inst, &sub);
    const text = try std.fmt.allocPrint(r.arena, "`{s}`", .{declared});
    if (summary == null) try forgetScalars(r, st, args, arg_tys);

    // How much room the container has before and after, and whether this call can still reallocate.
    var room: Room = .{};
    if (container_call) {
        room = try roomOf(r, st, ops, args, model);
    } else try dropCaps(r, st, args, arg_tys);

    // What the callee dereferences must still exist when it is called.
    if (summary) |s| if (!s.assumed) for (s.derefs) |d| {
        const got = try resolve(r, st, d, args, arg_tys, false);
        if (!got.blind) try r.alive(st, inst, .{ .ids = got.ids }, "read by a callee");
    };

    switch (effect) {
        .none, .reads, .query, .container => {},
        .alloc, .alloc_in, .realloc, .releases => {
            if (effect == .realloc) {
                var moved: Set = .empty;
                try endIds(r, st, inst, args[1], text, &moved, true);
                res.moved = moved;
            }
            const heap = try r.mint(st, .heap, inst.id, 0);
            var ids = try Set.single(r.arena, heap);
            // From an arena: the allocation ends with it, or when it is reset.
            var region: Set = .empty;
            if (effect == .alloc_in) {
                if (n > 0) if (args[0].place) |pl| {
                    region = try r.ensureObj(st, pl);
                };
            } else if (n > 0 and effect != .releases) for (args[0].ids.ids) |o| switch (r.identRec(o).kind) {
                .object => region = try region.with(r.arena, o),
                .init => if (r.identRec(o).b == 0) {
                    region = try region.with(r.arena, o);
                },
                // Only a buffer on the stack (a fixed-buffer allocator over a local array) outlives nothing else.
                .local => ids = try ids.with(r.arena, o),
                else => {},
            };
            if (!region.isEmpty()) try r.region_of.put(r.arena, heap, region);
            res.ids = ids;
            res.place = try r.places.root(r.arena, .heap, inst.id);
            if (effect == .releases) {
                const c = try containerAt(r, st, args[0], arg_tys[0]);
                try releaseStorage(r, st, inst, c, text);
                if (c.place) |pl| try r.dropCapsAt(st, pl);
            }
        },
        .handle => {
            const slot = try r.mint(st, .heap, inst.id, 0);
            res.ids = try Set.single(r.arena, slot);
        },
        .free, .resize => if (freed) |i| try endIds(r, st, inst, args[i], text, null, true),
        .cancel => if (freed) |i| {
            // The error of a second free is the caller's to propagate (`try`) or to swallow (`catch {}`).
            if (try staleHandle(r, args[i])) |e| try r.cancels.put(r.arena, inst.id, e);
            try endIds(r, st, inst, args[i], text, null, false);
        },
        .swap => if (n >= 2) {
            // The two objects trade contents.
            const pointee = r.pointeeOf(arg_tys[0]);
            const pa = args[0].place orelse return try swapBlind(r, inst, res);
            const pb = args[1].place orelse return try swapBlind(r, inst, res);
            // The contents trade places; each place keeps its own incarnation.
            var first = try r.readVal(st, pa, pointee);
            var second = try r.readVal(st, pb, pointee);
            first.obj = r.objAt(st, pb);
            second.obj = r.objAt(st, pa);
            try r.store(inst, st, args[0], second, pointee, false);
            try r.store(inst, st, args[1], first, pointee, false);
        },
        .allocator_of => if (n > 0) {
            const c = try containerAt(r, st, args[0], arg_tys[0]);
            if (c.place) |pl| {
                const obj = try r.ensureObj(st, pl);
                // What the arena keeps (its state) is the arena as far as a copy of it goes.
                try holdObject(r, st, pl, c.ty, obj, 0);
                var ids = (try r.peekFlat(st, pl)).ids;
                for (obj.ids) |o| ids = try ids.with(r.arena, o);
                res.ids = ids;
            } else res.ids = args[0].ids;
        },
        .ends => if (n > 0) try endObject(r, st, inst, args[0], arg_tys[0], text, true),
        .invalidates => if (n > 0) {
            _ = try invalidate(r, st, inst, try containerAt(r, st, args[0], arg_tys[0]), text, true, try allocatorRegion(r, args, arg_tys));
            try storeArgs(r, st, inst, args);
        },
        .resets => if (n > 0) {
            const c = try containerAt(r, st, args[0], arg_tys[0]);
            if (c.place) |pl| {
                const objs = try r.ensureObj(st, pl);
                const event: Event = .{ .loc = inst.loc, .text = try std.fmt.allocPrint(r.arena, "{s} gives back what `{s}` handed out here", .{ text, r.placeName(pl) }), .trail = st.trail };
                try r.endRegion(st, inst, objs, event);
            } else try r.tally("blind", inst);
        },
    }
    if (container_call and n > 0 and effect != .releases) {
        const c = try containerAt(r, st, args[0], arg_tys[0]);
        if (body == null and effect == .container) {
            if (model.shift or model.shift_maybe or (model.grow and !room.proven)) {
                const ended = try invalidate(r, st, inst, c, text, model.shift or (model.grow and !room.proven and !room.soft), try allocatorRegion(r, args, arg_tys));
                if (model.grow and !room.proven and !room.soft) try readsEnded(r, st, inst, args, arg_tys, ended, text);
            }
            try storeArgs(r, st, inst, args);
        } else if (model.shift or model.shift_maybe) _ = try invalidate(r, st, inst, c, text, model.shift, .empty);
        if (spec.removes(declared)) try dropPending(r, st, args[0]);
        if (model.moves and body == null) try moveStorage(r, st, inst, c, &res);
    }
    if (summary) |s| try applySummary(r, st, inst, s, args, arg_tys, &res, .{
        .skip_content_kills = container_call and room.proven,
        .soft = container_call and room.soft,
        .library = known != null and isLibrary(known.?),
        .callee = r.callName(inst),
        .pre_ended = effect == .ends,
    });
    if (summary) |s| if (r.ty.hasPointers(inst.ty)) try countLent(r, inst, s, args);
    if (container_call and model.seeds) res.room = room.seed;
    // A handle (a value with identities but no pointers) names what a pointer the call hands out points to.
    if (r.ty.hasPointers(inst.ty)) for (args, arg_tys) |a, aty| {
        if (!r.ty.hasPointers(aty) and !r.ty.isPointer(aty) and r.ty.kind(aty) == .@"struct") res.ids = try res.ids.merge(r.arena, a.ids);
    };
    if (res.ids.isEmpty() and res.obj.isEmpty() and res.parts == null) {
        try unknownResult(r, st, inst, &res, effect, summary, container_call, model, args, arg_tys, known);
    } else if (container_call and (model.ptr != .none or model.adopts or model.seeds) and !(model.ptr == .content and summary != null)) {
        try containerResult(r, st, inst, &res, model, args, arg_tys);
    }
    return finish(r, inst, res);
}

/// A callee nobody read may write any scalar below the pointers it was given: what was known of them is gone.
fn forgetScalars(r: *Run, st: *State, args: []const Val, tys: []const schema.TypeId) Allocator.Error!void {
    for (args, tys) |a, t| {
        if (!r.ty.isPointer(t)) continue;
        if (a.place) |pl| try r.clobber(st, pl);
    }
}

/// A pointer to a local handed to a call that returns something with pointers: when the summary of the callee says
/// nothing of where the argument went, or says the result holds a new allocation (whose elements may keep it), what the
/// result keeps of the local is not followed.
fn countLent(r: *Run, inst: *const Inst, s: Summary, args: []const Val) Allocator.Error!void {
    var new_block = false;
    for (s.ret) |l| for (l.descs) |d| {
        new_block = new_block or d.src == .fresh;
    };
    for (args, 0..) |a, i| {
        if (!holdsLocal(r, a)) continue;
        var traced = false;
        for (s.ret) |l| for (l.descs) |d| switch (d.src) {
            .from => |slot| traced = traced or slot.param == i,
            else => {},
        };
        for (s.writes) |w| for (w.descs) |d| switch (d.src) {
            .from => |slot| traced = traced or slot.param == i,
            else => {},
        };
        if (!traced or new_block) return r.tally("lent", inst);
    }
}

fn holdsLocal(r: *Run, v: Val) bool {
    for (v.ids.ids) |id| if (r.identRec(id).kind == .local) return true;
    if (v.parts) |parts| for (parts) |part| if (holdsLocal(r, part)) return true;
    return false;
}

fn finish(r: *Run, inst: *const Inst, res: Val) Error!void {
    r.set(inst, res);
}

fn swapBlind(r: *Run, inst: *const Inst, res: Val) Error!void {
    try r.tally("blind", inst);
    return finish(r, inst, res);
}

fn freshTokens(r: *Run, st: *State, inst: *const Inst, sub: *u32) Error!Val {
    return r.freshTokens(st, inst, sub);
}

/// The objects an allocator argument stands for: what a block allocated through it ends with.
fn allocatorRegion(r: *Run, args: []const Val, tys: []const schema.TypeId) Allocator.Error!Set {
    var out: Set = .empty;
    for (args, tys) |a, t| if (r.ty.isAllocator(t)) for (a.ids.ids) |o| switch (r.identRec(o).kind) {
        .object => out = try out.with(r.arena, o),
        .init => if (r.identRec(o).b == 0) {
            out = try out.with(r.arena, o);
        },
        else => {},
    };
    return out;
}

fn constantArg(r: *Run, ops: []const schema.Operand, at: usize, value: u64) bool {
    if (at + 1 >= ops.len) return false;
    const o = ops[1 + at];
    if (o.kind != .constant) return false;
    const k = r.v.constant(o);
    return k.kind == .int and k.a == value;
}

fn anyPointerLike(r: *Run, tys: []const schema.TypeId) bool {
    for (tys) |t| if (r.ty.isPointer(t) or r.ty.hasPointers(t)) return true;
    return false;
}

fn hasAllocator(r: *Run, tys: []const schema.TypeId) bool {
    for (tys) |t| if (r.ty.isAllocator(t)) return true;
    return false;
}

/// A function of std: not part of what is being checked, so its own run is not counted.
fn isLibrary(ref: Ref) bool {
    const file = ref.pack.t.files[@backingInt(ref.func.file)];
    return std.mem.eql(u8, ref.pack.str(file.module), "std");
}

/// A linear value went into a call: when the callee keeps it in memory the checker does not follow, that is a
/// transfer. A callee of the project counted it in its own run; std and the callees without a body did not.
fn noteTokenPassed(r: *Run, inst: *const Inst, a: Val, at: usize, known: ?Ref, body: ?Summary, declared: []const u8) Allocator.Error!void {
    if (std.mem.startsWith(u8, declared, "zv.")) return;
    const bit: u64 = if (at < 64) @as(u64, 1) << @intCast(at) else 0;
    var stored = true;
    if (body) |b| {
        stored = b.token_stores & bit != 0;
        if (stored) r.noteTokensOf(a);
        if (!isLibrary(known.?)) return;
    }
    if (!stored) return;
    try r.tally("transfers", inst);
    r.noteTokensOf(a);
}

// Room.

const Room = struct {
    /// The call is known not to reallocate.
    proven: bool = false,
    /// It reallocates only if there is no room, and a reserve of a size the checker cannot read was made.
    soft: bool = false,
    /// The room a container made by this call starts with.
    seed: ?u64 = null,
};

/// Updates what is known of the room in the container the first argument points to, and says whether the call
/// is known not to reallocate.
fn roomOf(r: *Run, st: *State, ops: []const schema.Operand, args: []const Val, model: spec.Model) Allocator.Error!Room {
    var out: Room = .{};
    if (model.seeds) out.seed = seedOf(r, ops);
    if (args.len == 0) return out;
    const pl = args[0].place orelse args[0].src orelse return out;
    const cur = st.caps.get(pl) orelse check.Cap{};
    var next = cur;
    var proven = false;
    const count = countArg(r, ops);
    switch (model.count) {
        .keep => {},
        .drop => {
            try r.dropCapsAt(st, pl);
            return out;
        },
        .remove1 => next.len_ub = if (cur.len_ub) |l| l -| 1 else null,
        .insert1 => {
            proven = cur.len_ub != null and cur.len_ub.? + 1 <= cur.cap_lb;
            next.len_ub = if (cur.len_ub) |l| l + 1 else null;
        },
        // The contract of these methods: the room is there, nothing is reallocated.
        .insert1_assume => {
            proven = true;
            next.len_ub = if (cur.len_ub) |l| l + 1 else null;
        },
        .many => if (sliceLen(r, ops)) |k| {
            proven = cur.len_ub != null and cur.len_ub.? + k <= cur.cap_lb;
            next.len_ub = if (cur.len_ub) |l| l + k else null;
        } else {
            next.len_ub = null;
        },
        .many_assume => {
            proven = true;
            next.len_ub = null;
        },
        .total => if (count) |c| {
            proven = c <= cur.cap_lb;
            next.cap_lb = @max(cur.cap_lb, c);
        } else {
            next.sym = true;
        },
        .unused => if (count) |c| {
            proven = cur.len_ub != null and cur.len_ub.? + c <= cur.cap_lb;
            next.cap_lb = @max(cur.cap_lb, c);
        } else {
            next.sym = true;
        },
    }
    // Only a method that can reallocate has a reallocation to rule out.
    proven = proven and (model.grow or model.count == .insert1_assume or model.count == .many_assume);
    out.proven = proven;
    out.soft = !proven and model.grow and cur.sym;
    if (next.cap_lb == 0 and next.len_ub == null and !next.sym) {
        _ = st.caps.swapRemove(pl);
    } else try st.caps.put(r.arena, pl, next);
    return out;
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

/// The room `initCapacity` or `initBuffer` gives: the constant count, or the length of the array it is lent.
fn seedOf(r: *Run, ops: []const schema.Operand) ?u64 {
    if (countArg(r, ops)) |c| return c;
    var i = ops.len;
    while (i > 1) {
        i -= 1;
        const pt = r.ty.pointee(r.operandType(ops[i])) orelse continue;
        const rec = r.ty.rec(pt);
        if (rec.kind == .array) return rec.len;
    }
    return null;
}

/// The length of a slice argument that is an array or a string literal.
fn sliceLen(r: *Run, ops: []const schema.Operand) ?u64 {
    const o = ops[ops.len - 1];
    switch (o.kind) {
        .inst => {
            const def = r.by_id[o.value] orelse return null;
            if (def.tag != .array_to_slice) return null;
            const pt = r.ty.pointee(r.operandType(r.v.ops(def)[0])) orelse return null;
            const rec = r.ty.rec(pt);
            return if (rec.kind == .array) rec.len else null;
        },
        .constant => {
            const k = r.v.constant(o);
            // A literal sliced as the compiler prints it: `"ok"[0..2]`.
            if (k.kind == .text) {
                const text = r.pack.str(@enumFromInt(k.a));
                if (text.len != 0 and text[text.len - 1] == ']') if (std.mem.lastIndexOfScalar(u8, text, '[')) |open| {
                    const range = text[open + 1 .. text.len - 1];
                    const dots = std.mem.indexOf(u8, range, "..") orelse return null;
                    const lo = std.fmt.parseInt(u64, range[0..dots], 10) catch return null;
                    const hi = std.fmt.parseInt(u64, range[dots + 2 ..], 10) catch return null;
                    return if (hi >= lo) hi - lo else null;
                };
            }
            const pt = r.ty.pointee(k.ty) orelse return null;
            const rec = r.ty.rec(pt);
            return if (rec.kind == .array) rec.len else null;
        },
        .none => return null,
    }
}

/// A call that can write through a pointer to a container leaves nothing known of its room.
fn dropCaps(r: *Run, st: *State, args: []const Val, tys: []const schema.TypeId) Allocator.Error!void {
    if (st.caps.count() == 0) return;
    for (args, tys) |a, t| if (r.ty.isPointer(t)) if (a.place) |pl| {
        if (!r.places.hasElem(pl)) try r.dropCapsAt(st, pl);
    };
}

/// A removal from the container at `obj` ends the entries that were put into it for the duration of a call.
fn dropPending(r: *Run, st: *State, obj: Val) Allocator.Error!void {
    const pl = obj.place orelse obj.src orelse return;
    var k: usize = 0;
    while (k < st.pending.count()) {
        if (r.places.overlaps(r.identRec(st.pending.values()[k].ident).a, pl)) st.pending.swapRemoveAt(k) else k += 1;
    }
}

// Containers and objects.

/// The object an argument names: where it lives and what it holds, by pointer or by value.
const Container = struct { val: Val, place: ?PlaceId, ty: schema.TypeId };

fn containerAt(r: *Run, st: *State, a: Val, aty: schema.TypeId) Allocator.Error!Container {
    if (r.ty.isPointer(aty)) {
        const pt = r.pointeeOf(aty);
        const pl = a.place orelse a.src orelse return .{ .val = .none, .place = null, .ty = pt };
        return .{ .val = try r.readVal(st, pl, pt), .place = pl, .ty = pt };
    }
    return .{ .val = a, .place = a.src, .ty = aty };
}

/// Puts `obj` into the pointer fields of the aggregate at `pl` that the object owns.
fn holdObject(r: *Run, st: *State, pl: PlaceId, ty: schema.TypeId, obj: Set, depth: u32) Allocator.Error!void {
    if (r.ty.isAllocator(r.ty.payload(ty))) return;
    if (depth < 5) if (r.ty.structFields(ty)) |fields| {
        for (fields, 0..) |f, k| try holdObject(r, st, try r.places.child(r.arena, pl, @intCast(k)), f.ty, obj, depth + 1);
        return;
    };
    if (!r.ty.hasPointers(ty)) return;
    const old = try r.peekFlat(st, pl);
    try r.writeLeafAs(st, pl, .{ .ids = try old.ids.merge(r.arena, obj) }, r.strongAt(pl));
}

/// The places of the storage a container owns: its slice and many-item pointer fields, below `pl`.
fn storageLeaves(r: *Run, out: *std.ArrayList(struct { PlaceId, schema.TypeId }), pl: PlaceId, ty: schema.TypeId, depth: u32) Allocator.Error!void {
    if (depth < 5) if (r.ty.structFields(ty)) |fields| if (!r.ty.isAllocator(r.ty.payload(ty))) {
        for (fields, 0..) |f, k| try storageLeaves(r, out, try r.places.child(r.arena, pl, @intCast(k)), f.ty, depth + 1);
        return;
    };
    if (r.ty.isAllocator(r.ty.payload(ty))) return;
    if (r.ty.structFields(ty) == null and r.ty.kind(r.ty.payload(ty)) != .@"struct" and !r.ty.isStorage(ty)) return;
    try out.append(r.arena, .{ pl, ty });
}

/// What a container value owns: the heap blocks and caller-given storage in its pointer fields (not an allocator it
/// was given, not an object it points to).
fn ownedIds(r: *Run, v: Val, ty: schema.TypeId, depth: u32) Allocator.Error!Set {
    var out: Set = .empty;
    if (r.ty.isAllocator(r.ty.payload(ty))) return out;
    if (depth < 5) if (r.ty.structFields(ty)) |fields| if (v.parts) |parts| if (parts.len == fields.len) {
        for (fields, parts) |f, part| out = try out.merge(r.arena, try ownedIds(r, part, f.ty, depth + 1));
        return out;
    };
    const flat_struct = r.ty.kind(r.ty.payload(ty)) == .@"struct";
    for (v.ids.ids) |id| {
        const rec = r.identRec(id);
        switch (rec.kind) {
            .heap, .tomb => out = try out.with(r.arena, id),
            // Without the fields of the type, the parameter's own value may be an allocator it was handed.
            .init => if (!(flat_struct and rec.b == 0 and r.places.rec(rec.a).parent == dom.no_place)) {
                out = try out.with(r.arena, id);
            },
            else => {},
        }
    }
    return out;
}

/// `deinit`: the object and what it owns are gone, and so is everything that was allocated from it.
/// With `leaves`, what the pointer fields of an object of a known family lead into goes with it; a function whose body is
/// known says by itself what it gives back.
fn endObject(r: *Run, st: *State, inst: *const Inst, a: Val, aty: schema.TypeId, what: []const u8, leaves: bool) Error!void {
    const c = try containerAt(r, st, a, aty);
    var objs = c.val.obj;
    if (objs.isEmpty()) if (c.place) |pl| {
        objs = try r.ensureObj(st, pl);
    };
    if (objs.isEmpty() and c.place == null and r.ty.isPointer(aty)) return r.tally("blind", inst);
    const name = if (c.place) |pl| r.placeName(pl) else "the object";
    for (objs.ids) |o| {
        if (r.identRec(o).kind != .tomb or r.identRec(o).b == 1) continue;
        const e = st.dead.get(r.identRec(o).a) orelse r.tomb_events.get(o) orelse continue;
        if (e.loc == inst.loc) continue;
        var items: std.ArrayList(diag.Note) = .empty;
        try items.append(r.arena, .{ .loc = e.loc, .text = e.text });
        try r.report(st, .use_after_free, inst.loc, try r.noteList(items.items), "`{s}` is used after it was deinitialized", .{name});
    }
    // One element of many: the checker cannot tell which one ended.
    const many = c.val.many or (if (c.place) |pl| r.places.hasElem(pl) else false);
    const event: Event = .{ .loc = inst.loc, .text = try std.fmt.allocPrint(r.arena, "{s} ends `{s}` here", .{ what, name }), .trail = st.trail, .soft = many };
    for (objs.ids) |o| try r.end(st, inst, o, event);
    const owned = if (leaves) try ownedIds(r, c.val, c.ty, 0) else Set.empty;
    for (owned.ids) |id| {
        if (r.identRec(id).kind == .tomb and r.identRec(id).b == 0) {
            var items: std.ArrayList(diag.Note) = .empty;
            if (st.dead.get(r.identRec(id).a) orelse r.tomb_events.get(id)) |e| try items.append(r.arena, .{ .loc = e.loc, .text = e.text });
            try r.report(st, .double_free, inst.loc, try r.noteList(items.items), "memory is freed twice", .{});
        } else if (r.identRec(id).kind != .tomb) try r.end(st, inst, id, event);
    }
    try r.endRegion(st, inst, objs, event);
}

/// Stale pointers into a container: its storage is replaced by a new block (it may have moved, or its elements may have).
fn invalidate(r: *Run, st: *State, inst: *const Inst, c: Container, what: []const u8, hard: bool, region: Set) Error!Set {
    var ended: Set = .empty;
    const pl = c.place orelse {
        try r.tally("blind", inst);
        return ended;
    };
    try r.objectAlive(st, inst, pl);
    if (!isInsertion(r.callName(inst))) try clearPending(r, st, pl);
    var leaves: std.ArrayList(struct { PlaceId, schema.TypeId }) = .empty;
    try storageLeaves(r, &leaves, pl, c.ty, 0);
    const text = try std.fmt.allocPrint(r.arena, "{s} invalidates pointers into `{s}` here", .{ what, r.placeName(pl) });
    const event: Event = .{ .loc = inst.loc, .text = text, .trail = st.trail, .soft = !hard or r.places.hasElem(pl), .exact = hard and !r.places.hasElem(pl) };
    // Pointers to elements kept inline in the container are stale too.
    var view: usize = 0;
    while (view < r.idents.items.len) : (view += 1) {
        const rec = r.idents.items[view];
        if (rec.kind == .init and rec.b == 2 and r.places.contains(pl, rec.a)) try r.end(st, inst, @intCast(view), event);
    }
    var any = false;
    for (leaves.items) |leaf| any = any or holdsStorage(r, try r.peekFlat(st, leaf[0]));
    var k: u32 = 0;
    for (leaves.items, 0..) |leaf, at| {
        const v = try r.peekFlat(st, leaf[0]);
        const had = holdsStorage(r, v);
        for (v.ids.ids) |id| switch (r.identRec(id).kind) {
            .heap, .init => {
                if (r.pointees.contains(id)) continue;
                try r.end(st, inst, id, event);
                ended = try ended.with(r.arena, id);
            },
            else => {},
        };
        // The new storage: pointers read from here on are good.
        if (!had and (any or at != 0)) continue;
        const fresh = try r.mint(st, .heap, inst.id, k);
        k += 1;
        if (!region.isEmpty()) try r.region_of.put(r.arena, fresh, region);
        var next: Val = .{ .ids = try Set.single(r.arena, fresh) };
        // Memory a container got from a stack buffer stays that buffer's.
        for (v.ids.ids) |id| if (r.identRec(id).kind == .local) {
            next.ids = try next.ids.with(r.arena, id);
        };
        // The old block is gone on every path (not only one of several alike): what the slot held is replaced.
        try r.writeLeafAs(st, leaf[0], next, r.strongAt(leaf[0]) or !event.soft);
    }
    return ended;
}

fn holdsStorage(r: *Run, v: Val) bool {
    for (v.ids.ids) |id| switch (r.identRec(id).kind) {
        .heap, .init => return true,
        else => {},
    };
    return false;
}

fn isInsertion(callee: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, callee, '.') orelse 0;
    const method = callee[if (dot == 0) 0 else dot + 1 ..];
    const stores = [_][]const u8{ "append", "put", "fetchPut", "insert", "add", "push", "prepend", "enqueue", "getOrPut", "ensure", "resize", "reserve", "expand", "set", "replace" };
    for (stores) |s| if (std.mem.startsWith(u8, method, s)) return true;
    return false;
}

fn clearPending(r: *Run, st: *State, pl: PlaceId) Allocator.Error!void {
    var k: usize = 0;
    while (k < st.pending.count()) {
        if (r.places.overlaps(r.identRec(st.pending.values()[k].ident).a, pl)) st.pending.swapRemoveAt(k) else k += 1;
    }
}

/// The buffer leaves the container (`toOwnedSlice`): pointers into it are stale (it may have been shrunk in place),
/// the container is empty, and the result is a new allocation.
fn releaseStorage(r: *Run, st: *State, inst: *const Inst, c: Container, what: []const u8) Error!void {
    const pl = c.place orelse return r.tally("blind", inst);
    try r.objectAlive(st, inst, pl);
    var leaves: std.ArrayList(struct { PlaceId, schema.TypeId }) = .empty;
    try storageLeaves(r, &leaves, pl, c.ty, 0);
    const text = try std.fmt.allocPrint(r.arena, "{s} invalidates pointers into `{s}` here", .{ what, r.placeName(pl) });
    const event: Event = .{ .loc = inst.loc, .text = text, .trail = st.trail };
    for (leaves.items) |leaf| {
        const v = try r.peekFlat(st, leaf[0]);
        for (v.ids.ids) |id| switch (r.identRec(id).kind) {
            .heap, .init => try r.end(st, inst, id, event),
            else => {},
        };
        try r.writeLeafAs(st, leaf[0], .none, r.strongAt(leaf[0]));
    }
}

/// The storage of the container goes to the result as it is, and the container is empty.
fn moveStorage(r: *Run, st: *State, inst: *const Inst, c: Container, res: *Val) Error!void {
    const pl = c.place orelse return r.tally("blind", inst);
    var leaves: std.ArrayList(struct { PlaceId, schema.TypeId }) = .empty;
    try storageLeaves(r, &leaves, pl, c.ty, 0);
    for (leaves.items) |leaf| {
        const v = try r.peekFlat(st, leaf[0]);
        res.ids = try res.ids.merge(r.arena, v.ids);
        try r.writeLeafAs(st, leaf[0], .none, r.strongAt(leaf[0]));
    }
}

/// The arguments of a container operation flow into the container: a pointer to a local that goes into
/// memory the caller owns outlives the local.
fn storeArgs(r: *Run, st: *State, inst: *const Inst, args: []const Val) Error!void {
    // `appendSlice` and its kin copy the elements, not the slice they are read from.
    const callee = r.callName(inst);
    // `getOrPut` hands back the slot for the caller to fill in, which is where a key is replaced by an owned copy.
    if (std.mem.indexOf(u8, callee, "getOrPut") != null) return;
    if (std.mem.indexOf(u8, callee, "Slice") != null or std.mem.indexOf(u8, callee, "NTimes") != null or std.mem.indexOf(u8, callee, "Many") != null) return;
    if (!isInsertion(callee)) return;
    const self_val = args[0];
    const into_local = r.isLocalPtr(self_val);
    for (args[1..]) |a| try r.escapesInto(st, inst, a, into_local, "stored into a container that outlives it", self_val.place);
}

/// The result of a container method from the documented model: what it points into.
fn containerResult(r: *Run, st: *State, inst: *const Inst, res: *Val, model: spec.Model, args: []const Val, tys: []const schema.TypeId) Error!void {
    if (model.adopts) {
        for (args, tys) |a, t| if (!r.ty.isAllocator(t)) {
            res.ids = try res.ids.merge(r.arena, a.ids);
        };
        return;
    }
    if (model.seeds) {
        // Made over a buffer it was lent, or over a new block from an allocator.
        if (hasAllocator(r, tys)) {
            const fresh = try r.mint(st, .heap, inst.id, 0);
            const region = try allocatorRegion(r, args, tys);
            if (!region.isEmpty()) try r.region_of.put(r.arena, fresh, region);
            res.ids = try res.ids.with(r.arena, fresh);
        } else for (args) |a| {
            res.ids = try res.ids.merge(r.arena, a.ids);
        }
        const shaped = try r.inStorage(inst.ty, res.ids, 0);
        res.parts = shaped.parts;
        return;
    }
    if (args.len == 0) return;
    switch (model.ptr) {
        .none => {},
        .storage => {
            const c = try containerAt(r, st, args[0], tys[0]);
            if (c.place) |pl| {
                var leaves: std.ArrayList(struct { PlaceId, schema.TypeId }) = .empty;
                try storageLeaves(r, &leaves, pl, c.ty, 0);
                for (leaves.items) |leaf| res.ids = try res.ids.merge(r.arena, (try r.peekFlat(st, leaf[0])).ids);
            } else res.ids = try res.ids.merge(r.arena, c.val.ids);
        },
        .self => res.ids = try res.ids.merge(r.arena, args[0].ids),
        .content => for (args, tys) |a, t| {
            for (a.ids.ids) |id| if (r.identRec(id).kind != .local) {
                res.ids = try res.ids.with(r.arena, id);
            };
            if (r.ty.isPointer(t)) if (a.place) |pl| {
                const content = try r.peekFlat(st, pl);
                res.ids = try res.ids.merge(r.arena, content.ids);
            };
        },
    }
}

/// The result of a call nothing is known of: given an allocator, an allocation from it; otherwise it may point into
/// anything an argument leads to, except when the callee is reached through a function pointer.
fn unknownResult(
    r: *Run,
    st: *State,
    inst: *const Inst,
    res: *Val,
    effect: spec.Effect,
    summary: ?Summary,
    container_call: bool,
    model: spec.Model,
    args: []const Val,
    tys: []const schema.TypeId,
    known: ?Ref,
) Error!void {
    if (!r.ty.hasPointers(inst.ty) and summary == null) return;
    if (summary != null) {
        // What a result of a nested helper (an iterator, a slice view) holds is in its body; the table is for the rest.
        if (container_call and model.ptr != .content and (model.ptr != .none or model.adopts or model.seeds)) try containerResult(r, st, inst, res, model, args, tys);
        return;
    }
    if (container_call and (model.ptr != .none or model.adopts or model.seeds)) return containerResult(r, st, inst, res, model, args, tys);
    if (effect != .none and effect != .container and effect != .reads) return;
    if (r.v.attrStr(inst, .callee) == null) {
        for (args) |a| if (r.isLocalPtr(a)) return r.tally("lent", inst);
        return;
    }
    // A method the model knows hands out nothing of the container (`get` copies a value).
    if (container_call and model.modelled) return;
    _ = known;
    // A function that hands out a pointer or a slice, given an allocator, hands out an allocation from it.
    if (hasAllocator(r, tys) and r.topLevelPointer(inst.ty)) {
        var region: Set = .empty;
        var ids: Set = .empty;
        for (args, tys) |a, t| if (r.ty.isAllocator(t)) for (a.ids.ids) |o| switch (r.identRec(o).kind) {
            .object => region = try region.with(r.arena, o),
            .init => if (r.identRec(o).b == 0) {
                region = try region.with(r.arena, o);
            },
            .local => ids = try ids.with(r.arena, o),
            else => {},
        };
        const heap = try r.mint(st, .heap, inst.id, 0);
        if (!region.isEmpty()) try r.region_of.put(r.arena, heap, region);
        res.ids = try ids.with(r.arena, heap);
        return;
    }
    // A struct that is handed back, given an allocator, holds allocations from it: one in each pointer field.
    if (hasAllocator(r, tys) and !derivesFromArgs(r, args, tys)) {
        var region: Set = .empty;
        var local: Set = .empty;
        var given: Set = .empty;
        for (args, tys) |a, t| if (r.ty.isAllocator(t)) for (a.ids.ids) |o| {
            given = try given.with(r.arena, o);
            switch (r.identRec(o).kind) {
                .object => region = try region.with(r.arena, o),
                .init => if (r.identRec(o).b == 0) {
                    region = try region.with(r.arena, o);
                },
                .local => local = try local.with(r.arena, o),
                else => {},
            }
        };
        var k: u32 = 0;
        if (try fieldAllocations(r, st, inst, inst.ty, given, region, local, &k, 0)) |shaped| {
            res.ids = shaped.ids;
            res.parts = shaped.parts;
            return;
        }
    }
    // It may point into anything an argument leads to: the argument itself and the storage behind a pointer.
    var held: Set = .empty;
    var given: Set = .empty;
    for (args, tys) |a, t| {
        // A pointer to something that holds pointers (a context, an iterator) is the callee's business: what it hands out
        // lives in what the thing holds, not in the stack slot that holds the thing; the stack slot itself is in the result
        // only if the result has a pointer to the thing.
        const pointee = r.ty.pointee(t);
        const holds = if (pointee) |pt| r.ty.hasPointers(pt) and (r.topLevelPointer(inst.ty) or !holdsPointerTo(r, inst.ty, pt, 0)) else false;
        const into = if (r.ty.isAllocator(t)) &given else &held;
        for (a.ids.ids) |id| if (!(holds and r.identRec(id).kind == .local)) {
            into.* = try into.with(r.arena, id);
        };
        if (r.ty.isPointer(t)) if (a.place) |pl| {
            const content = try r.peekFlat(st, pl);
            for (content.ids.ids) |id| switch (r.identRec(id).kind) {
                .heap, .init => held = try held.with(r.arena, id),
                else => {},
            };
        };
    }
    // A struct that is handed back keeps the allocator in the field made for it, and the rest where it points. Which of
    // several things a field leads into is not known.
    if (try r.byField(inst.ty, given, held, 0)) |shaped| {
        res.ids = shaped.ids;
        res.parts = shaped.parts;
        res.maybe = held.ids.len > 1;
        if (res.parts) |parts| {
            const copy = try r.arena.alloc(Val, parts.len);
            for (copy, parts) |*slot, part| {
                slot.* = part;
                slot.maybe = held.ids.len > 1;
            }
            res.parts = copy;
        }
    } else {
        res.ids = try held.merge(r.arena, given);
        res.maybe = held.ids.len > 1;
    }
}

/// Whether some argument that is not an allocator leads anywhere: what a call hands back may come from it.
fn derivesFromArgs(r: *Run, args: []const Val, tys: []const schema.TypeId) bool {
    for (args, tys) |a, t| {
        if (r.ty.isAllocator(t) or a.ids.isEmpty()) continue;
        // Text and bytes that are read, or a pointer to a number, are inputs; a struct or a pointer to one carries state.
        const pt = r.ty.pointee(t) orelse t;
        if (r.ty.kind(pt) == .@"struct" or r.ty.kind(pt) == .@"union" or r.ty.kind(pt) == .pointer) return true;
    }
    return false;
}

/// Whether a value of type `ty` has a field that is a pointer to a `pointee`.
fn holdsPointerTo(r: *Run, ty: schema.TypeId, pointee: schema.TypeId, depth: u32) bool {
    if (depth >= 4) return true;
    // A type nothing is known of may hold anything; a number or a slice of numbers holds no pointer to it.
    const fields = r.ty.structFields(ty) orelse return r.ty.kind(r.ty.payload(ty)) == .@"struct" or r.ty.kind(r.ty.payload(ty)) == .@"union";
    for (fields) |f| {
        if (r.ty.pointee(r.ty.payload(f.ty))) |pt| if (pt == pointee or std.mem.eql(u8, r.ty.name(pt), r.ty.name(pointee))) return true;
        if (holdsPointerTo(r, f.ty, pointee, depth + 1)) return true;
    }
    return false;
}

/// A value of struct type `ty` with a new allocation from the allocator in each of its pointer fields (the allocator
/// where it keeps it); null when the type has no known fields.
fn fieldAllocations(r: *Run, st: *State, inst: *const Inst, ty: schema.TypeId, given: Set, region: Set, local: Set, k: *u32, depth: u32) Allocator.Error!?Val {
    if (r.ty.isAllocator(r.ty.payload(ty))) return .{ .ids = given };
    if (depth >= 4) return null;
    const fields = r.ty.structFields(ty) orelse return null;
    const parts = try r.arena.alloc(Val, fields.len);
    for (parts, fields) |*part, f| {
        if (try fieldAllocations(r, st, inst, f.ty, given, region, local, k, depth + 1)) |inner| {
            part.* = inner;
        } else if (r.ty.hasPointers(f.ty)) {
            k.* += 1;
            const heap = try r.mint(st, .heap, inst.id, k.*);
            if (!region.isEmpty()) try r.region_of.put(r.arena, heap, region);
            part.* = .{ .ids = try local.with(r.arena, heap) };
        } else part.* = .none;
    }
    return try Val.aggregate(r.arena, parts);
}

// Ending allocations.

/// `free(x)`: the allocations `x` leads into end; a second free is a finding. With `deferred`, nothing ends yet: the
/// identities that do when the call succeeds are collected (`realloc` on an error that came back leaves the old
/// memory alone).
/// What a free of this handle would be a second free of, if there is one.
fn staleHandle(r: *Run, val: Val) Allocator.Error!?check.Cancel {
    for (val.ids.ids) |o| {
        const rec = r.identRec(o);
        if (rec.kind == .tomb and rec.b == 0) return .{ .tomb = o };
    }
    return null;
}

fn endIds(r: *Run, st: *State, inst: *const Inst, val: Val, what: []const u8, deferred: ?*Set, report: bool) Error!void {
    var first: ?dom.Id = null;
    var soft = false;
    for (val.ids.ids) |o| {
        const rec = r.identRec(o);
        if (rec.kind != .tomb) continue;
        if (rec.b == 1) soft = true else if (first == null) first = o;
    }
    // One of many (an element read out of an array): the site names them all and only one was freed, so a second free of
    // an element is no proof of a double free; it is counted.
    if (deferred == null and report) {
        if (first != null and !val.many) {
            const t = first.?;
            var items: std.ArrayList(diag.Note) = .empty;
            if (st.dead.get(r.identRec(t).a) orelse r.tomb_events.get(t)) |e| try items.append(r.arena, .{ .loc = e.loc, .text = e.text });
            try r.report(st, .double_free, inst.loc, try r.noteList(items.items), "memory is freed twice", .{});
        } else if (soft or first != null) try r.tally("maybe_alias", inst);
    }
    // A value that may be one of several allocations frees one of them, and the checker cannot tell which.
    const event: Event = .{ .loc = inst.loc, .text = try std.fmt.allocPrint(r.arena, "first freed here by {s}", .{what}), .trail = st.trail, .soft = val.maybe or val.many };
    for (val.ids.ids) |o| {
        const rec = r.identRec(o);
        switch (rec.kind) {
            .heap, .init => {
                if (rec.kind == .init and rec.b == 0 and r.places.rec(rec.a).parent == dom.no_place) {
                    if (!isParamItself(r, val, rec.a)) continue;
                    if (deferred == null) st.freed = try st.freed.with(r.arena, o);
                }
                if (deferred) |collected| {
                    collected.* = try collected.with(r.arena, o);
                    try r.moved_events.put(r.arena, o, event);
                } else try r.end(st, inst, o, event);
            },
            else => {},
        }
    }
}

/// Whether `val` is parameter `place`'s own value, or all that is known of it is that it comes from nothing else.
fn isParamItself(r: *Run, val: Val, root: PlaceId) bool {
    if (val.place) |pl| return pl == root;
    var params: usize = 0;
    for (val.ids.ids) |o| {
        const rec = r.identRec(o);
        if (rec.kind == .init and rec.b == 0 and r.places.rec(rec.a).parent == dom.no_place) params += 1;
    }
    return params == 1;
}

// Summaries.

const Applied = struct {
    skip_content_kills: bool,
    soft: bool,
    library: bool,
    callee: []const u8,
    /// The table already ended the object of this call.
    pre_ended: bool,
};

const Resolved = struct { ids: Set = .empty, obj: Set = .empty, place: ?PlaceId = null, blind: bool = false, flat: bool = false };

/// One call ended the same thing through two parameters: it was passed twice.
fn twice(r: *Run, st: *State, inst: *const Inst, callee: []const u8) Error!void {
    try r.report(st, .double_free, inst.loc, &.{}, "`{s}` ends the same memory through two parameters: one object is passed twice", .{callee});
}

/// An argument that points into what the call ends through another argument, and that the callee reads through its own
/// parameter: the callee has two names for one block and frees it under one of them.
fn overlap(r: *Run, st: *State, inst: *const Inst, s: Summary, args: []const Val, tys: []const schema.TypeId, ended_by: []const Set, callee: []const u8) Error!void {
    for (ended_by, 0..) |gone, i| {
        if (gone.isEmpty()) continue;
        for (args, 0..) |a, j| {
            if (i == j or r.ty.isAllocator(tys[j]) or !a.ids.meets(gone)) continue;
            var read = false;
            for (s.derefs) |d| read = read or d.param == j;
            if (!read) continue;
            try r.report(st, .use_after_free, inst.loc, &.{}, "argument {d} of `{s}` points into memory the call ends through argument {d}", .{ j, callee, i });
        }
    }
}

/// An argument that points into the storage the call reallocates is read by the callee after it moved.
fn readsEnded(r: *Run, st: *State, inst: *const Inst, args: []const Val, tys: []const schema.TypeId, ended: Set, callee: []const u8) Error!void {
    if (ended.isEmpty()) return;
    for (args[1..], tys[1..]) |a, t| {
        if (r.ty.isAllocator(t) or !a.ids.meets(ended)) continue;
        try r.report(st, .use_after_free, inst.loc, &.{}, "an argument of `{s}` points into storage that the call reallocates", .{callee});
    }
}
const Gate = struct {
    with: []const check.Cond,
    /// A test of a field of an aggregate (a tag) that the caller does not know the answer of.
    open: bool,
    /// A condition could not be said in the caller's terms and was left out of `with`.
    lost: bool,
};

/// Whether an effect of the callee that holds only where `when` holds can happen here: null when a tag the caller knows
/// says it cannot. Otherwise the conditions that stay open, in the caller's own parameters.
fn gateOf(r: *Run, st: *State, when: []const check.Cond, args: []const Val, tys: []const schema.TypeId) Allocator.Error!?Gate {
    var open: std.ArrayList(check.Cond) = .empty;
    var tag = false;
    var lost = false;
    for (when) |c| {
        const seen = (try scalarIn(r, st, c.slot, args, tys)) orelse {
            tag = tag or c.slot.path.len != 0;
            lost = true;
            continue;
        };
        if (seen.con) |k| {
            if ((k == c.value) != c.eq) return null;
            continue;
        }
        // One of two constants: the end can happen if either of them says so, and then it is as certain as a branch is.
        if (seen.pair) |p| {
            const first = (p[0] == c.value) == c.eq;
            const second = (p[1] == c.value) == c.eq;
            if (!first and !second) return null;
            continue;
        }
        tag = tag or c.slot.path.len != 0;
        const at = seen.at orelse {
            lost = true;
            continue;
        };
        const slot = if (r.entryValued(st, at)) try r.condSlot(at) else null;
        if (slot) |s| {
            try open.append(r.arena, .{ .slot = s, .value = c.value, .eq = c.eq });
        } else lost = true;
    }
    return .{ .with = open.items, .open = tag, .lost = lost };
}

/// The scalar a callee's slot is in the caller: what is known of it, and the place it is read from while that is current.
fn scalarIn(r: *Run, st: *State, slot: Slot, args: []const Val, tys: []const schema.TypeId) Allocator.Error!?struct { con: ?u64, pair: ?[2]u64, at: ?PlaceId } {
    if (slot.param >= args.len) return null;
    const a = args[slot.param];
    if (r.ty.isPointer(tys[slot.param])) {
        if (slot.kind != .content) return null;
        var at = a.place orelse return null;
        for (slot.path) |step| at = try r.places.child(r.arena, at, step);
        const here = try r.peekFlat(st, at);
        return .{ .con = here.con orelse st.facts.get(at), .pair = here.pair, .at = at };
    }
    if (slot.kind != .value) return null;
    var v = a;
    for (slot.path) |step| {
        if (v.parts == null) return null;
        v = v.field(step);
    }
    return .{ .con = v.con, .pair = v.pair, .at = if (v.at != null and r.current(v)) v.at else null };
}

/// What the callee's slot is in the caller: the identities the argument leads into, or the memory below it.
fn resolve(r: *Run, st: *State, slot: Slot, args: []const Val, tys: []const schema.TypeId, lazy: bool) Allocator.Error!Resolved {
    if (slot.param >= args.len) return .{ .blind = true };
    const a = args[slot.param];
    if (r.ty.isPointer(tys[slot.param])) {
        if (slot.kind == .value) return if (slot.path.len == 0) .{ .ids = a.ids } else .{ .blind = true };
        var at = a.place orelse return .{ .blind = true };
        for (slot.path) |step| at = try r.places.child(r.arena, at, step);
        if (slot.kind == .object) return .{ .obj = try r.ensureObj(st, at), .place = at };
        if (slot.kind == .view) return .{ .ids = try Set.single(r.arena, try r.ident(.init, at, 2)), .place = at };
        return .{ .ids = (try r.readLeaf(st, at, .none, lazy)).ids, .place = at };
    }
    var v = a;
    var flat = false;
    for (slot.path) |step| {
        if (v.parts == null and step != dom.elem_step) flat = true;
        v = if (step == dom.elem_step) v.flat() else v.field(step);
    }
    return switch (slot.kind) {
        .object => .{ .obj = v.obj, .flat = flat or v.maybe },
        .value => .{ .ids = v.ids, .flat = flat or v.maybe },
        .content, .view => .{ .blind = true },
    };
}

/// The allocations of one call, named when a result or a write first holds one.
const FreshCtx = struct {
    ids: []?dom.Id,
    s: *const Summary,
    args: []const Val,
    tys: []const schema.TypeId,
    callee: []const u8,
};

fn freshId(r: *Run, st: *State, inst: *const Inst, ctx: FreshCtx, k: u32) Allocator.Error!dom.Id {
    if (ctx.ids[k]) |id| return id;
    const id = try r.mint(st, .heap, inst.id, k);
    ctx.ids[k] = id;
    if (ctx.s.fresh[k].many) st.multi = try st.multi.with(r.arena, id);
    var region: Set = .empty;
    for (ctx.s.fresh[k].regions) |slot| {
        const got = try resolve(r, st, slot, ctx.args, ctx.tys, true);
        for ([_]Set{ got.ids, got.obj }) |set_| for (set_.ids) |o| switch (r.identRec(o).kind) {
            .object => region = try region.with(r.arena, o),
            .init => if (r.identRec(o).b == 0) {
                region = try region.with(r.arena, o);
            },
            else => {},
        };
    }
    if (!region.isEmpty()) try r.region_of.put(r.arena, id, region);
    return id;
}

fn resolveDescs(r: *Run, st: *State, inst: *const Inst, ctx: FreshCtx, descs: []const Desc) Allocator.Error!Val {
    const callee = ctx.callee;
    const args = ctx.args;
    const tys = ctx.tys;
    var out: Val = .none;
    for (descs) |d| {
        const set: Set = switch (d.src) {
            .con, .scalar => .empty,
            .fresh => |k| if (k < ctx.ids.len) try Set.single(r.arena, try freshId(r, st, inst, ctx, k)) else .empty,
            .gone => blk: {
                // What the callee hands back was already freed there.
                const id = try r.mint(st, .heap, inst.id, 4096);
                const event: Event = .{ .loc = inst.loc, .text = try std.fmt.allocPrint(r.arena, "`{s}` returns memory it already freed", .{callee}), .trail = st.trail };
                try r.kill(st, id, event);
                break :blk try Set.single(r.arena, try r.tomb(id, false));
            },
            .from => |slot| blk: {
                const got = try resolve(r, st, slot, args, tys, true);
                break :blk try got.ids.merge(r.arena, got.obj);
            },
        };
        if (d.obj and d.src == .from) out.obj = try out.obj.merge(r.arena, set) else out.ids = try out.ids.merge(r.arena, set);
    }
    // A scalar is a constant when every path that returns made it the same one.
    for (descs) |d| switch (d.src) {
        .con => |c| out.con = c,
        .scalar => |slot| if (try scalarIn(r, st, slot, args, tys)) |seen| {
            out.con = seen.con;
            out.pair = seen.pair;
        },
        else => {},
    };
    // Either a new block or memory the callee was lent, which the checker does not tell apart (the payloads of a union).
    var fresh = false;
    var lent = false;
    for (descs) |d| switch (d.src) {
        .fresh => fresh = true,
        .from => lent = true,
        .gone, .con, .scalar => {},
    };
    out.maybe = out.maybe or (fresh and lent);
    return out;
}

fn applySummary(r: *Run, st: *State, inst: *const Inst, s: Summary, args: []const Val, tys: []const schema.TypeId, res: *Val, opts: Applied) Error!void {
    if (s.assumed) {
        // Only what the intersection over the paths needs: the parameters a recursive call hands on and frees.
        for (args, 0..) |a, i| {
            if (i >= 64 or s.frees & (@as(u64, 1) << @intCast(i)) == 0) continue;
            for (a.ids.ids) |o| {
                const rec = r.identRec(o);
                if (rec.kind == .init and rec.b == 0 and r.places.rec(rec.a).parent == dom.no_place and isParamItself(r, a, rec.a)) st.freed = try st.freed.with(r.arena, o);
            }
        }
        return;
    }
    const ids = try r.arena.alloc(?dom.Id, s.fresh.len);
    @memset(ids, null);
    const ctx: FreshCtx = .{ .ids = ids, .s = &s, .args = args, .tys = tys, .callee = opts.callee };
    // What the result and the writes hold, as it is now: before the callee's ends are applied.
    const leaves = try r.arena.alloc(Val, s.ret.len);
    for (leaves, s.ret) |*v, l| v.* = try resolveDescs(r, st, inst, ctx, l.descs);
    const written = try r.arena.alloc(Val, s.writes.len);
    for (written, s.writes) |*v, w| v.* = try resolveDescs(r, st, inst, ctx, w.descs);
    var moved: Set = res.moved;
    if (s.moves != 0) for (args, 0..) |a, i| {
        if (i < 64 and s.moves & (@as(u64, 1) << @intCast(i)) != 0) try endIds(r, st, inst, a, opts.callee, &moved, true);
    };
    res.moved = moved;
    var ret_place: ?PlaceId = null;
    if (s.ret_place) |slot| ret_place = (try resolve(r, st, slot, args, tys, false)).place;

    // What the callee writes only on the paths that succeed is, on the error path of the caller's `try`, still what it was.
    // A call whose successful paths all test something the caller knows to be otherwise cannot succeed here.
    if (r.ty.kind(inst.ty) == .error_union) {
        var possible = true;
        if (s.ok_when) |alts| {
            possible = false;
            for (alts) |alt| {
                var open = true;
                for (alt) |c| {
                    const seen = (try scalarIn(r, st, c.slot, args, tys)) orelse continue;
                    if (seen.con) |k| {
                        if ((k == c.value) != c.eq) open = false;
                    } else if (seen.pair) |p| {
                        if ((p[0] == c.value) != c.eq and (p[1] == c.value) != c.eq) open = false;
                    }
                }
                possible = possible or open;
            }
        }
        if (possible) _ = r.never_ok.remove(inst.id) else try r.never_ok.put(r.arena, inst.id, {});
    }
    for (s.clobbers) |slot| {
        const got = try resolve(r, st, slot, args, tys, false);
        if (got.place) |pl| try r.clobber(st, pl);
    }
    var restores: std.ArrayList(check.Restore) = .empty;
    if (r.ty.kind(inst.ty) == .error_union) for (s.writes) |w| {
        if (w.on_fail and w.into.kind != .object) {
            const at = (try resolve(r, st, w.into, args, tys, false)).place orelse continue;
            try restores.append(r.arena, .{ .place = at, .val = .{ .con = w.fail_con }, .con_only = true });
            continue;
        }
        if (w.on_fail) continue;
        const got = try resolve(r, st, w.into, args, tys, false);
        const pl = got.place orelse continue;
        const is_obj = w.into.kind == .object;
        try restores.append(r.arena, .{ .place = pl, .val = if (is_obj) .{ .ids = r.objAt(st, pl) } else try r.readLeaf(st, pl, .none, false), .obj = is_obj });
    };
    if (restores.items.len != 0) try r.restores.put(r.arena, inst.id, restores.items) else _ = r.restores.remove(inst.id);
    var killed: Set = .empty;
    var ended: Set = .empty;
    // What the callee reallocates of the object it works on (its first parameter): an argument that points into it is read
    // by the callee after it moved. What it frees of an argument it was given to free is not that.
    var reallocated: Set = .empty;
    const ended_by = try r.arena.alloc(Set, args.len);
    @memset(ended_by, .empty);
    var fail_ends: std.ArrayList(check.FailEnd) = .empty;
    var ok_ends: std.ArrayList(check.FailEnd) = .empty;
    for (s.kills) |kill| {
        const k = kill.slot;
        // A kill that depends on a tag the caller knows to be otherwise does not happen here.
        const gate = try gateOf(r, st, kill.when, args, tys) orelse continue;
        const got = try resolve(r, st, k, args, tys, true);
        if (got.blind) {
            try r.tally("blind", inst);
            continue;
        }
        const where = if (got.place) |pl| r.placeName(pl) else "its argument";
        // Another parameter of the call ended it, not another part of this one.
        var earlier: Set = .empty;
        for (ended_by, 0..) |gone, i| if (i != k.param) {
            earlier = try earlier.merge(r.arena, gone);
        };
        switch (k.kind) {
            .object => {
                const many = got.flat or (if (got.place) |pl| r.places.hasElem(pl) else false);
                const event: Event = .{ .loc = inst.loc, .text = try std.fmt.allocPrint(r.arena, "`{s}` ends `{s}` here", .{ opts.callee, where }), .trail = st.trail, .soft = many, .with = gate.with, .open = gate.open or kill.lost, .lost = gate.lost or kill.lost };
                if (got.place) |pl| try r.objectAlive(st, inst, pl);
                for (got.obj.ids) |o| {
                    const rec = r.identRec(o);
                    if (rec.kind == .tomb and earlier.has(rec.a) and !opts.pre_ended and !got.flat) try twice(r, st, inst, opts.callee);
                    if (rec.kind != .object) continue;
                    ended = try ended.with(r.arena, o);
                    try r.end(st, inst, o, event);
                    if (kill.on_fail) try fail_ends.append(r.arena, .{ .id = o, .event = event });
                }
                try r.endRegion(st, inst, got.obj, event);
            },
            .value, .content, .view => {
                // A call that is known not to reallocate (room was made) moves nothing, whatever its body may do.
                if (opts.skip_content_kills) continue;
                if (got.place) |pl| try r.objectAlive(st, inst, pl);
                const many = got.flat or (if (got.place) |pl| r.places.hasElem(pl) else false);
                const event: Event = .{ .loc = inst.loc, .text = try std.fmt.allocPrint(r.arena, "`{s}` invalidates pointers into `{s}` here", .{ opts.callee, where }), .trail = st.trail, .soft = opts.soft or many, .with = gate.with, .open = gate.open or kill.lost, .lost = gate.lost or kill.lost };
                for (got.ids.ids) |id| if (!r.pointees.contains(id)) switch (r.identRec(id).kind) {
                    .object => {
                        try r.end(st, inst, id, event);
                        try r.endRegion(st, inst, try Set.single(r.arena, id), event);
                    },
                    .tomb => if (earlier.has(r.identRec(id).a)) {
                        if (!opts.pre_ended and !got.flat) try twice(r, st, inst, opts.callee);
                    } else if (!got.flat and !opts.pre_ended and earlierEvent(r, id, inst)) try r.tally("maybe_alias", inst),
                    .heap, .init => {
                        ended = try ended.with(r.arena, id);
                        if (k.param < ended_by.len) ended_by[k.param] = try ended_by[k.param].with(r.arena, id);
                        if (k.param == 0 and !got.flat) reallocated = try reallocated.with(r.arena, id);
                        try r.end(st, inst, id, event);
                        if (kill.on_fail) try fail_ends.append(r.arena, .{ .id = id, .event = event }) else if (st.dead.get(id)) |d| try ok_ends.append(r.arena, .{ .id = id, .event = event, .tomb = try r.tomb(id, d.soft) });
                        killed = try killed.with(r.arena, try r.tomb(id, event.soft or st.multi.has(id)));
                    },
                    else => {},
                };
            },
        }
    }
    for (args, 0..) |a, i| {
        if (i >= 64 or s.frees & (@as(u64, 1) << @intCast(i)) == 0) continue;
        if (i < ended_by.len) ended_by[i] = try ended_by[i].merge(r.arena, a.ids);
        try endIds(r, st, inst, a, r.callName(inst), null, true);
    }
    if (fail_ends.items.len != 0 and r.ty.kind(inst.ty) == .error_union) try r.fail_ends.put(r.arena, inst.id, fail_ends.items) else _ = r.fail_ends.remove(inst.id);
    if (ok_ends.items.len != 0 and r.ty.kind(inst.ty) == .error_union) try r.ok_ends.put(r.arena, inst.id, ok_ends.items) else _ = r.ok_ends.remove(inst.id);
    // Freed on some paths only: the checker cannot tell whether it happened, so the argument is stale only if it did.
    for (args, 0..) |a, i| {
        if (i >= 64 or s.maybe_frees & (@as(u64, 1) << @intCast(i)) == 0) continue;
        const event: Event = .{ .loc = inst.loc, .text = try std.fmt.allocPrint(r.arena, "`{s}` may free it", .{opts.callee}), .trail = st.trail, .soft = true };
        for (a.ids.ids) |o| switch (r.identRec(o).kind) {
            .heap, .init => try r.end(st, inst, o, event),
            else => {},
        };
    }
    try overlap(r, st, inst, s, args, tys, ended_by, opts.callee);
    try readsEnded(r, st, inst, args, tys, reallocated, opts.callee);
    // What the callee gives back from a block it also ended is, on the paths where it ended it, the new block.
    for (leaves) |*v| {
        const live = try v.ids.minus(r.arena, ended);
        if (!live.isEmpty()) v.ids = live;
    }

    for (s.writes, written) |w, v| {
        const got = try resolve(r, st, w.into, args, tys, false);
        if (got.blind) continue;
        const dst = args[w.into.param];
        // An entry of a container that holds a pointer to a local may be taken out again before the return.
        if (opts.library) {
            try r.escapesInto(st, inst, v, r.isLocalPtr(dst), "stored by the callee into memory that outlives it", dst.place);
        } else try r.escapes(st, inst, v, r.isLocalPtr(dst), "stored by the callee into memory that outlives it");
        const pl = got.place orelse continue;
        // What std's containers hold is not followed (an element is one of many).
        if (opts.library and r.places.hasElem(pl)) continue;
        if (w.into.kind == .object) {
            try r.writeObj(st, pl, v.obj);
            continue;
        }
        var stored = v;
        stored.obj = .empty;
        // The callee ended some of what it also leaves in the slot only on the paths where it left it; the slot read
        // afterwards holds the new memory, the stale pointers held elsewhere keep the tombstone.
        const live = try stored.ids.minus(r.arena, ended);
        if (!live.isEmpty()) stored.ids = live;
        const strong = w.must and r.strongAt(pl);
        if (!strong and !killed.isEmpty()) {
            // What the call ended is not what the place holds afterwards on the path where it wrote.
            var old = try r.readLeaf(st, pl, .none, false);
            old.ids = try old.ids.minus(r.arena, killed);
            try r.writeLeafAs(st, pl, old, true);
        }
        try r.writeLeafAs(st, pl, stored, strong);
    }

    // The result.
    var shaped: Val = .none;
    for (leaves, s.ret) |v, l| shaped = try place(r, shaped, inst.ty, l.path, v, 0);
    if (res.toks.isEmpty()) {
        const keep_moved = res.moved;
        res.* = shaped;
        res.moved = keep_moved;
    } else {
        res.ids = shaped.ids;
        res.obj = shaped.obj;
    }
    if (ret_place) |pl| res.place = pl;
}

/// Puts the leaf `v` at `path` inside the value `base` of type `ty`.
fn place(r: *Run, base: Val, ty: schema.TypeId, path: []const u32, v: Val, depth: u32) Allocator.Error!Val {
    if (path.len == 0) {
        var out = base;
        out.ids = try base.ids.merge(r.arena, v.ids);
        out.obj = try base.obj.merge(r.arena, v.obj);
        out.maybe = base.maybe or v.maybe;
        out.con = v.con;
        return out;
    }
    if (path[0] == dom.obj_step) {
        var out = base;
        out.obj = try base.obj.merge(r.arena, v.obj);
        out.ids = try base.ids.merge(r.arena, v.ids);
        return out;
    }
    const fields = if (depth < 6) r.ty.structFields(ty) else null;
    if (fields == null or path[0] >= fields.?.len) {
        var out = base;
        out.ids = try base.ids.merge(r.arena, v.ids);
        out.obj = try base.obj.merge(r.arena, v.obj);
        out.maybe = base.maybe or v.maybe;
        return out;
    }
    const parts = try r.arena.alloc(Val, fields.?.len);
    for (parts, 0..) |*p, k| p.* = if (base.parts) |bp| (if (k < bp.len) bp[k] else .none) else .none;
    parts[path[0]] = try place(r, parts[path[0]], fields.?[path[0]].ty, path[1..], v, depth + 1);
    var out = try Val.aggregate(r.arena, parts);
    out.obj = base.obj;
    return out;
}

fn earlierEvent(r: *Run, id: dom.Id, inst: *const Inst) bool {
    const e = r.tomb_events.get(id) orelse return false;
    return e.loc != inst.loc;
}
