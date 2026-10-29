//! Verification conditions from AIR. One function is run symbolically: every instruction yields a
//! value (a term, or a structured aggregate of terms), memory cells hold the mutable locals, and control
//! flow is followed with path conditions and joined by if-then-else. Every way the function can go wrong
//! becomes an obligation `pc => goal`; the contracts (`zv.requires`, `zv.ensures`, `zv.invariant`) are
//! recognized by the callee name of their inlined call and give assumptions and obligations of their own.
//! Loops are cut at their invariant: modified cells are havoced, the invariant is assumed, one iteration is
//! run, and the invariant is obligated again where the iteration repeats.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zv_air = @import("zv_air");
const schema = zv_air.schema;
const term = @import("term.zig");
const value = @import("value.zig");
const Term = term.Term;
const Pool = term.Pool;
const Value = value.Value;
const Ctx = value.Ctx;
const Inst = schema.Inst;
const Tag = schema.Tag;

pub const Error = value.Error;

pub const Kind = enum {
    overflow,
    /// An operation Zig does not check here (safety is off) and leaves undefined on overflow: neither a panic nor a wrap.
    unchecked,
    division,
    bounds,
    cast,
    shift,
    panic,
    unreachable_code,
    precondition,
    postcondition,
    invariant_entry,
    invariant_step,
    termination,
    /// The specification itself is ill-defined: it does not count as the function doing something first.
    ghost,
    other,
};

pub const Local = struct { name: []const u8, value: Term, signed: bool };

pub const Obligation = struct {
    kind: Kind,
    text: []const u8,
    loc: schema.LocId,
    pc: Term,
    goal: Term,
    locals: []const Local,
    /// The path abstracts a loop, so a counterexample may not be a real execution.
    approx: bool,
};

pub const Unsupported = struct { reason: []const u8, loc: schema.LocId };

const NameNode = struct { prev: ?*const NameNode, local: Local };

const State = struct {
    pc: Term,
    cells: []Value,
    names: ?*const NameNode,
    /// The path went through a loop abstracted by its invariant.
    cut: bool = false,
    /// The tokens that some operation or call on the path consumed, and when.
    dead: []const Dead = &.{},

    fn clone(s: State, arena: Allocator) Allocator.Error!State {
        var c = s;
        c.cells = try arena.dupe(Value, s.cells);
        return c;
    }
};

const Dead = struct { token: u32, cond: Term };

const Incoming = struct { state: State, value: Value };

/// An `ensures` call: what it promised and the value it returns.
pub const Site = struct { ok: Term, value: Value };

const Return = struct { state: State, value: Value, site: ?Site };

const BlockCtx = struct { incoming: std.ArrayList(Incoming) = .empty };

/// What the head of a loop body states: invariants (a condition) and decreasing measures (a term).
const Collected = struct { id: u32, kind: enum { invariant, decreases }, term: Term, ghost: bool = false };

const LoopCtx = struct {
    head: []const Collected,
    /// The tokens that existed when the body started, and the ones already consumed: an iteration may not consume more.
    token_base: u32 = 0,
    dead: []const Dead = &.{},
};

/// What a caller may use of a function: its precondition on the parameters, and a postcondition on the
/// parameters and the result placeholder, each in terms of this function's own variables.
pub const Summary = struct {
    name: []const u8,
    params: []const Value,
    lazy: []const value.Lazy,
    pre: Term,
    post: Term,
    result: Value,
    /// The pointer parameters whose pointee the function may change.
    ptrs: []const PtrSummary = &.{},
    /// The callee as the program names it, and whether it is `.trusted`: its contract and its safety are assumed.
    callee: []const u8 = "",
    trusted: bool = false,
};

/// A pointer-to-struct parameter: the pointee at entry, the pointee at each return as a placeholder (`out`), and which
/// fields the function may have changed. A field not in `touched` is what the caller had.
pub const PtrSummary = struct {
    index: usize,
    ty: schema.TypeId,
    entry: Value,
    out: Value,
    touched: []const u32,
    all: bool,
};

const PtrParam = struct { index: usize, cell: u32, ty: schema.TypeId, entry: Value };

/// How a run finds the summary of a function it calls.
pub const Hooks = struct {
    context: *anyopaque,
    summaryFn: *const fn (context: *anyopaque, caller: *Vc, name: []const u8) Error!*const Summary,
};

pub const Options = struct {
    param_names: []const []const u8 = &.{},
    /// Prefixed to the variables of the parameters: functions share one pool and must not share a variable.
    prefix: []const u8 = "",
    hooks: ?Hooks = null,
    field_names: ?value.FieldNames = null,
};

const Stop = error{StopPure};

const StepError = Error || Stop;

