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
    division,
    bounds,
    cast,
    shift,
    panic,
    unreachable_code,
    postcondition,
    invariant_entry,
    invariant_step,
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

    fn clone(s: State, arena: Allocator) Allocator.Error!State {
        var c = s;
        c.cells = try arena.dupe(Value, s.cells);
        return c;
    }
};

const Incoming = struct { state: State, value: Value };

const BlockCtx = struct { incoming: std.ArrayList(Incoming) = .empty };

const LoopCtx = struct {
    invariants: []const Collected,
};

const Collected = struct { id: u32, ok: Term };

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
    head_invariants: std.AutoHashMapUnmanaged(u32, void) = .empty,
    obligations: std.ArrayList(Obligation) = .empty,
    returns: std.ArrayList(Incoming) = .empty,
    unsupported: ?Unsupported = null,
    loc: schema.LocId = .none,

    pure: bool = false,
    pure_seen: bool = false,
    collected: std.ArrayList(Collected) = .empty,
    obligations_seen: bool = false,

    pub fn arena(v: *Vc) Allocator {
        return v.ctx.arena;
    }

    pub fn init(gpa: Allocator, arena_alloc: Allocator, pool: *Pool, pack: *const schema.Pack, func: schema.Func, param_names: []const []const u8) Allocator.Error!Vc {
        var max_id: u32 = 0;
        scanMax(pack, pack.instsOf(func.insts), &max_id);
        const by_id = try arena_alloc.alloc(?*const Inst, max_id + 1);
        @memset(by_id, null);
        var v: Vc = .{
            .gpa = gpa,
            .ctx = .{ .pool = pool, .pack = pack, .arena = arena_alloc },
            .pool = pool,
            .pack = pack,
            .func = func,
            .param_names = param_names,
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

    fn runInner(v: *Vc) StepError!void {
        const pool = v.pool;
        var st: State = .{
            .pc = try pool.tru(),
            .cells = try v.arena().alloc(Value, v.cell_names.items.len),
            .names = null,
        };
        @memset(st.cells, .none);
        const params = v.pack.paramsOf(v.func);
        for (v.pack.instsOf(v.func.insts)) |*inst| {
            if (inst.tag != .arg) break;
            const index = v.attrInt(inst, .index) orelse return v.ctx.unsupported("argument without an index", .{});
            const name = if (index < v.param_names.len) v.param_names[index] else try std.fmt.allocPrint(v.arena(), "arg{d}", .{index});
            const val = try v.ctx.symbolic(name, params[index].ty, true);
            v.values[inst.id] = val;
            st.pc = try pool.@"and"(st.pc, try v.boundsOf(val, params[index].ty));
        }
        try v.exec(v.pack.instsOf(v.func.insts), &st);
    }

    /// Facts every value of the type satisfies: a slice fits the address space.
    fn boundsOf(v: *Vc, val: Value, ty: schema.TypeId) Allocator.Error!Term {
        const pool = v.pool;
        switch (val) {
            .slice => |s| {
                const t = v.ctx.typeRec(ty);
                const size: u128 = if (v.ctx.intInfo(t.child)) |i| @max(1, i.bits / 8) else 1;
                const limit = try pool.bv(64, (@as(u128, 1) << 63) / size - 1);
                return pool.cmp(.ule, s.len, limit);
            },
            .array, .none, .scalar => return pool.tru(),
            else => return pool.tru(),
        }
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
                const info = try v.intTypeOf(c.ty);
                return .{ .scalar = try pool.bv(info.bits, if (info.signed) @as(u128, @bitCast(@as(i128, @as(i64, @bitCast(c.a))))) else c.a) };
            },
            .null => {
                const t = v.ctx.typeRec(c.ty);
                const payload = try v.ctx.symbolic("null.payload", t.child, false);
                return .{ .opt = try v.ctx.create(value.Opt, .{ .has = try pool.fls(), .payload = payload }) };
            },
            .@"error" => {
                return .{ .scalar = try pool.bv(value.error_bits, errorCode(v.pack.str(@fromBackingInt(@intCast(c.a))))) };
            },
            .text => return v.ctx.unsupported("constant {s}", .{v.pack.str(@fromBackingInt(@intCast(c.a)))}),
            else => return v.ctx.unsupported("constant of kind {t}", .{c.kind}),
        }
    }

    fn errorCode(name: []const u8) u16 {
        return @intCast(1 + std.hash.Wyhash.hash(0, name) % 65534);
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
        v.obligations_seen = true;
        st.pc = try v.pool.@"and"(st.pc, goal);
    }

    // Execution.

    fn exec(v: *Vc, body: []const Inst, st: *State) StepError!void {
        for (body) |*inst| {
            if (!v.alive(st)) return;
            try v.step(inst, st);
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
            .dbg_inline_block => if (contractOf(v.attrStr(inst, .callee) orelse "") != .invariant) return error.StopPure,
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
                    .place => |pl| v.setResult(inst, try v.read(st.cells[pl.cell], pl.path, inst.ty)),
                    .elem_ptr => |e| v.setScalar(inst, try pool.select(e.mem, e.off)),
                    else => return v.ctx.unsupported("load through {t}", .{std.meta.activeTag(p)}),
                }
            },
            .ptr_cast, .addrspace_cast => v.setResult(inst, try v.arg(inst, 0)),
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
                v.setResult(inst, .{ .place = .{ .cell = p.place.cell, .path = try append(v.arena(), p.place.path, .{ .field = index }) } });
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
                    .obj => |ob| v.setResult(inst, try v.ctx.field(ob, index, inst.ty)),
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
                if (a == .scalar and pool.sortOf(a.scalar) == .bv) {
                    const info = try v.intTypeOf(inst.ty);
                    if (pool.bitsOf(a.scalar) != info.bits) return v.ctx.unsupported("bit_cast between widths", .{});
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
                const fields = try v.arena().alloc(value.Field, v.ops(inst).len);
                for (fields, v.ops(inst), 0..) |*f, o, i| f.* = .{ .index = @intCast(i), .value = try v.operand(o) };
                v.setResult(inst, .{ .obj = try v.ctx.create(value.Obj, .{ .base = null, .fields = fields }) });
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
                try v.returns.append(v.arena(), .{ .state = try st.clone(v.arena()), .value = val });
                try v.kill(st);
            },
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

    fn append(arena_alloc: Allocator, path: []const value.Step, s: value.Step) Allocator.Error![]const value.Step {
        const out = try arena_alloc.alloc(value.Step, path.len + 1);
        @memcpy(out[0..path.len], path);
        out[path.len] = s;
        return out;
    }

    // Memory.

    fn read(v: *Vc, cell: Value, path: []const value.Step, ty: schema.TypeId) Error!Value {
        if (path.len == 0) return cell;
        switch (path[0]) {
            .field => |i| {
                const o = switch (cell) {
                    .obj => |ob| ob,
                    else => return v.ctx.unsupported("field {d} of {t} in memory", .{ i, std.meta.activeTag(cell) }),
                };
                const f = try v.ctx.field(o, i, if (path.len == 1) ty else null);
                return v.read(f, path[1..], ty);
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

    fn update(v: *Vc, cell: Value, path: []const value.Step, new: Value) Error!Value {
        if (path.len == 0) return new;
        switch (path[0]) {
            .field => |i| {
                const o: *const value.Obj = switch (cell) {
                    .obj => |ob| ob,
                    .none => try v.ctx.create(value.Obj, .{ .base = null, .fields = &.{} }),
                    else => return v.ctx.unsupported("field store into {t}", .{std.meta.activeTag(cell)}),
                };
                const inner: Value = for (o.fields) |f| {
                    if (f.index == i) break f.value;
                } else .none;
                return v.ctx.withField(o, i, try v.update(inner, path[1..], new));
            },
            .slice_len => {
                if (cell != .slice or path.len != 1) return v.ctx.unsupported("store to a slice length", .{});
                return .{ .slice = .{ .mem = cell.slice.mem, .off = cell.slice.off, .len = new.scalar } };
            },
            .slice_ptr => return v.ctx.unsupported("store to a slice pointer", .{}),
        }
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
        try v.oblige(st, inst, .overflow, "integer overflow in `{s}` on {s}", .{ sym, v.ctx.typeName(inst.ty) }, ok);
        v.setScalar(inst, try pool.bin(op, a, b));
    }

    /// The result of `a op b` fits the type.
    fn noOverflow(v: *Vc, op: term.Op, a: Term, b: Term, info: value.IntInfo) Allocator.Error!Term {
        const pool = v.pool;
        const w = info.bits;
        const wide: u16 = if (op == .mul) 2 * w else w + 1;
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

    fn shift(v: *Vc, inst: *const Inst, st: *State) StepError!void {
        const pool = v.pool;
        const a = try v.scalarArg(inst, 0);
        var amount = try v.scalarArg(inst, 1);
        const info = try v.intTypeOf(inst.ty);
        const amount_bits = pool.bitsOf(amount);
        if (amount_bits > info.bits) return v.ctx.unsupported("shift amount wider than the value", .{});
        amount = try pool.zext(amount, info.bits);
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

    fn intCast(v: *Vc, inst: *const Inst, st: *State) StepError!void {
        const pool = v.pool;
        const o = v.ops(inst)[0];
        const a = try v.scalarArg(inst, 0);
        const src = v.ctx.intInfo(v.operandType(o)) orelse return v.ctx.unsupported("cast from a non-integer", .{});
        const dst = try v.intTypeOf(inst.ty);
        const wide = @max(src.bits, dst.bits) + 1;
        const x = if (src.signed) try pool.sext(a, wide) else try pool.zext(a, wide);
        const lo: i128 = if (dst.signed) -(@as(i128, 1) << @intCast(dst.bits - 1)) else 0;
        const hi: i128 = if (dst.signed) (@as(i128, 1) << @intCast(dst.bits - 1)) - 1 else @intCast(term.mask(dst.bits));
        const fits = try pool.@"and"(try pool.cmp(.sle, try pool.bvSigned(wide, lo), x), try pool.cmp(.sle, x, try pool.bvSigned(wide, hi)));
        try v.oblige(st, inst, .cast, "value does not fit in {s}", .{v.ctx.typeName(inst.ty)}, fits);
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
        if (v.pure and (v.containsInvariant(bodies[0]) or v.containsInvariant(bodies[1]))) {
            const pick = if (v.containsInvariant(bodies[0])) bodies[0] else bodies[1];
            return v.exec(v.pack.instsOf(pick.insts), st);
        }
        var then_state = try st.clone(v.arena());
        then_state.pc = try pool.@"and"(st.pc, c);
        var else_state = try st.clone(v.arena());
        else_state.pc = try pool.@"and"(st.pc, not_c);
        try v.exec(v.pack.instsOf(bodies[0].insts), &then_state);
        try v.exec(v.pack.instsOf(bodies[1].insts), &else_state);
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
        return v.ctx.unsupported("call to {s}", .{callee});
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

    const Contract = enum { requires, ensures, invariant, assume };

    fn contractOf(callee: []const u8) ?Contract {
        const trimmed = if (std.mem.endsWith(u8, callee, "__func")) callee[0 .. callee.len - "__func".len] else callee;
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
        const contract = contractOf(callee) orelse return v.block(inst, st, body);
        var args: [4]schema.Operand = undefined;
        const n = v.inlineArgs(body, &args);
        if (v.pure and contract != .invariant) return;
        switch (contract) {
            .requires => {
                if (n != 1) return v.ctx.unsupported("zv.requires with {d} arguments", .{n});
                if (v.obligations_seen or v.blocks.count() != 0) return v.ctx.unsupported("zv.requires must open the function body", .{});
                const ok = (try v.operand(args[0])).scalar;
                st.pc = try pool.@"and"(st.pc, ok);
            },
            .assume => {
                if (n != 1) return v.ctx.unsupported("zv.assume with {d} arguments", .{n});
                st.pc = try pool.@"and"(st.pc, (try v.operand(args[0])).scalar);
            },
            .ensures => {
                if (n != 2) return v.ctx.unsupported("zv.ensures with {d} arguments", .{n});
                const ok = (try v.operand(args[1])).scalar;
                try v.oblige(st, inst, .postcondition, "postcondition (zv.ensures) may not hold", .{}, ok);
                v.setResult(inst, try v.operand(args[0]));
            },
            .invariant => {
                if (n != 1) return v.ctx.unsupported("zv.invariant with {d} arguments", .{n});
                const ok = (try v.operand(args[0])).scalar;
                if (v.pure) {
                    try v.collected.append(v.arena(), .{ .id = inst.id, .ok = ok });
                    v.pure_seen = true;
                    return;
                }
                if (!v.head_invariants.contains(inst.id)) return v.ctx.unsupported("zv.invariant must open a loop body", .{});
            },
        }
    }

    // Loops.

    fn containsInvariant(v: *Vc, body: schema.Body) bool {
        for (v.pack.instsOf(body.insts)) |*i| {
            if (i.tag == .loop) continue;
            if (i.tag == .dbg_inline_block) {
                if (v.attrStr(i, .callee)) |c| if (contractOf(c) == .invariant) return true;
            }
            for (v.pack.bodiesOf(i.*)) |b| if (v.containsInvariant(b)) return true;
        }
        return false;
    }

    /// Cells written by a store inside `body`, loops included.
    fn modifiedCells(v: *Vc, body: schema.Body, out: *std.AutoArrayHashMapUnmanaged(u32, void)) Error!void {
        for (v.pack.instsOf(body.insts)) |*i| {
            switch (i.tag) {
                .store, .store_safe => {
                    const cell = v.cellOf(v.ops(i)[0]) orelse return v.ctx.unsupported("a store through an unknown pointer inside a loop", .{});
                    try out.put(v.arena(), cell, {});
                },
                .memset, .memset_safe, .memcpy, .memmove => return v.ctx.unsupported("{t} inside a loop", .{i.tag}),
                else => {},
            }
            for (v.pack.bodiesOf(i.*)) |b| try v.modifiedCells(b, out);
        }
    }

    fn cellOf(v: *Vc, o: schema.Operand) ?u32 {
        var cur = o;
        while (cur.kind == .inst) {
            const i = v.by_id[cur.value] orelse return null;
            switch (i.tag) {
                .alloc => return v.cell_of.get(i.id),
                .struct_field_ptr, .struct_field_ptr_index_0, .struct_field_ptr_index_1, .struct_field_ptr_index_2, .struct_field_ptr_index_3, .ptr_cast, .ptr_slice_len_ptr, .ptr_slice_ptr_ptr, .bit_cast => cur = v.ops(i)[0],
                else => return null,
            }
        }
        return null;
    }

    /// The invariants at the head of a loop body, evaluated in `st`.
    fn invariantsAt(v: *Vc, body: schema.Body, st: *const State) StepError![]const Collected {
        var probe = try st.clone(v.arena());
        const saved_pure = v.pure;
        const saved_seen = v.pure_seen;
        const saved_len = v.collected.items.len;
        v.pure = true;
        v.pure_seen = false;
        defer {
            v.pure = saved_pure;
            v.pure_seen = saved_seen;
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
        if (v.pure) return v.ctx.unsupported("a loop before the invariant of the enclosing loop", .{});
        const body = v.pack.bodiesOf(inst.*)[0];
        var modified: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
        try v.modifiedCells(body, &modified);

        const has_invariants = v.containsInvariant(body);
        var entry: []const Collected = &.{};
        if (has_invariants) {
            entry = try v.invariantsAt(body, st);
            for (entry) |c| {
                const at = v.by_id[c.id];
                try v.oblige(st, at, .invariant_entry, "loop invariant may not hold on entry", .{}, c.ok);
            }
        }

        var head = try st.clone(v.arena());
        head.cut = true;
        for (modified.keys()) |cell| {
            const name = v.cell_names.items[cell] orelse try std.fmt.allocPrint(v.arena(), "cell{d}", .{cell});
            head.cells[cell] = try v.ctx.havoc(name, head.cells[cell]);
        }
        var ctx: LoopCtx = .{ .invariants = &.{} };
        if (has_invariants) {
            ctx.invariants = try v.invariantsAt(body, &head);
            for (ctx.invariants) |c| {
                head.pc = try pool.@"and"(head.pc, c.ok);
                try v.head_invariants.put(v.arena(), c.id, {});
            }
        }
        try v.loops.put(v.arena(), inst.id, &ctx);
        defer _ = v.loops.remove(inst.id);
        try v.exec(v.pack.instsOf(body.insts), &head);
        try v.kill(st);
    }

    fn repeat(v: *Vc, inst: *const Inst, st: *State) StepError!void {
        const target = v.attrInt(inst, .target) orelse return v.ctx.unsupported("repeat without a target", .{});
        const ctx = v.loops.get(target) orelse return v.ctx.unsupported("repeat outside its loop", .{});
        const loop_inst = v.by_id[target].?;
        if (ctx.invariants.len != 0) {
            const now = try v.invariantsAt(v.pack.bodiesOf(loop_inst.*)[0], st);
            for (now) |c| try v.oblige(st, v.by_id[c.id], .invariant_step, "loop invariant may not be preserved by an iteration", .{}, c.ok);
        }
        try v.kill(st);
    }
};