pub const Vc = struct {
    gpa: Allocator,
    ctx: Ctx,
    pool: *Pool,
    pack: *const schema.Pack,
    func: schema.Func,
    param_names: []const []const u8,

    by_id: []?*const Inst,
    values: []Value,
    cell_of: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    cell_names: std.ArrayList(?[]const u8) = .empty,
    cell_signed: std.ArrayList(bool) = .empty,
    blocks: std.AutoHashMapUnmanaged(u32, *BlockCtx) = .empty,
    loops: std.AutoHashMapUnmanaged(u32, *LoopCtx) = .empty,
    head_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,
    obligations: std.ArrayList(Obligation) = .empty,
    returns: std.ArrayList(Return) = .empty,
    sites: std.AutoHashMapUnmanaged(u32, Site) = .empty,
    param_values: std.ArrayList(Value) = .empty,
    pre: Term,
    hooks: ?Hooks,
    inline_names: std.ArrayList([]const u8) = .empty,
    /// Loops that state no measure, so nothing shows that they stop.
    unbounded_loops: std.ArrayList(schema.LocId) = .empty,
    /// The summaries this function relied on at its calls: each is a promise that must be kept elsewhere.
    relied: std.ArrayList(*const Summary) = .empty,
    /// The `zv.assume` calls on live paths: each is a premise the proof takes without proving it.
    assumed: std.ArrayList(schema.LocId) = .empty,
    unsupported: ?Unsupported = null,
    loc: schema.LocId = .none,
    has_token: std.AutoHashMapUnmanaged(schema.TypeId, bool) = .empty,
    ptr_params: std.ArrayList(PtrParam) = .empty,
    /// The last instruction that finished, debug markers aside: a `return` of a constant follows its `zv.ensures`.
    latest: ?*const Inst = null,
    arg_cell: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    pure: bool = false,
    pure_seen: bool = false,
    /// How many contracts the head being collected has: the collection stops after the last one.
    pure_target: usize = 0,
    pure_base: usize = 0,
    collected: std.ArrayList(Collected) = .empty,
    obligations_seen: bool = false,

    pub fn arena(v: *Vc) Allocator {
        return v.ctx.arena;
    }

    pub fn init(gpa: Allocator, arena_alloc: Allocator, pool: *Pool, pack: *const schema.Pack, func: schema.Func, options: Options) Allocator.Error!Vc {
        var max_id: u32 = 0;
        scanMax(pack, pack.instsOf(func.insts), &max_id);
        const by_id = try arena_alloc.alloc(?*const Inst, max_id + 1);
        @memset(by_id, null);
        var v: Vc = .{
            .gpa = gpa,
            .ctx = .{ .pool = pool, .pack = pack, .arena = arena_alloc, .prefix = options.prefix, .field_names = options.field_names },
            .pool = pool,
            .pack = pack,
            .func = func,
            .param_names = options.param_names,
            .pre = try pool.tru(),
            .hooks = options.hooks,
            .by_id = by_id,
            .values = try arena_alloc.alloc(Value, max_id + 1),
        };
        @memset(v.values, .none);
        try v.indexInsts(pack.instsOf(func.insts));
        return v;
    }

    fn scanMax(pack: *const schema.Pack, insts: []const Inst, max: *u32) void {
        for (insts) |*inst| {
            max.* = @max(max.*, inst.id);
            for (pack.bodiesOf(inst.*)) |b| scanMax(pack, pack.instsOf(b.insts), max);
        }
    }

    fn indexInsts(v: *Vc, insts: []const Inst) Allocator.Error!void {
        for (insts) |*inst| {
            v.by_id[inst.id] = inst;
            if (inst.tag == .alloc) {
                try v.cell_of.put(v.arena(), inst.id, @intCast(v.cell_names.items.len));
                try v.cell_names.append(v.arena(), null);
                const pointee = v.ctx.typeRec(inst.ty).child;
                try v.cell_signed.append(v.arena(), if (v.ctx.intInfo(pointee)) |i| i.signed else false);
            }
            for (v.pack.bodiesOf(inst.*)) |b| try v.indexInsts(v.pack.instsOf(b.insts));
        }
    }

    pub fn inputs(v: *const Vc) []const value.Input {
        return v.ctx.inputs.items;
    }

    // Entry point.

    /// Runs the function from its entry with symbolic parameters.
    pub fn run(v: *Vc) Allocator.Error!void {
        v.runInner() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => v.unsupported = .{ .reason = v.ctx.reason, .loc = v.loc },
            error.StopPure => unreachable,
        };
    }

    /// A single-item pointer to a struct: the one kind of pointer parameter a function may take. The pointee is a
    /// cell of its own, so the function reads and writes it like a local, and the caller's summary says what changed.
    fn pointsToStruct(v: *const Vc, ty: schema.TypeId) ?schema.TypeId {
        const t = v.ctx.typeRec(ty);
        if (t.kind != .pointer or t.flags.size != .one or t.child == .none) return null;
        return if (v.ctx.typeRec(t.child).kind == .@"struct") t.child else null;
    }

    fn runInner(v: *Vc) StepError!void {
        const pool = v.pool;
        const params = v.pack.paramsOf(v.func);
        for (v.pack.instsOf(v.func.insts)) |*inst| {
            if (inst.tag != .arg) break;
            if (v.pointsToStruct(inst.ty) == null) continue;
            const cell: u32 = @intCast(v.cell_names.items.len);
            try v.cell_names.append(v.arena(), null);
            try v.cell_signed.append(v.arena(), false);
            try v.arg_cell.put(v.arena(), inst.id, cell);
        }
        var st: State = .{
            .pc = try pool.tru(),
            .cells = try v.arena().alloc(Value, v.cell_names.items.len),
            .names = null,
        };
        @memset(st.cells, .none);
        for (v.pack.instsOf(v.func.insts)) |*inst| {
            if (inst.tag != .arg) break;
            const index = v.attrInt(inst, .index) orelse return v.ctx.unsupported("argument without an index", .{});
            const given = if (index < v.param_names.len) v.param_names[index] else "_";
            const name = if (std.mem.eql(u8, given, "_")) try std.fmt.allocPrint(v.arena(), "arg{d}", .{index}) else given;
            if (index >= params.len or params[index].ty != inst.ty) return v.ctx.unsupported("argument {d} is not a parameter of the declared signature (a comptime parameter)", .{index});
            if (v.pointsToStruct(inst.ty)) |pointee| {
                const cell = v.arg_cell.get(inst.id).?;
                const entry = try v.ctx.symbolic(name, pointee, true);
                st.cells[cell] = entry;
                const val: Value = .{ .place = .{ .cell = cell, .path = &.{} } };
                try v.param_values.append(v.arena(), val);
                try v.ptr_params.append(v.arena(), .{ .index = index, .cell = cell, .ty = pointee, .entry = entry });
                v.values[inst.id] = val;
                continue;
            }
            const val = try v.ctx.symbolic(name, params[index].ty, true);
            try v.param_values.append(v.arena(), val);
            v.values[inst.id] = val;
            if (val == .slice) if (v.sentinelOf(inst.ty)) |sentinel| {
                const held = try pool.eq(try pool.select(val.slice.mem, val.slice.len), try pool.bv(sentinel.bits, sentinel.value));
                st.pc = try pool.@"and"(st.pc, held);
                v.pre = try pool.@"and"(v.pre, held);
            };
        }
        try v.exec(v.pack.instsOf(v.func.insts), &st);
    }

    /// The sentinel of a slice type, when its name states one as an integer: `[:0]const u8`.
    fn sentinelOf(v: *const Vc, ty: schema.TypeId) ?struct { bits: u16, value: u128 } {
        const t = v.ctx.typeRec(ty);
        const elem = v.ctx.intInfo(t.child) orelse return null;
        const name = v.ctx.typeName(ty);
        if (!std.mem.startsWith(u8, name, "[:")) return null;
        const end = std.mem.indexOfScalar(u8, name, ']') orelse return null;
        const sentinel = std.fmt.parseInt(u128, name[2..end], 0) catch return null;
        if (elem.bits < 128 and sentinel >> @intCast(elem.bits) != 0) return null;
        return .{ .bits = elem.bits, .value = sentinel };
    }

    // Attribute and operand access.

    fn attrInt(v: *const Vc, inst: *const Inst, key: schema.AttrKey) ?u32 {
        for (v.pack.attrsOf(inst.*)) |a| if (a.key == key) return a.value;
        return null;
    }

    fn attrStr(v: *const Vc, inst: *const Inst, key: schema.AttrKey) ?[]const u8 {
        for (v.pack.attrsOf(inst.*)) |a| if (a.key == key) return switch (key.kind()) {
            .callee => v.pack.calleeName(@fromBackingInt(@intCast(a.value))),
            else => v.pack.str(@fromBackingInt(@intCast(a.value))),
        };
        return null;
    }

    fn ops(v: *const Vc, inst: *const Inst) []const schema.Operand {
        return v.pack.operandsOf(inst.*);
    }

    fn operand(v: *Vc, o: schema.Operand) Error!Value {
        switch (o.kind) {
            .none => return .none,
            .inst => return v.values[o.value],
            .constant => return v.constValue(o.value),
        }
    }

    fn arg(v: *Vc, inst: *const Inst, i: usize) Error!Value {
        return v.operand(v.ops(inst)[i]);
    }

    fn scalarArg(v: *Vc, inst: *const Inst, i: usize) Error!Term {
        return switch (try v.arg(inst, i)) {
            .scalar => |t| t,
            else => v.ctx.unsupported("operand {d} of {t} is not a scalar", .{ i, inst.tag }),
        };
    }

    fn operandType(v: *const Vc, o: schema.Operand) schema.TypeId {
        return switch (o.kind) {
            .none => .none,
            .inst => if (v.by_id[o.value]) |i| i.ty else .none,
            .constant => v.pack.t.consts[o.value].ty,
        };
    }

    fn intTypeOf(v: *Vc, ty: schema.TypeId) Error!value.IntInfo {
        return v.ctx.intInfo(ty) orelse v.ctx.unsupported("integer type {s}", .{if (ty == .none) "?" else v.ctx.typeName(ty)});
    }

    fn constValue(v: *Vc, id: u32) Error!Value {
        const pool = v.pool;
        const c = v.pack.t.consts[id];
        switch (c.kind) {
            .void, .type, .func => return .none,
            .undef => {
                if (c.ty != .none) if (v.ctx.scalarSort(c.ty)) |sort| return .{ .scalar = try pool.fresh("undef", sort) };
                return .none;
            },
            .bool => return .{ .scalar = try pool.boolean(c.a != 0) },
            .int => {
                if (c.ty != .none) {
                    const t = v.ctx.typeRec(c.ty);
                    if (t.kind == .int and t.flags.signed and t.bits == term.ghost_bits) return .{ .scalar = try pool.bvSigned(t.bits, @as(i64, @bitCast(c.a))) };
                }
                const info = try v.intTypeOf(c.ty);
                return .{ .scalar = try pool.bv(info.bits, if (info.signed) @as(u128, @bitCast(@as(i128, @as(i64, @bitCast(c.a))))) else c.a) };
            },
            .null => {
                const t = v.ctx.typeRec(c.ty);
                const payload = try v.ctx.symbolic("null.payload", t.child, false);
                return .{ .opt = try v.ctx.create(value.Opt, .{ .has = try pool.fls(), .payload = payload }) };
            },
            .@"error" => return v.errorValue(c.ty, v.pack.str(@fromBackingInt(@intCast(c.a)))),
            .text => {
                const text = v.pack.str(@fromBackingInt(@intCast(c.a)));
                if (std.mem.startsWith(u8, text, "error.")) return v.errorValue(c.ty, text["error.".len..]);
                if (v.ctx.intInfo(c.ty)) |info| if (std.fmt.parseInt(i256, text, 10)) |n| return .{ .scalar = try pool.bvSigned(info.bits, n) } else |_| {};
                return v.ctx.unsupported("constant {s}", .{text});
            },
            else => return v.ctx.unsupported("constant of kind {t}", .{c.kind}),
        }
    }

    /// An error constant: a bare code, or, where the type is an error union, the union holding it.
    fn errorValue(v: *Vc, ty: schema.TypeId, name: []const u8) Error!Value {
        const number = try v.pool.errorCode(name) orelse return v.ctx.unsupported("more than 65535 distinct errors", .{});
        const code = try v.pool.bv(value.error_bits, number);
        if (ty == .none or v.ctx.typeRec(ty).kind != .error_union) return .{ .scalar = code };
        return .{ .eu = try v.ctx.create(value.Eu, .{ .is_err = try v.pool.tru(), .err = code, .payload = .none }) };
    }

    // States.

    fn alive(v: *const Vc, st: *const State) bool {
        return !v.pool.isFalse(st.pc);
    }

    fn kill(v: *Vc, st: *State) Allocator.Error!void {
        st.pc = try v.pool.fls();
    }

    fn join(v: *Vc, list: []const Incoming) Error!?Incoming {
        const pool = v.pool;
        var acc: ?Incoming = null;
        for (list) |inc| {
            if (!v.alive(&inc.state)) continue;
            const a = acc orelse {
                acc = inc;
                continue;
            };
            const cond = a.state.pc;
            const cells = try v.arena().alloc(Value, a.state.cells.len);
            for (cells, a.state.cells, inc.state.cells) |*out, x, y| {
                out.* = if (std.meta.eql(x, y)) x else try v.ctx.merge(cond, x, y);
            }
            acc = .{
                .state = .{
                    .pc = try pool.@"or"(a.state.pc, inc.state.pc),
                    .cells = cells,
                    .names = if (a.state.names == inc.state.names) a.state.names else commonNames(a.state.names, inc.state.names),
                    .cut = a.state.cut or inc.state.cut,
                    .dead = try unionDead(v.arena(), a.state.dead, inc.state.dead),
                },
                .value = try v.ctx.merge(cond, a.value, inc.value),
            };
        }
        return acc;
    }

    /// The names both paths share: the common tail of two persistent lists.
    fn commonNames(a: ?*const NameNode, b: ?*const NameNode) ?*const NameNode {
        var x = a;
        while (x) |xn| : (x = xn.prev) {
            var y = b;
            while (y) |yn| : (y = yn.prev) if (xn == yn) return xn;
        }
        return null;
    }

    // Obligations.

    fn oblige(v: *Vc, st: *State, inst: ?*const Inst, kind: Kind, comptime fmt: []const u8, args: anytype, goal: Term) Error!void {
        if (v.pure or v.pool.isTrue(goal) or !v.alive(st)) return;
        var locals: std.ArrayList(Local) = .empty;
        var it = st.names;
        while (it) |n| : (it = n.prev) try locals.append(v.arena(), n.local);
        for (st.cells, v.cell_names.items) |cell, name| {
            if (name == null) continue;
            if (cell == .scalar) try locals.append(v.arena(), .{ .name = name.?, .value = cell.scalar, .signed = false });
        }
        for (locals.items) |*l| {
            for (v.cell_names.items, v.cell_signed.items) |name, signed| {
                if (name != null and std.mem.eql(u8, name.?, l.name)) l.signed = signed;
            }
        }
        try v.obligations.append(v.arena(), .{
            .kind = kind,
            .text = try std.fmt.allocPrint(v.arena(), fmt, args),
            .loc = if (inst) |i| (if (i.loc != .none) i.loc else v.loc) else v.loc,
            .pc = st.pc,
            .goal = goal,
            .locals = locals.items,
            .approx = st.cut,
        });
        if (kind != .ghost) v.obligations_seen = true;
        st.pc = try v.pool.@"and"(st.pc, goal);
    }

    // Execution.

    fn exec(v: *Vc, body: []const Inst, st: *State) StepError!void {
        for (body) |*inst| {
            if (!v.alive(st)) return;
            try v.step(inst, st);
            switch (inst.tag) {
                .dbg_stmt, .dbg_empty_stmt, .dbg_var_ptr, .dbg_var_val, .dbg_arg_inline => {},
                else => v.latest = inst,
            }
        }
    }

    fn setResult(v: *Vc, inst: *const Inst, val: Value) void {
        v.values[inst.id] = val;
    }

    fn setScalar(v: *Vc, inst: *const Inst, t: Term) void {
        v.values[inst.id] = .{ .scalar = t };
    }

    fn step(v: *Vc, inst: *const Inst, st: *State) StepError!void {
        const pool = v.pool;
        if (inst.loc != .none) v.loc = inst.loc;
        if (v.pure and v.pure_seen) switch (inst.tag) {
            .dbg_stmt, .dbg_empty_stmt, .save_err_return_trace_index => return,
            .dbg_inline_block => switch (contractOf(v.attrStr(inst, .callee) orelse "") orelse return error.StopPure) {
                .invariant, .decreases => {},
                else => return error.StopPure,
            },
            else => return error.StopPure,
        };
        if (inst.ty == .none) return v.ctx.unsupported("instruction {t} is not decoded in the pack", .{inst.tag});
        switch (inst.tag) {
            .arg => {},
            .dbg_stmt, .dbg_empty_stmt, .save_err_return_trace_index, .set_err_return_trace, .err_return_trace, .dbg_arg_inline => {},
            .dbg_var_ptr => {
                const o = v.ops(inst)[0];
                if (o.kind == .inst) if (v.cell_of.get(o.value)) |cell| {
                    if (v.attrStr(inst, .name)) |n| v.cell_names.items[cell] = n;
                };
            },
            .dbg_var_val => {
                const o = v.ops(inst)[0];
                if (v.attrStr(inst, .name)) |n| if (try v.operand(o) == .scalar) {
                    const sc = (try v.operand(o)).scalar;
                    const info = v.ctx.intInfo(v.operandType(o));
                    const node = try v.arena().create(NameNode);
                    node.* = .{ .prev = st.names, .local = .{ .name = n, .value = sc, .signed = if (info) |i| i.signed else false } };
                    st.names = node;
                };
            },

            .alloc => {
                const cell = v.cell_of.get(inst.id).?;
                st.cells[cell] = .none;
                v.setResult(inst, .{ .place = .{ .cell = cell, .path = &.{} } });
            },
            .store, .store_safe => {
                const p = try v.arg(inst, 0);
                if (p != .place) return v.ctx.unsupported("store through {t}", .{std.meta.activeTag(p)});
                const new = try v.arg(inst, 1);
                st.cells[p.place.cell] = try v.update(st.cells[p.place.cell], p.place.path, new);
            },
            .load => {
                const p = try v.arg(inst, 0);
                switch (p) {
                    .place => |pl| {
                        try v.livePath(st, st.cells[pl.cell], pl.path);
                        v.setResult(inst, try v.read(st.cells[pl.cell], pl.path, inst.ty));
                    },
                    .elem_ptr => |e| v.setScalar(inst, try pool.select(e.mem, e.off)),
                    else => return v.ctx.unsupported("load through {t}", .{std.meta.activeTag(p)}),
                }
            },
            .ptr_cast, .addrspace_cast => {
                if (!v.sameLayoutPointee(inst)) return v.ctx.unsupported("a pointer cast to a pointee of another layout", .{});
                v.setResult(inst, try v.arg(inst, 0));
            },
            .struct_field_ptr, .struct_field_ptr_index_0, .struct_field_ptr_index_1, .struct_field_ptr_index_2, .struct_field_ptr_index_3 => {
                const p = try v.arg(inst, 0);
                if (p != .place) return v.ctx.unsupported("field pointer of {t}", .{std.meta.activeTag(p)});
                const index: u32 = switch (inst.tag) {
                    .struct_field_ptr_index_0 => 0,
                    .struct_field_ptr_index_1 => 1,
                    .struct_field_ptr_index_2 => 2,
                    .struct_field_ptr_index_3 => 3,
                    else => v.attrInt(inst, .field) orelse return v.ctx.unsupported("field pointer without an index", .{}),
                };
                const owner = v.ctx.typeRec(v.operandType(v.ops(inst)[0])).child;
                v.setResult(inst, .{ .place = .{ .cell = p.place.cell, .path = try append(v.arena(), p.place.path, .{ .field = .{ .index = index, .owner = owner } }) } });
            },
            .optional_payload_ptr, .optional_payload_ptr_set => {
                const p = try v.arg(inst, 0);
                if (p != .place) return v.ctx.unsupported("optional payload pointer of {t}", .{std.meta.activeTag(p)});
                if (inst.tag == .optional_payload_ptr_set) {
                    const cur = peek(st.cells[p.place.cell], p.place.path);
                    const payload: Value = if (cur == .opt) cur.opt.payload else .none;
                    const set: Value = .{ .opt = try v.ctx.create(value.Opt, .{ .has = try pool.tru(), .payload = payload }) };
                    st.cells[p.place.cell] = try v.update(st.cells[p.place.cell], p.place.path, set);
                }
                v.setResult(inst, .{ .place = .{ .cell = p.place.cell, .path = try append(v.arena(), p.place.path, .payload) } });
            },
            .ptr_slice_len_ptr, .ptr_slice_ptr_ptr => {
                const p = try v.arg(inst, 0);
                if (p != .place) return v.ctx.unsupported("slice field pointer of {t}", .{std.meta.activeTag(p)});
                const step_: value.Step = if (inst.tag == .ptr_slice_len_ptr) .slice_len else .slice_ptr;
                v.setResult(inst, .{ .place = .{ .cell = p.place.cell, .path = try append(v.arena(), p.place.path, step_) } });
            },
            .agg_field_val => {
                const o = try v.arg(inst, 0);
                const index = v.attrInt(inst, .field) orelse return v.ctx.unsupported("field read without an index", .{});
                switch (o) {
                    .obj => |ob| {
                        try v.live(st, ob);
                        v.setResult(inst, try v.ctx.field(ob, index, inst.ty));
                    },
                    else => return v.ctx.unsupported("field {d} of {t}", .{ index, std.meta.activeTag(o) }),
                }
            },
            .slice_len => {
                const s = try v.arg(inst, 0);
                if (s != .slice) return v.ctx.unsupported("length of {t}", .{std.meta.activeTag(s)});
                v.setScalar(inst, s.slice.len);
            },
            .slice_ptr => {
                const s = try v.arg(inst, 0);
                if (s != .slice) return v.ctx.unsupported("pointer of {t}", .{std.meta.activeTag(s)});
                v.setResult(inst, .{ .elem_ptr = .{ .mem = s.slice.mem, .off = s.slice.off } });
            },
            .slice => {
                const p = try v.arg(inst, 0);
                const len = try v.scalarArg(inst, 1);
                if (p != .elem_ptr) return v.ctx.unsupported("slice of {t}", .{std.meta.activeTag(p)});
                v.setResult(inst, .{ .slice = .{ .mem = p.elem_ptr.mem, .off = p.elem_ptr.off, .len = len } });
            },
            .slice_elem_val, .slice_elem_ptr => {
                const s = try v.arg(inst, 0);
                if (s != .slice) return v.ctx.unsupported("element of {t}", .{std.meta.activeTag(s)});
                const i = try v.scalarArg(inst, 1);
                const at = try pool.bin(.add, s.slice.off, i);
                if (inst.tag == .slice_elem_val) v.setScalar(inst, try pool.select(s.slice.mem, at)) else v.setResult(inst, .{ .elem_ptr = .{ .mem = s.slice.mem, .off = at } });
            },
            .array_elem_val => {
                const a = try v.arg(inst, 0);
                if (a != .array) return v.ctx.unsupported("element of {t}", .{std.meta.activeTag(a)});
                v.setScalar(inst, try pool.select(a.array.mem, try v.scalarArg(inst, 1)));
            },
            .ptr_add, .ptr_sub => {
                const p = try v.arg(inst, 0);
                if (p != .elem_ptr) return v.ctx.unsupported("pointer arithmetic on {t}", .{std.meta.activeTag(p)});
                const n = try v.scalarArg(inst, 1);
                const off = try pool.bin(if (inst.tag == .ptr_add) .add else .sub, p.elem_ptr.off, n);
                v.setResult(inst, .{ .elem_ptr = .{ .mem = p.elem_ptr.mem, .off = off } });
            },
            .ptr_elem_val, .ptr_elem_ptr => {
                const p = try v.arg(inst, 0);
                if (p != .elem_ptr) return v.ctx.unsupported("element of {t}", .{std.meta.activeTag(p)});
                const at = try pool.bin(.add, p.elem_ptr.off, try v.scalarArg(inst, 1));
                if (inst.tag == .ptr_elem_val) v.setScalar(inst, try pool.select(p.elem_ptr.mem, at)) else v.setResult(inst, .{ .elem_ptr = .{ .mem = p.elem_ptr.mem, .off = at } });
            },

            .add, .add_safe, .sub, .sub_safe, .mul, .mul_safe => try v.checkedArith(inst, st),
            .add_wrap, .sub_wrap, .mul_wrap => {
                const a = try v.scalarArg(inst, 0);
                const b = try v.scalarArg(inst, 1);
                const op: term.Op = switch (inst.tag) {
                    .add_wrap => .add,
                    .sub_wrap => .sub,
                    else => .mul,
                };
                v.setScalar(inst, try pool.bin(op, a, b));
            },
            .div_trunc, .div_floor, .div_exact, .rem, .mod => try v.division(inst, st),
            .min, .max => {
                const a = try v.scalarArg(inst, 0);
                const b = try v.scalarArg(inst, 1);
                const info = try v.intTypeOf(inst.ty);
                const lt = try pool.cmp(if (info.signed) .slt else .ult, a, b);
                v.setScalar(inst, if (inst.tag == .min) try pool.ite(lt, a, b) else try pool.ite(lt, b, a));
            },
            .bit_and, .bit_or, .xor => {
                const a = try v.scalarArg(inst, 0);
                const b = try v.scalarArg(inst, 1);
                if (pool.sortOf(a) == .bool) {
                    v.setScalar(inst, switch (inst.tag) {
                        .bit_and => try pool.@"and"(a, b),
                        .bit_or => try pool.@"or"(a, b),
                        else => try pool.ne(a, b),
                    });
                } else {
                    v.setScalar(inst, try pool.bin(switch (inst.tag) {
                        .bit_and => .band,
                        .bit_or => .bor,
                        else => .bxor,
                    }, a, b));
                }
            },
            .clz, .ctz, .popcount => try v.bitCount(inst),
            .not => {
                const a = try v.scalarArg(inst, 0);
                v.setScalar(inst, if (pool.sortOf(a) == .bool) try pool.not(a) else try pool.bnot(a));
            },
            .shl, .shl_exact, .shr, .shr_exact => try v.shift(inst, st),
            .cmp_lt, .cmp_lte, .cmp_gt, .cmp_gte, .cmp_eq, .cmp_neq => try v.compare(inst),
            .int_cast, .int_cast_safe => try v.intCast(inst, st),
            .trunc => {
                const a = try v.scalarArg(inst, 0);
                const info = try v.intTypeOf(inst.ty);
                v.setScalar(inst, try pool.extract(a, info.bits - 1, 0));
            },
            .bit_cast, .bit_cast_safe => {
                const a = try v.arg(inst, 0);
                if (a != .scalar) {
                    if (v.operandType(v.ops(inst)[0]) != inst.ty) return v.ctx.unsupported("bit_cast of {t} to {s}", .{ std.meta.activeTag(a), v.ctx.typeName(inst.ty) });
                } else {
                    const have = pool.sortOf(a.scalar);
                    const want = v.ctx.scalarSort(inst.ty) orelse return v.ctx.unsupported("bit_cast to {s}", .{v.ctx.typeName(inst.ty)});
                    if (!have.eql(want)) {
                        const one = try pool.bv(1, 1);
                        if (have == .bool and want.eql(.{ .bv = 1 })) return v.setScalar(inst, try pool.ite(a.scalar, one, try pool.bv(1, 0)));
                        if (have.eql(.{ .bv = 1 }) and want == .bool) return v.setScalar(inst, try pool.eq(a.scalar, one));
                        return v.ctx.unsupported("bit_cast between widths", .{});
                    }
                }
                v.setResult(inst, a);
            },

            .is_non_null, .is_null => {
                const o = try v.arg(inst, 0);
                if (o != .opt) return v.ctx.unsupported("null test of {t}", .{std.meta.activeTag(o)});
                v.setScalar(inst, if (inst.tag == .is_non_null) o.opt.has else try pool.not(o.opt.has));
            },
            .optional_payload => {
                const o = try v.arg(inst, 0);
                if (o != .opt) return v.ctx.unsupported("payload of {t}", .{std.meta.activeTag(o)});
                v.setResult(inst, o.opt.payload);
            },
            .wrap_optional => v.setResult(inst, .{ .opt = try v.ctx.create(value.Opt, .{ .has = try pool.tru(), .payload = try v.arg(inst, 0) }) }),
            .is_err, .is_non_err => {
                const o = try v.arg(inst, 0);
                if (o != .eu) return v.ctx.unsupported("error test of {t}", .{std.meta.activeTag(o)});
                v.setScalar(inst, if (inst.tag == .is_err) o.eu.is_err else try pool.not(o.eu.is_err));
            },
            .unwrap_errunion_payload => {
                const o = try v.arg(inst, 0);
                if (o != .eu) return v.ctx.unsupported("payload of {t}", .{std.meta.activeTag(o)});
                v.setResult(inst, o.eu.payload);
            },
            .unwrap_errunion_err => {
                const o = try v.arg(inst, 0);
                if (o != .eu) return v.ctx.unsupported("error of {t}", .{std.meta.activeTag(o)});
                v.setScalar(inst, o.eu.err);
            },
            .wrap_errunion_payload => v.setResult(inst, .{ .eu = try v.ctx.create(value.Eu, .{
                .is_err = try pool.fls(),
                .err = try pool.bv(value.error_bits, 0),
                .payload = try v.arg(inst, 0),
            }) }),
            .wrap_errunion_err => {
                const payload: Value = .none;
                v.setResult(inst, .{ .eu = try v.ctx.create(value.Eu, .{ .is_err = try pool.tru(), .err = try v.scalarArg(inst, 0), .payload = payload }) });
            },
            .aggregate_init => {
                const t = v.ctx.typeRec(inst.ty);
                if (t.kind != .@"struct") return v.ctx.unsupported("aggregate of kind {t}", .{t.kind});
                const token = v.ctx.isToken(inst.ty);
                if (token and !v.insideTokenOp()) return v.ctx.unsupported("a token built outside the operations of zv.PointsTo", .{});
                const fields = try v.arena().alloc(value.Field, v.ops(inst).len);
                for (fields, v.ops(inst), 0..) |*f, o, i| f.* = .{ .index = @intCast(i), .value = try v.operand(o) };
                v.setResult(inst, .{ .obj = try v.ctx.create(value.Obj, .{ .base = null, .fields = fields, .ty = inst.ty, .token = if (token) v.ctx.newToken() else 0 }) });
            },

            .block => try v.block(inst, st, v.pack.bodiesOf(inst.*)[0]),
            .dbg_inline_block => try v.inlineBlock(inst, st),
            .br => {
                const target = v.attrInt(inst, .target) orelse return v.ctx.unsupported("br without a target", .{});
                const ctx = v.blocks.get(target) orelse return v.ctx.unsupported("br to a block that is not open", .{});
                const val = if (v.ops(inst).len > 0) try v.arg(inst, 0) else .none;
                try ctx.incoming.append(v.arena(), .{ .state = try st.clone(v.arena()), .value = val });
                try v.kill(st);
            },
            .cond_br => try v.condBr(inst, st),
            .loop => try v.loop(inst, st),
            .repeat => try v.repeat(inst, st),
            .ret, .ret_safe => {
                const val = try v.arg(inst, 0);
                try v.useTokens(st, val, v.func.ret, false);
                for (v.ptr_params.items) |p| try v.useTokens(st, st.cells[p.cell], p.ty, false);
                var site = v.siteOf(v.ops(inst)[0], val);
                // A value the compiler knew (`null`) is a constant operand, not the result of the `zv.ensures` that checked it.
                if (site == null and v.ops(inst)[0].kind == .constant) if (v.latest) |p| if (p.tag == .dbg_inline_block) if (v.sites.get(p.id)) |s| if (v.sameConstant(s.value, val)) {
                    site = .{ .ok = s.ok, .value = val };
                };
                try v.returns.append(v.arena(), .{ .state = try st.clone(v.arena()), .value = val, .site = site });
                try v.kill(st);
            },
            .@"try", .try_cold => {
                const o = try v.arg(inst, 0);
                if (o != .eu) return v.ctx.unsupported("try of {t}", .{std.meta.activeTag(o)});
                var failed = try st.clone(v.arena());
                failed.pc = try pool.@"and"(st.pc, o.eu.is_err);
                try v.exec(v.pack.instsOf(v.pack.bodiesOf(inst.*)[0].insts), &failed);
                if (v.alive(&failed)) return v.ctx.unsupported("the error path of try falls through", .{});
                st.pc = try pool.@"and"(st.pc, try pool.not(o.eu.is_err));
                v.setResult(inst, o.eu.payload);
            },
            .switch_br => try v.switchBr(inst, st),
            .unreach => {
                try v.oblige(st, inst, .unreachable_code, "unreachable code is reachable", .{}, try pool.fls());
                try v.kill(st);
            },
            .trap => {
                try v.oblige(st, inst, .panic, "trap is reachable", .{}, try pool.fls());
                try v.kill(st);
            },
            .call, .call_always_tail, .call_never_tail, .call_never_inline => try v.call(inst, st),
            else => return v.ctx.unsupported("instruction {t}", .{inst.tag}),
        }
    }

    /// The `ensures` that produced a returned value, possibly wrapped into an optional or error union.
    fn siteOf(v: *Vc, o: schema.Operand, val: Value) ?Site {
        if (o.kind != .inst) return null;
        if (v.sites.get(o.value)) |s| return s;
        const i = v.by_id[o.value] orelse return null;
        switch (i.tag) {
            .wrap_errunion_payload, .wrap_optional => {
                const inner = v.ops(i)[0];
                if (inner.kind == .inst) if (v.sites.get(inner.value)) |s| return .{ .ok = s.ok, .value = val };
            },
            else => {},
        }
        return null;
    }

    /// Whether two constants are the same value (a null optional has no payload to compare).
    fn sameConstant(v: *const Vc, a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .none => true,
            .scalar => |x| x == b.scalar,
            .opt => |x| x.has == b.opt.has and (v.pool.isFalse(x.has) or v.sameConstant(x.payload, b.opt.payload)),
            else => false,
        };
    }

    fn isConstant(v: *const Vc, val: Value) bool {
        return switch (val) {
            .none => true,
            .scalar => |t| switch (v.pool.node(t)) {
                .bool_lit, .bv_lit => true,
                else => false,
            },
            .opt => |o| v.isConstant(.{ .scalar = o.has }) and v.isConstant(o.payload),
            .eu => |e| v.isConstant(.{ .scalar = e.is_err }) and v.isConstant(.{ .scalar = e.err }) and v.isConstant(e.payload),
            .obj => |o| o.base == null and for (o.fields) |f| {
                if (!v.isConstant(f.value)) break false;
            } else true,
            else => false,
        };
    }

    fn append(arena_alloc: Allocator, path: []const value.Step, s: value.Step) Allocator.Error![]const value.Step {
        const out = try arena_alloc.alloc(value.Step, path.len + 1);
        @memcpy(out[0..path.len], path);
        out[path.len] = s;
        return out;
    }

    // Tokens (`zv.PointsTo`). A token is a linear value: it has an identity (`Obj.token`), it is consumed by the
    // operations of `zv.PointsTo` that say so and by being passed to a call, and a consumed token may not be used
    // again. Its fields are written only inside those operations, so no token is built, changed or copied out of
    // thin air: that is what lets a proof treat two tokens as disjoint memory.

    const TokenOp = zv_air.tokens.Op;

    const tokenOpOf = zv_air.tokens.opOf;

    /// Whether the code being run is the body of an operation of `zv.PointsTo`, the only code that may build a token.
    fn insideTokenOp(v: *const Vc) bool {
        for (v.inline_names.items) |name| if (zv_air.tokens.inside(name)) return true;
        return false;
    }

    fn unionDead(arena_alloc: Allocator, a: []const Dead, b: []const Dead) Allocator.Error![]const Dead {
        if (b.len == 0) return a;
        var out: std.ArrayList(Dead) = .empty;
        try out.appendSlice(arena_alloc, a);
        for (b) |d| {
            if (for (a) |e| {
                if (e.token == d.token and e.cond == d.cond) break true;
            } else false) continue;
            try out.append(arena_alloc, d);
        }
        return out.items;
    }

    /// When the token was consumed: the path condition at that point, or'ed over the paths that joined.
    fn consumedWhen(v: *Vc, st: *const State, token: u32) Allocator.Error!Term {
        var cond = try v.pool.fls();
        for (st.dead) |d| if (d.token == token) {
            cond = try v.pool.@"or"(cond, d.cond);
        };
        return cond;
    }

    fn markDead(v: *Vc, st: *State, token: u32) Allocator.Error!void {
        const d: Dead = .{ .token = token, .cond = st.pc };
        st.dead = try unionDead(v.arena(), st.dead, &.{d});
    }

    /// Obliges `o`, if it is a token, to be unconsumed on this path.
    fn live(v: *Vc, st: *State, o: *const value.Obj) StepError!void {
        if (o.token == 0) return;
        const gone = try v.consumedWhen(st, o.token);
        try v.oblige(st, null, .other, "a token is used after it was consumed", .{}, try v.pool.not(gone));
    }

    /// Whether a value of type `ty` is or holds a token by value.
    fn hasToken(v: *Vc, ty: schema.TypeId) Allocator.Error!bool {
        if (ty == .none) return false;
        if (v.has_token.get(ty)) |known| return known;
        try v.has_token.put(v.arena(), ty, false);
        const t = v.ctx.typeRec(ty);
        const found = switch (t.kind) {
            .@"struct" => blk: {
                if (v.ctx.isToken(ty)) break :blk true;
                for (v.pack.fieldsOf(ty) orelse &.{}) |f| if (try v.hasToken(f.ty)) break :blk true;
                break :blk false;
            },
            .optional, .error_union => try v.hasToken(t.child),
            else => false,
        };
        try v.has_token.put(v.arena(), ty, found);
        return found;
    }

    /// The tokens held by `val`, which has type `ty`; fields nothing read yet are made, so a token inside a
    /// parameter is found even if the function never touched it.
    fn tokensOf(v: *Vc, val: Value, ty: schema.TypeId, out: *std.ArrayList(*const value.Obj)) Error!void {
        if (!try v.hasToken(ty)) return;
        const t = v.ctx.typeRec(ty);
        switch (t.kind) {
            .@"struct" => {
                const o = switch (val) {
                    .obj => |o| o,
                    else => return,
                };
                if (v.ctx.isToken(ty)) return out.append(v.arena(), o);
                for (v.pack.fieldsOf(ty) orelse &.{}) |f| {
                    if (!try v.hasToken(f.ty)) continue;
                    try v.tokensOf(try v.ctx.field(o, f.index, f.ty), f.ty, out);
                }
            },
            .optional => if (val == .opt) try v.tokensOf(val.opt.payload, t.child, out),
            .error_union => if (val == .eu) try v.tokensOf(val.eu.payload, t.child, out),
            else => {},
        }
    }

    /// Obliges every token in `val` to be unconsumed; `consume` ends them.
    fn useTokens(v: *Vc, st: *State, val: Value, ty: schema.TypeId, consume: bool) StepError!void {
        var found: std.ArrayList(*const value.Obj) = .empty;
        try v.tokensOf(val, ty, &found);
        for (found.items) |o| {
            try v.live(st, o);
            if (consume) try v.markDead(st, o.token);
        }
    }

    fn tokenOpEnter(v: *Vc, inst: *const Inst, st: *State, op: TokenOp, args: []const schema.Operand) StepError!void {
        for (args) |a| try v.useTokens(st, try v.operand(a), v.operandType(a), false);
        if (op == .own and !v.pure and v.alive(st)) try v.assumed.append(v.arena(), if (inst.loc != .none) inst.loc else v.loc);
    }

    /// Obliges every token on the way down `path` into `cell` to be unconsumed: reading a field of a consumed
    /// token is a use of it.
    fn livePath(v: *Vc, st: *State, cell: Value, path: []const value.Step) StepError!void {
        var cur = cell;
        for (path) |walk| switch (walk) {
            .payload => cur = if (cur == .opt) cur.opt.payload else return,
            .field => |fs| {
                const o = switch (cur) {
                    .obj => |o| o,
                    else => return,
                };
                try v.live(st, o);
                cur = for (o.fields) |f| {
                    if (f.index == fs.index) break f.value;
                } else blk: {
                    const declared = v.pack.fieldsOf(fs.owner) orelse return;
                    const rec = for (declared) |d| {
                        if (d.index == fs.index) break d;
                    } else return;
                    if (!try v.hasToken(rec.ty)) return;
                    break :blk try v.ctx.field(o, fs.index, rec.ty);
                };
            },
            else => return,
        };
    }

    // Memory.

    fn read(v: *Vc, cell: Value, path: []const value.Step, ty: schema.TypeId) Error!Value {
        if (path.len == 0) return cell;
        switch (path[0]) {
            .field => |fstep| {
                const i = fstep.index;
                const o = switch (cell) {
                    .obj => |ob| ob,
                    else => return v.ctx.unsupported("field {d} of {t} in memory", .{ i, std.meta.activeTag(cell) }),
                };
                const f = try v.ctx.field(o, i, if (path.len == 1) ty else v.fieldType(fstep));
                return v.read(f, path[1..], ty);
            },
            .payload => {
                if (cell != .opt) return v.ctx.unsupported("optional payload of {t} in memory", .{std.meta.activeTag(cell)});
                return v.read(cell.opt.payload, path[1..], ty);
            },
            .slice_len => {
                if (cell != .slice) return v.ctx.unsupported("slice length of {t} in memory", .{std.meta.activeTag(cell)});
                return .{ .scalar = cell.slice.len };
            },
            .slice_ptr => {
                if (cell != .slice) return v.ctx.unsupported("slice pointer of {t} in memory", .{std.meta.activeTag(cell)});
                return .{ .elem_ptr = .{ .mem = cell.slice.mem, .off = cell.slice.off } };
            },
        }
    }

    /// What a place holds so far, `.none` where nothing was stored yet.
    fn peek(cell: Value, path: []const value.Step) Value {
        var cur = cell;
        for (path) |walk| switch (walk) {
            .payload => cur = if (cur == .opt) cur.opt.payload else return .none,
            .field => |fs| {
                const o = switch (cur) {
                    .obj => |o| o,
                    else => return .none,
                };
                cur = for (o.fields) |f| {
                    if (f.index == fs.index) break f.value;
                } else return .none;
            },
            else => return .none,
        };
        return cur;
    }

    /// The declared type of the field a step names, when the pack knows the struct.
    fn fieldType(v: *const Vc, fs: value.FieldStep) ?schema.TypeId {
        for (v.pack.fieldsOf(fs.owner) orelse return null) |d| if (d.index == fs.index) return d.ty;
        return null;
    }

    fn update(v: *Vc, cell: Value, path: []const value.Step, new: Value) Error!Value {
        if (path.len == 0) return new;
        switch (path[0]) {
            .field => |fstep| {
                const i = fstep.index;
                const o: *const value.Obj = switch (cell) {
                    .obj => |ob| ob,
                    .none => if (v.ctx.isToken(fstep.owner)) blk: {
                        if (!v.insideTokenOp()) return v.ctx.unsupported("a token built outside the operations of zv.PointsTo", .{});
                        break :blk try v.ctx.create(value.Obj, .{ .base = null, .fields = &.{}, .ty = fstep.owner, .token = v.ctx.newToken() });
                    } else try v.ctx.create(value.Obj, .{ .base = null, .fields = &.{} }),
                    else => return v.ctx.unsupported("field store into {t}", .{std.meta.activeTag(cell)}),
                };
                if (o.token != 0 and !v.insideTokenOp()) return v.ctx.unsupported("a token changed outside the operations of zv.PointsTo", .{});
                const inner: Value = for (o.fields) |f| {
                    if (f.index == i) break f.value;
                } else .none;
                return v.ctx.withField(o, i, try v.update(inner, path[1..], new));
            },
            .payload => {
                const o: *const value.Opt = switch (cell) {
                    .opt => |o| o,
                    .none => try v.ctx.create(value.Opt, .{ .has = try v.pool.tru(), .payload = .none }),
                    else => return v.ctx.unsupported("optional payload store into {t}", .{std.meta.activeTag(cell)}),
                };
                return .{ .opt = try v.ctx.create(value.Opt, .{ .has = o.has, .payload = try v.update(o.payload, path[1..], new) }) };
            },
            .slice_len => {
                if (cell != .slice or path.len != 1) return v.ctx.unsupported("store to a slice length", .{});
                return .{ .slice = .{ .mem = cell.slice.mem, .off = cell.slice.off, .len = new.scalar } };
            },
            .slice_ptr => return v.ctx.unsupported("store to a slice pointer", .{}),
        }
    }

    /// A pointer cast keeps the model's value only when the pointees have one layout: the same type, integers of
    /// one width, or arrays of such of one length. Anything else reads the same bits as another type.
    fn sameLayoutPointee(v: *const Vc, inst: *const Inst) bool {
        const from = v.operandType(v.ops(inst)[0]);
        if (from == .none or inst.ty == .none) return false;
        const f = v.ctx.typeRec(from);
        const t = v.ctx.typeRec(inst.ty);
        return f.kind == .pointer and t.kind == .pointer and v.sameLayout(f.child, t.child);
    }

    fn sameLayout(v: *const Vc, a: schema.TypeId, b: schema.TypeId) bool {
        if (a == b) return true;
        if (a == .none or b == .none) return false;
        const x = v.ctx.typeRec(a);
        const y = v.ctx.typeRec(b);
        if (x.kind != y.kind) return false;
        return switch (x.kind) {
            .int => x.bits == y.bits,
            .array => x.len == y.len and v.sameLayout(x.child, y.child),
            else => false,
        };
    }

    // Arithmetic.

    fn checkedArith(v: *Vc, inst: *const Inst, st: *State) StepError!void {
        const pool = v.pool;
        const a = try v.scalarArg(inst, 0);
        const b = try v.scalarArg(inst, 1);
        const info = try v.intTypeOf(inst.ty);
        const op: term.Op, const sym: []const u8 = switch (inst.tag) {
            .add, .add_safe => .{ .add, "+" },
            .sub, .sub_safe => .{ .sub, "-" },
            else => .{ .mul, "*" },
        };
        const ok = try v.noOverflow(op, a, b, info);
        if (inst.tag == .add or inst.tag == .sub or inst.tag == .mul)
            try v.oblige(st, inst, .unchecked, "overflow in unchecked `{s}` on {s}: undefined, not a panic and not a wrap", .{ sym, v.ctx.typeName(inst.ty) }, ok)
        else
            try v.oblige(st, inst, .overflow, "integer overflow in `{s}` on {s}", .{ sym, v.ctx.typeName(inst.ty) }, ok);
        v.setScalar(inst, try pool.bin(op, a, b));
    }

    /// The result of `a op b` fits the type.
    fn noOverflow(v: *Vc, op: term.Op, a: Term, b: Term, info: value.IntInfo) Allocator.Error!Term {
        const pool = v.pool;
        const w = info.bits;
        if (op == .mul) {
            if (!info.signed) return pool.mulFits(.umul_ok, a, b);
            return pool.@"and"(try pool.mulFits(.smul_hi_ok, a, b), try pool.mulFits(.smul_lo_ok, a, b));
        }
        const wide: u16 = w + 1;
        const ext = struct {
            fn f(p: *Pool, t: Term, to: u16, s: bool) Allocator.Error!Term {
                return if (s) p.sext(t, to) else p.zext(t, to);
            }
        }.f;
        const x = try ext(pool, a, wide, info.signed);
        const y = try ext(pool, b, wide, info.signed);
        const exact = try pool.bin(op, x, y);
        const narrow = try pool.bin(op, a, b);
        return pool.eq(exact, try ext(pool, narrow, wide, info.signed));
    }

    fn division(v: *Vc, inst: *const Inst, st: *State) StepError!void {
        const pool = v.pool;
        const a = try v.scalarArg(inst, 0);
        const b = try v.scalarArg(inst, 1);
        const info = try v.intTypeOf(inst.ty);
        const zero = try pool.bv(info.bits, 0);
        const nonzero = try pool.ne(b, zero);
        try v.oblige(st, inst, .division, "division by zero", .{}, nonzero);
        const trunc_q = try pool.bin(if (info.signed) .sdiv else .udiv, a, b);
        const rem = try pool.bin(if (info.signed) .srem else .urem, a, b);
        if (info.signed) {
            const min = try pool.bv(info.bits, @as(u128, 1) << @intCast(info.bits - 1));
            const neg1 = try pool.bv(info.bits, term.mask(info.bits));
            const fits = try pool.@"or"(try pool.ne(a, min), try pool.ne(b, neg1));
            try v.oblige(st, inst, .overflow, "integer overflow in division on {s}", .{v.ctx.typeName(inst.ty)}, fits);
        }
        switch (inst.tag) {
            .div_trunc => v.setScalar(inst, trunc_q),
            .div_exact => {
                try v.oblige(st, inst, .other, "exact division leaves a remainder", .{}, try pool.eq(rem, zero));
                v.setScalar(inst, trunc_q);
            },
            .div_floor => {
                if (!info.signed) return v.setScalar(inst, trunc_q);
                const rem_nonzero = try pool.ne(rem, zero);
                const signs_differ = try pool.ne(try pool.cmp(.slt, rem, zero), try pool.cmp(.slt, b, zero));
                const adjust = try pool.@"and"(rem_nonzero, signs_differ);
                v.setScalar(inst, try pool.ite(adjust, try pool.bin(.sub, trunc_q, try pool.bv(info.bits, 1)), trunc_q));
            },
            .rem => v.setScalar(inst, rem),
            .mod => {
                if (!info.signed) return v.setScalar(inst, rem);
                v.setScalar(inst, try pool.bin(.smod, a, b));
            },
            else => unreachable,
        }
    }

    /// Leading zeros, trailing zeros and set bits, one bit at a time: later bits override earlier ones.
    fn bitCount(v: *Vc, inst: *const Inst) Error!void {
        const pool = v.pool;
        const a = try v.scalarArg(inst, 0);
        const width = pool.bitsOf(a);
        const out = (try v.intTypeOf(inst.ty)).bits;
        const one = try pool.bv(1, 1);
        var r = if (inst.tag == .popcount) try pool.bv(out, 0) else try pool.bv(out, width);
        for (0..width) |step_| {
            const i: u16 = @intCast(if (inst.tag == .ctz) width - 1 - step_ else step_);
            const set = try pool.eq(try pool.extract(a, i, i), one);
            switch (inst.tag) {
                .clz => r = try pool.ite(set, try pool.bv(out, width - 1 - i), r),
                .ctz => r = try pool.ite(set, try pool.bv(out, i), r),
                else => r = try pool.bin(.add, r, try pool.zext(try pool.extract(a, i, i), out)),
            }
        }
        v.setScalar(inst, r);
    }

    fn shift(v: *Vc, inst: *const Inst, st: *State) StepError!void {
        const pool = v.pool;
        const a = try v.scalarArg(inst, 0);
        var amount = try v.scalarArg(inst, 1);
        const info = try v.intTypeOf(inst.ty);
        const amount_bits = pool.bitsOf(amount);
        if (amount_bits > info.bits) return v.ctx.unsupported("shift amount wider than the value", .{});
        amount = try pool.zext(amount, info.bits);
        try v.oblige(st, inst, .shift, "shift amount is too large", .{}, try pool.cmp(.ult, amount, try pool.bv(info.bits, info.bits)));
        const left = inst.tag == .shl or inst.tag == .shl_exact;
        const op: term.Op = if (left) .shl else if (info.signed) .ashr else .lshr;
        const result = try pool.bin(op, a, amount);
        switch (inst.tag) {
            .shl_exact, .shr_exact => {
                const back = try pool.bin(if (left) (if (info.signed) .ashr else .lshr) else .shl, result, amount);
                try v.oblige(st, inst, .shift, "exact shift loses bits", .{}, try pool.eq(back, a));
            },
            else => {},
        }
        v.setScalar(inst, result);
    }

    fn compare(v: *Vc, inst: *const Inst) Error!void {
        const pool = v.pool;
        const lhs = try v.arg(inst, 0);
        const rhs = try v.arg(inst, 1);
        if (lhs != .scalar or rhs != .scalar) {
            if (lhs == .opt and inst.tag == .cmp_eq or lhs == .opt and inst.tag == .cmp_neq) return v.ctx.unsupported("optional comparison", .{});
            return v.ctx.unsupported("comparison of {t} and {t}", .{ std.meta.activeTag(lhs), std.meta.activeTag(rhs) });
        }
        const a = lhs.scalar;
        const b = rhs.scalar;
        if (pool.sortOf(a) == .bool) {
            const same = try pool.eq(a, b);
            return v.setScalar(inst, switch (inst.tag) {
                .cmp_eq => same,
                .cmp_neq => try pool.not(same),
                else => return v.ctx.unsupported("ordering on booleans", .{}),
            });
        }
        if (v.isErrorSet(v.operandType(v.ops(inst)[0])) or v.isErrorSet(v.operandType(v.ops(inst)[1]))) {
            const same = try pool.eq(a, b);
            return v.setScalar(inst, switch (inst.tag) {
                .cmp_eq => same,
                .cmp_neq => try pool.not(same),
                else => return v.ctx.unsupported("ordering on errors", .{}),
            });
        }
        const info = v.ctx.intInfo(v.operandType(v.ops(inst)[0])) orelse
            v.ctx.intInfo(v.operandType(v.ops(inst)[1])) orelse return v.ctx.unsupported("comparison of a non-integer", .{});
        const lt: term.Op = if (info.signed) .slt else .ult;
        const le: term.Op = if (info.signed) .sle else .ule;
        v.setScalar(inst, switch (inst.tag) {
            .cmp_lt => try pool.cmp(lt, a, b),
            .cmp_lte => try pool.cmp(le, a, b),
            .cmp_gt => try pool.cmp(lt, b, a),
            .cmp_gte => try pool.cmp(le, b, a),
            .cmp_eq => try pool.eq(a, b),
            else => try pool.ne(a, b),
        });
    }

    fn isErrorSet(v: *const Vc, ty: schema.TypeId) bool {
        return ty != .none and v.ctx.typeRec(ty).kind == .error_set;
    }

    fn intCast(v: *Vc, inst: *const Inst, st: *State) StepError!void {
        const pool = v.pool;
        const o = v.ops(inst)[0];
        const a = try v.scalarArg(inst, 0);
        const src = v.ctx.intInfo(v.operandType(o)) orelse return v.ctx.unsupported("cast from a non-integer", .{});
        const dst = try v.intTypeOf(inst.ty);
        const lossless = (dst.bits > src.bits and (dst.signed or !src.signed)) or (dst.bits == src.bits and dst.signed == src.signed);
        if (!lossless) {
            const wide = @max(src.bits, dst.bits) + 1;
            if (wide > 128) return v.ctx.unsupported("a narrowing cast between types this wide", .{});
            const x = if (src.signed) try pool.sext(a, wide) else try pool.zext(a, wide);
            const lo: i128 = if (dst.signed) -(@as(i128, 1) << @intCast(dst.bits - 1)) else 0;
            const hi: i128 = if (dst.signed) (@as(i128, 1) << @intCast(dst.bits - 1)) - 1 else @intCast(term.mask(dst.bits));
            const fits = try pool.@"and"(try pool.cmp(.sle, try pool.bvSigned(wide, lo), x), try pool.cmp(.sle, x, try pool.bvSigned(wide, hi)));
            try v.oblige(st, inst, .cast, "value does not fit in {s}", .{v.ctx.typeName(inst.ty)}, fits);
        }
        const out = if (dst.bits > src.bits) x_ext: {
            break :x_ext if (src.signed) try pool.sext(a, dst.bits) else try pool.zext(a, dst.bits);
        } else try pool.extract(a, dst.bits - 1, 0);
        v.setScalar(inst, out);
    }

    // Control flow.

    fn block(v: *Vc, inst: *const Inst, st: *State, body: schema.Body) StepError!void {
        var ctx: BlockCtx = .{};
        try v.blocks.put(v.arena(), inst.id, &ctx);
        defer _ = v.blocks.remove(inst.id);
        var inner = try st.clone(v.arena());
        try v.exec(v.pack.instsOf(body.insts), &inner);
        if (v.alive(&inner)) return v.ctx.unsupported("a block body falls through", .{});
        if (try v.join(ctx.incoming.items)) |joined| {
            st.* = joined.state;
            v.setResult(inst, joined.value);
        } else try v.kill(st);
    }

    fn condBr(v: *Vc, inst: *const Inst, st: *State) StepError!void {
        const pool = v.pool;
        const c = try v.scalarArg(inst, 0);
        const bodies = v.pack.bodiesOf(inst.*);
        const not_c = try pool.not(c);
        if (v.pure and (v.containsHead(bodies[0]) or v.containsHead(bodies[1]))) {
            const pick = if (v.containsHead(bodies[0])) bodies[0] else bodies[1];
            return v.exec(v.pack.instsOf(pick.insts), st);
        }
        var then_state = try st.clone(v.arena());
        then_state.pc = try pool.@"and"(st.pc, c);
        var else_state = try st.clone(v.arena());
        else_state.pc = try pool.@"and"(st.pc, not_c);
        try v.exec(v.pack.instsOf(bodies[0].insts), &then_state);
        try v.exec(v.pack.instsOf(bodies[1].insts), &else_state);
        if (v.alive(&then_state) or v.alive(&else_state)) return v.ctx.unsupported("a branch falls through", .{});
        try v.kill(st);
    }

    fn switchBr(v: *Vc, inst: *const Inst, st: *State) StepError!void {
        const pool = v.pool;
        const selector = try v.scalarArg(inst, 0);
        const info = v.ctx.intInfo(v.operandType(v.ops(inst)[0])) orelse return v.ctx.unsupported("switch on a non-integer", .{});
        const le: term.Op = if (info.signed) .sle else .ule;
        const bodies = v.pack.bodiesOf(inst.*);
        var covered = try pool.fls();
        for (bodies) |b| {
            var matches = try pool.fls();
            if (b.label == .case) {
                for (v.pack.t.operands[b.items.off..][0..b.items.len]) |item| {
                    const iv = try v.operand(item);
                    if (iv != .scalar) return v.ctx.unsupported("a switch prong that is not an integer", .{});
                    matches = try pool.@"or"(matches, try pool.eq(selector, iv.scalar));
                }
                for (0..b.ranges.len) |k| {
                    const lo = try v.operand(v.pack.t.operands[b.ranges.off + 2 * k]);
                    const hi = try v.operand(v.pack.t.operands[b.ranges.off + 2 * k + 1]);
                    if (lo != .scalar or hi != .scalar) return v.ctx.unsupported("a switch range that is not an integer", .{});
                    matches = try pool.@"or"(matches, try pool.@"and"(try pool.cmp(le, lo.scalar, selector), try pool.cmp(le, selector, hi.scalar)));
                }
                covered = try pool.@"or"(covered, matches);
            } else matches = try pool.not(covered);
            var arm = try st.clone(v.arena());
            arm.pc = try pool.@"and"(st.pc, matches);
            try v.exec(v.pack.instsOf(b.insts), &arm);
            if (v.alive(&arm)) return v.ctx.unsupported("a switch prong falls through", .{});
        }
        try v.kill(st);
    }

    fn call(v: *Vc, inst: *const Inst, st: *State) StepError!void {
        const pool = v.pool;
        const callee = v.attrStr(inst, .callee) orelse return v.ctx.unsupported("call through a function pointer", .{});
        if (v.ctx.typeRec(inst.ty).kind == .noreturn) {
            const kind: Kind = if (std.mem.indexOf(u8, callee, "outOfBounds") != null) .bounds else if (std.mem.indexOf(u8, callee, "divideByZero") != null) .division else .panic;
            try v.oblige(st, inst, kind, "{s}", .{try v.panicText(inst, callee)}, try pool.fls());
            return v.kill(st);
        }
        if (std.mem.eql(u8, callee, "lang.returnError")) return;
        const hooks = v.hooks orelse return v.ctx.unsupported("call to {s}", .{callee});
        const summary = try hooks.summaryFn(hooks.context, v, callee);
        if (std.mem.indexOfScalar(*const Summary, v.relied.items, summary) == null) try v.relied.append(v.arena(), summary);
        const operands = v.ops(inst)[1..];
        if (operands.len != summary.params.len) return v.ctx.unsupported("call to {s} with {d} arguments, expected {d}", .{ callee, operands.len, summary.params.len });
        for (operands) |o| try v.useTokens(st, try v.operand(o), v.operandType(o), true);
        var sub: term.Subst = .{ .pool = pool, .alloc = v.arena() };
        const PtrCall = struct { s: PtrSummary, place: value.Place, cur: Value };
        var ptr_calls: std.ArrayList(PtrCall) = .empty;
        for (summary.ptrs) |s| {
            const a = try v.operand(operands[s.index]);
            if (a != .place) return v.ctx.unsupported("a pointer argument that is not the address of a variable", .{});
            for (ptr_calls.items) |q| if (q.place.cell == a.place.cell and overlap(q.place.path, a.place.path))
                return v.ctx.unsupported("two pointer arguments to {s} that overlap", .{callee});
            const cur = try v.read(st.cells[a.place.cell], a.place.path, s.ty);
            if (cur != .obj) return v.ctx.unsupported("a pointer argument to a struct that was never set", .{});
            try ptr_calls.append(v.arena(), .{ .s = s, .place = a.place, .cur = cur });
            // What the callee changes, it was given: its tokens are the callee's, and it puts back the ones it keeps.
            if (s.all) {
                try v.useTokens(st, cur, s.ty, true);
            } else for (s.touched) |f| {
                const fty = v.fieldType(.{ .index = f, .owner = s.ty }) orelse continue;
                if (try v.hasToken(fty)) try v.useTokens(st, try v.ctx.field(cur.obj, f, fty), fty, true);
            }
            try v.bind(&sub, s.entry, cur, summary.lazy);
        }
        for (summary.params, operands) |param, o| {
            if (param == .place) continue;
            try v.bind(&sub, param, try v.operand(o), summary.lazy);
        }
        const result = try v.ctx.havoc("$ret", summary.result);
        try v.bind(&sub, summary.result, result, summary.lazy);
        const outs = try v.arena().alloc(Value, ptr_calls.items.len);
        for (outs, ptr_calls.items) |*out, pc| {
            out.* = try v.ctx.havoc("$out", pc.s.out);
            try v.bind(&sub, pc.s.out, out.*, summary.lazy);
        }
        const pre = sub.apply(summary.pre) catch |err| return v.substFailed(err, callee);
        const post = sub.apply(summary.post) catch |err| return v.substFailed(err, callee);
        try v.oblige(st, inst, .precondition, "precondition of {s} may not hold", .{callee}, pre);
        st.pc = try pool.@"and"(st.pc, post);
        for (outs, ptr_calls.items) |out, pc| {
            var now = out;
            if (!pc.s.all) {
                now = pc.cur;
                for (pc.s.touched) |f| {
                    const fty = v.fieldType(.{ .index = f, .owner = pc.s.ty }) orelse continue;
                    const like = try v.ctx.field(pc.cur.obj, f, fty);
                    now = try v.ctx.withField(now.obj, f, try v.ctx.fieldShaped(out.obj, f, like));
                }
            }
            st.cells[pc.place.cell] = try v.update(st.cells[pc.place.cell], pc.place.path, now);
        }
        v.setResult(inst, result);
    }

    /// Whether one path into a cell is a prefix of the other: the two places share memory.
    fn overlap(a: []const value.Step, b: []const value.Step) bool {
        const n = @min(a.len, b.len);
        for (a[0..n], b[0..n]) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    fn substFailed(v: *Vc, err: term.Subst.Error, callee: []const u8) StepError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnboundArray => v.ctx.unsupported("the contract of {s} uses a slice in a way a call cannot carry over", .{callee}),
        };
    }

    /// Maps the variables of a callee's value onto the caller's value of the same shape.
    fn bind(v: *Vc, sub: *term.Subst, callee: Value, caller: Value, lazy: []const value.Lazy) Error!void {
        const gpa = v.arena();
        if (std.meta.activeTag(callee) != std.meta.activeTag(caller)) {
            return v.ctx.unsupported("an argument ({t}) whose shape differs from the parameter ({t})", .{ std.meta.activeTag(caller), std.meta.activeTag(callee) });
        }
        switch (callee) {
            .none => {},
            .scalar => |t| try sub.map.put(gpa, t, caller.scalar),
            .slice => |s| {
                try sub.map.put(gpa, s.len, caller.slice.len);
                try sub.arrays.put(gpa, s.mem, .{ .mem = caller.slice.mem, .off = caller.slice.off });
            },
            .array => |a| try sub.arrays.put(gpa, a.mem, .{ .mem = caller.array.mem, .off = try v.pool.bv(64, 0) }),
            .opt => |o| {
                try sub.map.put(gpa, o.has, caller.opt.has);
                try v.bind(sub, o.payload, caller.opt.payload, lazy);
            },
            .eu => |e| {
                try sub.map.put(gpa, e.is_err, caller.eu.is_err);
                try sub.map.put(gpa, e.err, caller.eu.err);
                try v.bind(sub, e.payload, caller.eu.payload, lazy);
            },
            .obj => |o| {
                const base = o.base orelse return;
                for (lazy) |l| {
                    if (!std.mem.eql(u8, l.base, base)) continue;
                    try v.bind(sub, l.value, try v.ctx.fieldShaped(caller.obj, l.index, l.value), lazy);
                }
            },
            .elem_ptr, .place => return v.ctx.unsupported("a pointer argument", .{}),
        }
    }

    fn panicText(v: *Vc, inst: *const Inst, callee: []const u8) Error![]const u8 {
        const table = [_]struct { []const u8, []const u8 }{
            .{ "divideByZero", "division by zero" },
            .{ "outOfBounds", "index out of bounds" },
            .{ "integerOverflow", "integer overflow" },
            .{ "reachedUnreachable", "unreachable code is reachable" },
            .{ "unwrapNull", "optional is null where a value is required" },
            .{ "castTruncatedData", "integer cast loses bits" },
            .{ "negativeToUnsigned", "negative value cast to unsigned" },
            .{ "shiftRhsTooBig", "shift amount is too large" },
            .{ "startGreaterThanEnd", "slice start is greater than its end" },
            .{ "inactiveUnionField", "inactive union field" },
        };
        for (table) |entry| if (std.mem.indexOf(u8, callee, entry[0]) != null) return entry[1];
        if (v.ops(inst).len > 1 and v.ops(inst)[1].kind == .constant) {
            const c = v.pack.t.consts[v.ops(inst)[1].value];
            if (c.kind == .text) {
                const text = v.pack.str(@fromBackingInt(@intCast(c.a)));
                if (std.mem.indexOfScalar(u8, text, '"')) |open| if (std.mem.indexOfScalarPos(u8, text, open + 1, '"')) |close|
                    return std.fmt.allocPrint(v.arena(), "panic: {s}", .{text[open + 1 .. close]});
            }
        }
        return std.fmt.allocPrint(v.arena(), "call to {s} is reachable", .{callee});
    }

    // Contracts.

    const Contract = enum { requires, ensures, invariant, decreases, assume };

    fn stripInstance(callee: []const u8) []const u8 {
        return if (std.mem.endsWith(u8, callee, "__func")) callee[0 .. callee.len - "__func".len] else callee;
    }

    fn contractOf(callee: []const u8) ?Contract {
        const trimmed = stripInstance(callee);
        if (!std.mem.startsWith(u8, trimmed, "zv.")) return null;
        return std.meta.stringToEnum(Contract, trimmed["zv.".len..]);
    }

    /// The operands of the `dbg_arg_inline` instructions that open an inlined call, in order.
    fn inlineArgs(v: *Vc, body: schema.Body, out: *[4]schema.Operand) usize {
        var n: usize = 0;
        for (v.pack.instsOf(body.insts)) |*i| {
            if (i.tag != .dbg_arg_inline) break;
            if (n < out.len) out[n] = v.ops(i)[0];
            n += 1;
        }
        return @min(n, out.len);
    }

    fn inlineBlock(v: *Vc, inst: *const Inst, st: *State) StepError!void {
        const pool = v.pool;
        const body = v.pack.bodiesOf(inst.*)[0];
        const callee = v.attrStr(inst, .callee) orelse return v.block(inst, st, body);
        var args: [4]schema.Operand = undefined;
        const n = v.inlineArgs(body, &args);
        const contract = contractOf(callee) orelse {
            if (try v.ghostCall(inst, st, callee, args[0..n])) return;
            const token_op = tokenOpOf(callee);
            if (token_op) |op| try v.tokenOpEnter(inst, st, op, args[0..n]);
            try v.inline_names.append(v.arena(), callee);
            defer _ = v.inline_names.pop();
            try v.block(inst, st, body);
            if (token_op) |op| if (zv_air.tokens.consumes(op))
                for (args[0..n]) |a| try v.useTokens(st, try v.operand(a), v.operandType(a), true);
            return;
        };
        if (v.pure and contract != .invariant and contract != .decreases) return;
        const nested = v.inline_names.items.len != 0;
        switch (contract) {
            .requires => {
                if (n != 1) return v.ctx.unsupported("zv.requires with {d} arguments", .{n});
                const ok = (try v.operand(args[0])).scalar;
                if (nested) {
                    try v.oblige(st, inst, .precondition, "precondition of {s} may not hold", .{v.inline_names.getLast()}, ok);
                } else {
                    if (v.obligations_seen or v.blocks.count() != 0) return v.ctx.unsupported("zv.requires must open the function body", .{});
                    st.pc = try pool.@"and"(st.pc, ok);
                    v.pre = try pool.@"and"(v.pre, ok);
                }
            },
            .assume => {
                if (n != 1) return v.ctx.unsupported("zv.assume with {d} arguments", .{n});
                if (v.alive(st)) try v.assumed.append(v.arena(), if (inst.loc != .none) inst.loc else v.loc);
                st.pc = try pool.@"and"(st.pc, (try v.operand(args[0])).scalar);
            },
            .ensures => {
                // A void value is not an argument of the inlined call: `zv.ensures({}, ok)` has only the condition.
                if (n != 2 and n != 1) return v.ctx.unsupported("zv.ensures with {d} arguments", .{n});
                const ok = (try v.operand(args[n - 1])).scalar;
                const val: Value = if (n == 2) try v.operand(args[0]) else .none;
                if (nested) {
                    try v.oblige(st, inst, .postcondition, "postcondition of {s} may not hold", .{v.inline_names.getLast()}, ok);
                } else {
                    try v.oblige(st, inst, .postcondition, "postcondition (zv.ensures) may not hold", .{}, ok);
                    try v.sites.put(v.arena(), inst.id, .{ .ok = ok, .value = val });
                }
                v.setResult(inst, val);
            },
            .invariant, .decreases => {
                if (n != 1) return v.ctx.unsupported("zv.{t} with {d} arguments", .{ contract, n });
                const ghost = contract == .decreases and v.isGhostInt(v.operandType(args[0]));
                const t = if (ghost) try v.asInt(args[0]) else switch (try v.operand(args[0])) {
                    .scalar => |t| t,
                    else => return v.ctx.unsupported("zv.{t} of something that is not a number or a condition", .{contract}),
                };
                if (contract == .decreases) if (v.ctx.intInfo(v.operandType(args[0]))) |info| if (info.signed)
                    return v.ctx.unsupported("zv.decreases of a signed integer: use an unsigned one or a zv.Int", .{});
                if (v.pure) {
                    try v.collected.append(v.arena(), .{ .id = inst.id, .kind = if (contract == .invariant) .invariant else .decreases, .term = t, .ghost = ghost });
                    v.pure_seen = v.collected.items.len - v.pure_base >= v.pure_target;
                    return;
                }
                if (!v.head_ids.contains(inst.id)) return v.ctx.unsupported("zv.{t} must open a loop body", .{contract});
            },
        }
    }

    // Ghost integers and sequences (zv.Int, zv.Seq): their operations are read as mathematics. A ghost
    // integer is a signed bit-vector of `term.ghost_bits`; an operation that would leave that range is an
    // obligation, so no specification silently wraps. Bit-vectors keep the queries in one theory.

    const Ghost = enum {
        @"Int.of",
        @"Int.add",
        @"Int.sub",
        @"Int.mul",
        @"Int.neg",
        @"Int.divFloor",
        @"Int.mod",
        @"Int.lt",
        @"Int.le",
        @"Int.gt",
        @"Int.ge",
        @"Int.eq",
        @"Int.ne",
        @"Seq.empty",
        @"Seq.push",
        @"Seq.len",
        @"Seq.at",
        @"Seq.concat",
        @"Seq.sub",
    };

    const ghost_info: value.IntInfo = .{ .bits = term.ghost_bits, .signed = true };

    fn isGhostInt(v: *const Vc, ty: schema.TypeId) bool {
        return ty != .none and std.mem.startsWith(u8, v.ctx.typeName(ty), "zv.Int");
    }

    fn asInt(v: *Vc, o: schema.Operand) Error!Term {
        const pool = v.pool;
        const val = try v.operand(o);
        switch (val) {
            .scalar => |t| switch (pool.sortOf(t)) {
                .bv => |bits| {
                    if (bits == term.ghost_bits) return t;
                    const signed = if (v.ctx.intInfo(v.operandType(o))) |i| i.signed else false;
                    return if (signed) pool.sext(t, term.ghost_bits) else pool.zext(t, term.ghost_bits);
                },
                else => {},
            },
            .obj => |ob| if (ob.fields.len == 1 and ob.fields[0].value == .scalar and pool.sortOf(ob.fields[0].value.scalar) == .bv)
                return pool.sext(ob.fields[0].value.scalar, term.ghost_bits),
            else => {},
        }
        return v.ctx.unsupported("a ghost integer that is not one", .{});
    }

    fn asSeq(v: *Vc, o: schema.Operand) Error!Term {
        const val = try v.operand(o);
        if (val == .scalar and v.pool.sortOf(val.scalar) == .seq) return val.scalar;
        return v.ctx.unsupported("a ghost sequence that is not one", .{});
    }

    fn ghostArith(v: *Vc, inst: *const Inst, st: *State, op: term.Op, a: Term, b: Term) StepError!Term {
        const ok = try v.noOverflow(op, a, b, ghost_info);
        try v.oblige(st, inst, .ghost, "a specification outgrows {d}-bit ghost integers", .{term.ghost_bits}, ok);
        return v.pool.bin(op, a, b);
    }

    fn ghostOp(v: *Vc, callee: []const u8) Allocator.Error!?Ghost {
        if (!std.mem.startsWith(u8, callee, "zv.") or std.mem.indexOf(u8, callee, "__struct.") == null) return null;
        return std.meta.stringToEnum(Ghost, try std.mem.replaceOwned(u8, v.arena(), callee["zv.".len..], "__struct", ""));
    }

    /// Handles a call of a ghost operation; false when `callee` is not one.
    fn ghostCall(v: *Vc, inst: *const Inst, st: *State, callee: []const u8, args: []const schema.Operand) StepError!bool {
        const op = try v.ghostOp(callee) orelse return false;
        if (op == .@"Int.of" and (args.len != 1 or v.ctx.intInfo(v.operandType(args[0])) == null)) return false;
        const pool = v.pool;
        const zero = try pool.bv(term.ghost_bits, 0);
        switch (op) {
            .@"Int.of" => v.setScalar(inst, try v.asInt(args[0])),
            .@"Int.add" => v.setScalar(inst, try v.ghostArith(inst, st, .add, try v.asInt(args[0]), try v.asInt(args[1]))),
            .@"Int.sub" => v.setScalar(inst, try v.ghostArith(inst, st, .sub, try v.asInt(args[0]), try v.asInt(args[1]))),
            .@"Int.mul" => v.setScalar(inst, try v.ghostArith(inst, st, .mul, try v.asInt(args[0]), try v.asInt(args[1]))),
            .@"Int.neg" => v.setScalar(inst, try v.ghostArith(inst, st, .sub, zero, try v.asInt(args[0]))),
            .@"Int.divFloor", .@"Int.mod" => {
                const a = try v.asInt(args[0]);
                const b = try v.asInt(args[1]);
                try v.oblige(st, inst, .ghost, "division by zero in a specification", .{}, try pool.ne(b, zero));
                if (op == .@"Int.mod") return v.finishGhost(inst, try pool.bin(.smod, a, b));
                const min = try pool.bv(term.ghost_bits, @as(u256, 1) << (term.ghost_bits - 1));
                const neg1 = try pool.bv(term.ghost_bits, std.math.maxInt(u256));
                const fits = try pool.@"or"(try pool.ne(a, min), try pool.ne(b, neg1));
                try v.oblige(st, inst, .ghost, "a specification outgrows {d}-bit ghost integers", .{term.ghost_bits}, fits);
                const q = try pool.bin(.sdiv, a, b);
                const r = try pool.bin(.srem, a, b);
                const adjust = try pool.@"and"(try pool.ne(r, zero), try pool.ne(try pool.cmp(.slt, r, zero), try pool.cmp(.slt, b, zero)));
                v.setScalar(inst, try pool.ite(adjust, try pool.bin(.sub, q, try pool.bv(term.ghost_bits, 1)), q));
            },
            .@"Int.lt", .@"Int.le", .@"Int.gt", .@"Int.ge", .@"Int.eq", .@"Int.ne" => {
                const a = try v.asInt(args[0]);
                const b = try v.asInt(args[1]);
                v.setScalar(inst, switch (op) {
                    .@"Int.lt" => try pool.cmp(.slt, a, b),
                    .@"Int.le" => try pool.cmp(.sle, a, b),
                    .@"Int.gt" => try pool.cmp(.slt, b, a),
                    .@"Int.ge" => try pool.cmp(.sle, b, a),
                    .@"Int.eq" => try pool.eq(a, b),
                    else => try pool.ne(a, b),
                });
            },
            .@"Seq.empty" => v.setScalar(inst, try pool.seqEmpty()),
            .@"Seq.push" => {
                const s = try v.asSeq(args[0]);
                const room = try pool.cmp(.ult, try pool.seqLen(s), try pool.bv(term.ghost_bits, term.seq_capacity));
                try v.oblige(st, inst, .ghost, "a specification pushes past the {d} elements a sequence holds", .{term.seq_capacity}, room);
                v.setScalar(inst, try pool.seqConcat(s, try pool.seqUnit(try v.asInt(args[1]))));
            },
            .@"Seq.len" => v.setScalar(inst, try pool.seqLen(try v.asSeq(args[0]))),
            .@"Seq.at" => {
                const s = try v.asSeq(args[0]);
                const i = try v.asInt(args[1]);
                const in_range = try pool.@"and"(try pool.cmp(.sle, zero, i), try pool.cmp(.slt, i, try pool.seqLen(s)));
                try v.oblige(st, inst, .ghost, "sequence index out of range in a specification", .{}, in_range);
                v.setScalar(inst, try pool.seqAt(s, i));
            },
            .@"Seq.concat" => {
                const a = try v.asSeq(args[0]);
                const b = try v.asSeq(args[1]);
                const cap = try pool.bv(term.ghost_bits, term.seq_capacity);
                const room = try pool.@"and"(
                    try pool.cmp(.ule, try pool.seqLen(a), cap),
                    try pool.cmp(.ule, try pool.seqLen(b), try pool.bin(.sub, cap, try pool.seqLen(a))),
                );
                try v.oblige(st, inst, .ghost, "a specification joins sequences past the {d} elements one holds", .{term.seq_capacity}, room);
                v.setScalar(inst, try pool.seqConcat(a, b));
            },
            .@"Seq.sub" => {
                const s = try v.asSeq(args[0]);
                const lo = try v.asInt(args[1]);
                const n = try v.asInt(args[2]);
                const end = try pool.bin(.add, lo, n);
                const in_range = try pool.@"and"(
                    try v.noOverflow(.add, lo, n, ghost_info),
                    try pool.@"and"(
                        try pool.cmp(.sle, zero, lo),
                        try pool.@"and"(try pool.cmp(.sle, zero, n), try pool.cmp(.sle, end, try pool.seqLen(s))),
                    ),
                );
                try v.oblige(st, inst, .ghost, "subsequence out of range in a specification", .{}, in_range);
                v.setScalar(inst, try pool.seqExtract(s, lo, n));
            },
        }
        return true;
    }

    fn finishGhost(v: *Vc, inst: *const Inst, t: Term) bool {
        v.setScalar(inst, t);
        return true;
    }

    // Loops.

    fn containsHead(v: *Vc, body: schema.Body) bool {
        return v.headCount(body) != 0;
    }

    /// The `zv.invariant` and `zv.decreases` calls in a loop body that are not in a loop of their own.
    fn headCount(v: *Vc, body: schema.Body) usize {
        var n: usize = 0;
        for (v.pack.instsOf(body.insts)) |*i| {
            if (i.tag == .loop) continue;
            if (i.tag == .dbg_inline_block) {
                if (v.attrStr(i, .callee)) |c| if (contractOf(c)) |k| if (k == .invariant or k == .decreases) {
                    n += 1;
                };
            }
            for (v.pack.bodiesOf(i.*)) |b| n += v.headCount(b);
        }
        return n;
    }

    /// Cells written by a store inside `body`, loops included.
    fn modifiedCells(v: *Vc, st: *const State, body: schema.Body, out: *std.AutoArrayHashMapUnmanaged(u32, void)) Error!void {
        for (v.pack.instsOf(body.insts)) |*i| {
            if (i.tag == .dbg_inline_block) if (v.attrStr(i, .callee)) |callee| if (try v.ghostOp(callee) != null) continue;
            switch (i.tag) {
                .store, .store_safe => {
                    const cell = v.cellOf(st, v.ops(i)[0]) orelse return v.ctx.unsupported("a store through an unknown pointer inside a loop", .{});
                    try out.put(v.arena(), cell, {});
                },
                .memset, .memset_safe, .memcpy, .memmove => return v.ctx.unsupported("{t} inside a loop", .{i.tag}),
                else => {},
            }
            for (v.pack.bodiesOf(i.*)) |b| try v.modifiedCells(st, b, out);
        }
    }

    /// The cell a pointer operand points into. A pointer read from a variable (a `*Self` parameter is copied into one) is
    /// what the variable holds when the loop starts.
    fn cellOf(v: *Vc, st: *const State, o: schema.Operand) ?u32 {
        var cur = o;
        while (cur.kind == .inst) {
            const i = v.by_id[cur.value] orelse return null;
            switch (i.tag) {
                .alloc => return v.cell_of.get(i.id),
                .arg => return v.arg_cell.get(i.id),
                .load => {
                    const holder = v.cellOf(st, v.ops(i)[0]) orelse return null;
                    return switch (st.cells[holder]) {
                        .place => |pl| pl.cell,
                        else => null,
                    };
                },
                .struct_field_ptr, .struct_field_ptr_index_0, .struct_field_ptr_index_1, .struct_field_ptr_index_2, .struct_field_ptr_index_3, .ptr_cast, .ptr_slice_len_ptr, .ptr_slice_ptr_ptr, .bit_cast => cur = v.ops(i)[0],
                else => return null,
            }
        }
        return null;
    }

    /// The invariants and measures at the head of a loop body, evaluated in `st`.
    fn headAt(v: *Vc, body: schema.Body, st: *const State) StepError![]const Collected {
        var probe = try st.clone(v.arena());
        const saved_pure = v.pure;
        const saved_seen = v.pure_seen;
        const saved_len = v.collected.items.len;
        const saved_target = v.pure_target;
        const saved_base = v.pure_base;
        v.pure = true;
        v.pure_seen = false;
        v.pure_target = v.headCount(body);
        v.pure_base = saved_len;
        defer {
            v.pure = saved_pure;
            v.pure_seen = saved_seen;
            v.pure_target = saved_target;
            v.pure_base = saved_base;
            v.collected.shrinkRetainingCapacity(saved_len);
        }
        v.exec(v.pack.instsOf(body.insts), &probe) catch |err| switch (err) {
            error.StopPure => {},
            else => |e| return e,
        };
        return v.arena().dupe(Collected, v.collected.items[saved_len..]);
    }

    fn loop(v: *Vc, inst: *const Inst, st: *State) StepError!void {
        const pool = v.pool;
        if (v.pure) return v.ctx.unsupported("a loop before the head of the enclosing loop", .{});
        const body = v.pack.bodiesOf(inst.*)[0];
        var modified: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
        try v.modifiedCells(st, body, &modified);

        const has_head = v.containsHead(body);
        if (has_head) {
            for (try v.headAt(body, st)) |c| switch (c.kind) {
                .invariant => try v.oblige(st, v.by_id[c.id], .invariant_entry, "loop invariant may not hold on entry", .{}, c.term),
                .decreases => {
                    if (c.ghost) try v.oblige(st, v.by_id[c.id], .termination, "loop measure may be negative on entry", .{}, try pool.cmp(.sle, try pool.bv(term.ghost_bits, 0), c.term));
                },
            };
        }

        var head = try st.clone(v.arena());
        head.cut = true;
        for (modified.keys()) |cell| {
            const name = v.cell_names.items[cell] orelse try std.fmt.allocPrint(v.arena(), "cell{d}", .{cell});
            head.cells[cell] = try v.ctx.havoc(name, head.cells[cell]);
        }
        var ctx: LoopCtx = .{ .head = &.{}, .token_base = v.ctx.tokens, .dead = head.dead };
        if (has_head) {
            ctx.head = try v.headAt(body, &head);
            var measures: usize = 0;
            for (ctx.head) |c| {
                try v.head_ids.put(v.arena(), c.id, {});
                switch (c.kind) {
                    .invariant => head.pc = try pool.@"and"(head.pc, c.term),
                    .decreases => measures += 1,
                }
            }
            if (measures == 0) try v.unbounded_loops.append(v.arena(), inst.loc);
        } else try v.unbounded_loops.append(v.arena(), inst.loc);
        try v.loops.put(v.arena(), inst.id, &ctx);
        defer _ = v.loops.remove(inst.id);
        try v.exec(v.pack.instsOf(body.insts), &head);
        try v.kill(st);
    }

    fn repeat(v: *Vc, inst: *const Inst, st: *State) StepError!void {
        const pool = v.pool;
        const target = v.attrInt(inst, .target) orelse return v.ctx.unsupported("repeat without a target", .{});
        const ctx = v.loops.get(target) orelse return v.ctx.unsupported("repeat outside its loop", .{});
        const loop_inst = v.by_id[target].?;
        for (st.dead) |d| if (d.token <= ctx.token_base and for (ctx.dead) |e| {
            if (e.token == d.token) break false;
        } else true)
            return v.ctx.unsupported("a loop consumes a token it did not build in the iteration", .{});
        if (ctx.head.len != 0) {
            const now = try v.headAt(v.pack.bodiesOf(loop_inst.*)[0], st);
            // Lexicographic decrease: `smaller` accumulates "some earlier measure is equal" prefixes.
            var smaller = try pool.fls();
            var equal_so_far = try pool.tru();
            var at: ?*const Inst = null;
            for (now, ctx.head) |n, h| {
                switch (n.kind) {
                    .invariant => try v.oblige(st, v.by_id[n.id], .invariant_step, "loop invariant may not be preserved by an iteration", .{}, n.term),
                    .decreases => {
                        at = v.by_id[n.id];
                        if (n.ghost) try v.oblige(st, at, .termination, "loop measure may become negative", .{}, try pool.cmp(.sle, try pool.bv(term.ghost_bits, 0), n.term));
                        const less = try pool.cmp(if (n.ghost) .slt else .ult, n.term, h.term);
                        smaller = try pool.@"or"(smaller, try pool.@"and"(equal_so_far, less));
                        equal_so_far = try pool.@"and"(equal_so_far, try pool.eq(n.term, h.term));
                    },
                }
            }
            if (at != null) try v.oblige(st, at, .termination, "loop measure may not decrease in an iteration", .{}, smaller);
        }
        try v.kill(st);
    }

    // Summary.

    /// What callers may know of this function, after `run`: its preconditions and, over its ensures sites, the
    /// disjunction of what each one promises: the returned value is what the path computed, and the promise
    /// holds. A return that no `ensures` covers promises nothing. Loops contribute only through their invariants.
    pub fn summarize(v: *Vc, name: []const u8) Error!Summary {
        const pool = v.pool;
        const result = try v.ctx.symbolic("$ret", v.func.ret, false);
        const ptrs = try v.arena().alloc(PtrSummary, v.ptr_params.items.len);
        for (ptrs, v.ptr_params.items, 0..) |*s, p, k| {
            const out_name = try std.fmt.allocPrint(v.arena(), "$out{d}", .{k});
            s.* = .{ .index = p.index, .ty = p.ty, .entry = p.entry, .out = try v.ctx.symbolic(out_name, p.ty, false), .touched = &.{}, .all = false };
            var touched: std.ArrayList(u32) = .empty;
            for (v.returns.items) |r| {
                switch (r.state.cells[p.cell]) {
                    .obj => |o| if (o.base != null and p.entry == .obj and p.entry.obj.base != null and std.mem.eql(u8, o.base.?, p.entry.obj.base.?)) {
                        for (o.fields) |f| if (std.mem.indexOfScalar(u32, touched.items, f.index) == null) try touched.append(v.arena(), f.index);
                    } else {
                        s.all = true;
                    },
                    else => s.all = true,
                }
            }
            s.touched = touched.items;
        }
        var post = try pool.fls();
        var covered = v.returns.items.len != 0;
        for (v.returns.items) |r| {
            var outs = try pool.tru();
            for (ptrs, v.ptr_params.items) |s, p| outs = try pool.@"and"(outs, try v.agrees(s.out, r.state.cells[p.cell]));
            const site = r.site orelse {
                if (!v.isConstant(r.value)) {
                    covered = false;
                    break;
                }
                post = try pool.@"or"(post, try pool.@"and"(try v.agrees(result, r.value), outs));
                continue;
            };
            const matches = try v.agrees(result, site.value);
            post = try pool.@"or"(post, try pool.@"and"(try pool.@"and"(matches, outs), site.ok));
        }
        return .{
            .name = name,
            .params = v.param_values.items,
            .lazy = v.ctx.lazy.items,
            .pre = v.pre,
            .post = if (covered) post else try pool.tru(),
            .result = result,
            .ptrs = ptrs,
        };
    }

    /// The condition that `result` is `val`, part by part.
    fn agrees(v: *Vc, result: Value, val: Value) Error!Term {
        const pool = v.pool;
        if (val == .none) return pool.tru();
        if (std.meta.activeTag(val) != std.meta.activeTag(result)) return v.ctx.unsupported("a returned {t} where the declared result is {t}", .{ std.meta.activeTag(val), std.meta.activeTag(result) });
        switch (val) {
            .none => return pool.tru(),
            .scalar => |t| {
                if (!pool.sortOf(result.scalar).eql(pool.sortOf(t))) return v.ctx.unsupported("a returned scalar of another sort than the declared result", .{});
                return pool.eq(result.scalar, t);
            },
            .opt => |o| return pool.@"and"(
                try pool.eq(result.opt.has, o.has),
                try v.agrees(result.opt.payload, o.payload),
            ),
            .eu => |e| return pool.@"and"(
                try pool.eq(result.eu.is_err, e.is_err),
                try pool.@"and"(try pool.eq(result.eu.err, e.err), try v.agrees(result.eu.payload, e.payload)),
            ),
            .obj => |o| {
                var acc = try pool.tru();
                for (o.fields) |f| acc = try pool.@"and"(acc, try v.agrees(try v.ctx.fieldShaped(result.obj, f.index, f.value), f.value));
                // A value that is a parameter or a call result has the fields something read so far, as variables.
                const base = o.base orelse return acc;
                const seen = v.ctx.lazy.items.len;
                for (0..seen) |i| {
                    const l = v.ctx.lazy.items[i];
                    if (!std.mem.eql(u8, l.base, base)) continue;
                    if (for (o.fields) |f| {
                        if (f.index == l.index) break true;
                    } else false) continue;
                    acc = try pool.@"and"(acc, try v.agrees(try v.ctx.fieldShaped(result.obj, l.index, l.value), l.value));
                }
                return acc;
            },
            .slice, .array, .elem_ptr, .place => return v.ctx.unsupported("a returned slice, array or pointer", .{}),
        }
    }
};
