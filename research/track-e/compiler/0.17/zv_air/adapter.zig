//! The only file that reads Air, InternPool and Zcu. It turns one function's
//! finished AIR into a `Function` view that does not mention compiler types.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Air = @import("../Air.zig");
const InternPool = @import("../InternPool.zig");
const Type = @import("../Type.zig");
const Value = @import("../Value.zig");
const Zcu = @import("../Zcu.zig");
const shapes = @import("shapes.zig");

pub const TypeId = u32;

pub const Operand = union(enum) {
    none,
    inst: u32,
    constant: struct { ty: TypeId, val: []const u8 },
};

pub const Attr = struct {
    key: []const u8,
    value: union(enum) { int: u64, str: []const u8, flag: bool, inst: u32 },
};

pub const Loc = struct { file: u32, line: u32, col: u32 };

pub const Body = struct {
    label: []const u8,
    items: []const Operand = &.{},
    ranges: []const [2]Operand = &.{},
    insts: []const Inst,
};

pub const Inst = struct {
    id: u32,
    tag: []const u8,
    supported: bool = true,
    ty: ?TypeId = null,
    operands: []const Operand = &.{},
    attrs: []const Attr = &.{},
    loc: ?Loc = null,
    bodies: []const Body = &.{},
};

pub const Callee = struct { fqn: []const u8, inlined: bool };
pub const SourceFile = struct { module: []const u8, path: []const u8 };
pub const TypeEntry = struct { name: []const u8, kind: []const u8 };
pub const Param = struct { ty: TypeId, zir_index: u32 };

pub const Function = struct {
    fqn: []const u8,
    file: u32,
    line: u32,
    generic_instance: bool,
    params: []const Param,
    ret: TypeId,
    files: []const SourceFile,
    types: []const TypeEntry,
    insts: []const Inst,
    callees: []const Callee,
    unsupported: u32,
};

pub const Error = Allocator.Error;

/// Whether the function comes from std or another module shipped in the Zig lib directory
/// (compiler_rt, ubsan_rt, the test runner).
pub fn isToolchain(zcu: *Zcu, func_index: InternPool.Index) bool {
    const func = zcu.funcInfo(func_index);
    const mod = zcu.navFileScope(func.owner_nav).mod.?;
    return mod == zcu.std_mod or mod.root.root == .zig_lib;
}

/// Builds the view of `air`. Everything is allocated from `arena`.
pub fn view(arena: Allocator, zcu: *Zcu, func_index: InternPool.Index, air: *const Air) Error!Function {
    const ip = &zcu.intern_pool;
    const func = zcu.funcInfo(func_index);
    var c: Ctx = .{ .arena = arena, .zcu = zcu, .air = air };
    c.file = try c.fileId(zcu.navFileScopeIndex(func.owner_nav));
    c.base_line = zcu.navSrcLine(func.owner_nav);

    const main = air.getMainBody();
    var params: std.ArrayList(Param) = .empty;
    for (main) |index| {
        const i = @backingInt(index);
        if (air.instructions.items(.tag)[i] != .arg) break;
        const arg = air.instructions.items(.data)[i].arg;
        try params.append(arena, .{ .ty = try c.typeId(arg.ty), .zir_index = arg.zir_param_index });
    }

    const ret = try c.typeId(.fromInterned(ip.funcTypeReturnType(func.ty)));
    const insts = try c.body(main);
    return .{
        .fqn = ip.getNav(func.owner_nav).fqn.toSlice(ip),
        .file = 0,
        .line = zcu.navSrcLine(func.owner_nav) + 1,
        .generic_instance = func.generic_owner != .none,
        .params = params.items,
        .ret = ret,
        .files = c.files.items,
        .types = c.types.items,
        .insts = insts,
        .callees = c.callees.items,
        .unsupported = c.unsupported,
    };
}

const Ctx = struct {
    arena: Allocator,
    zcu: *Zcu,
    air: *const Air,
    /// Declaration line (zero-based) of the function whose body is being walked.
    base_line: u32 = 0,
    file: u32 = 0,
    loc: ?Loc = null,
    types: std.ArrayList(TypeEntry) = .empty,
    type_ids: std.AutoHashMapUnmanaged(InternPool.Index, TypeId) = .empty,
    files: std.ArrayList(SourceFile) = .empty,
    file_ids: std.AutoHashMapUnmanaged(Zcu.File.Index, u32) = .empty,
    callees: std.ArrayList(Callee) = .empty,
    unsupported: u32 = 0,

    fn typeId(c: *Ctx, ty: Type) Error!TypeId {
        const gop = try c.type_ids.getOrPut(c.arena, ty.toIntern());
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(c.types.items.len);
            try c.types.append(c.arena, .{
                .name = try std.fmt.allocPrint(c.arena, "{f}", .{ty.fmt(c.zcu)}),
                .kind = @tagName(ty.zigTypeTag(c.zcu)),
            });
        }
        return gop.value_ptr.*;
    }

    fn fileId(c: *Ctx, index: Zcu.File.Index) Error!u32 {
        const gop = try c.file_ids.getOrPut(c.arena, index);
        if (!gop.found_existing) {
            const file = c.zcu.fileByIndex(index);
            gop.value_ptr.* = @intCast(c.files.items.len);
            try c.files.append(c.arena, .{
                .module = if (file.mod) |mod| mod.fully_qualified_name else "",
                .path = file.sub_file_path,
            });
        }
        return gop.value_ptr.*;
    }

    fn operand(c: *Ctx, ref: Air.Inst.Ref) Error!Operand {
        if (ref == .none) return .none;
        if (ref.toIndex()) |index| return .{ .inst = @backingInt(index) };
        const interned = ref.toInterned().?;
        const ty: Type = .fromInterned(c.zcu.intern_pool.typeOf(interned));
        return .{ .constant = .{
            .ty = try c.typeId(ty),
            .val = try std.fmt.allocPrint(c.arena, "{f}", .{Value.fromInterned(interned).fmtValue(c.zcu)}),
        } };
    }

    fn operands(c: *Ctx, refs: []const Air.Inst.Ref) Error![]const Operand {
        const out = try c.arena.alloc(Operand, refs.len);
        for (refs, out) |ref, *slot| slot.* = try c.operand(ref);
        return out;
    }

    fn body(c: *Ctx, indices: []const Air.Inst.Index) Error![]const Inst {
        const out = try c.arena.alloc(Inst, indices.len);
        for (indices, out) |index, *slot| slot.* = try c.inst(index);
        return out;
    }

    fn funcName(c: *Ctx, func_index: InternPool.Index) []const u8 {
        const ip = &c.zcu.intern_pool;
        return ip.getNav(c.zcu.funcInfo(func_index).owner_nav).fqn.toSlice(ip);
    }

    fn skip(c: *Ctx, i: u32, tag: Air.Inst.Tag) Inst {
        c.unsupported += 1;
        return .{ .id = i, .tag = @tagName(tag), .supported = false };
    }

    fn inst(c: *Ctx, index: Air.Inst.Index) Error!Inst {
        const zcu = c.zcu;
        const ip = &zcu.intern_pool;
        const air = c.air;
        const i = @backingInt(index);
        const tag = air.instructions.items(.tag)[i];
        const data = air.instructions.items(.data)[i];
        const loc = c.loc;
        var a: Acc = .{ .c = c };

        // Target-specific and pre-legalization-only instructions are not exported.
        inline for (.{ "legalize_", "wasm_", "work_" }) |prefix| {
            if (std.mem.startsWith(u8, @tagName(tag), prefix)) return c.skip(i, tag);
        }

        if (try shapes.operands(&a, air, tag, data)) |manual| switch (manual) {
            .inferred_alloc, .shuffle_one, .shuffle_two, .legalize_compiler_rt_call => return c.skip(i, tag),
            .block => try a.body("block", air.unwrapBlock(index).body),
            .loop => try a.body("loop", air.unwrapBlock(index).body),
            .dbg_inline_block => {
                const inlined = air.unwrapDbgBlock(index);
                const name = c.funcName(inlined.func);
                try a.str("callee", name);
                try c.callees.append(c.arena, .{ .fqn = name, .inlined = true });
                const callee = zcu.funcInfo(inlined.func);
                const saved_line, const saved_file, const saved_loc = .{ c.base_line, c.file, c.loc };
                c.base_line = zcu.navSrcLine(callee.owner_nav);
                c.file = try c.fileId(zcu.navFileScopeIndex(callee.owner_nav));
                try a.body("inline", inlined.body);
                c.base_line, c.file, c.loc = .{ saved_line, saved_file, saved_loc };
            },
            .call => {
                const call = air.unwrapCall(index);
                try a.ops(&.{call.callee});
                try a.ops(call.args);
                if (call.callee.toInterned()) |callee| {
                    const nav: ?InternPool.Nav.Index = switch (ip.indexToKey(callee)) {
                        .func => |f| f.owner_nav,
                        .@"extern" => |e| e.owner_nav,
                        else => null,
                    };
                    if (nav) |n| {
                        const name = ip.getNav(n).fqn.toSlice(ip);
                        try a.str("callee", name);
                        try c.callees.append(c.arena, .{ .fqn = name, .inlined = false });
                    }
                }
            },
            .aggregate_init => {
                const len: usize = @intCast(data.ty_pl.ty.arrayLen(zcu));
                try a.ops(@ptrCast(air.extra.items[data.ty_pl.payload..][0..len]));
            },
            .br, .switch_dispatch => {
                try a.ops(&.{data.br.operand});
                try a.target(data.br.block_inst);
            },
            .repeat => try a.target(data.repeat.loop_inst),
            .cond_br => {
                const cond = air.unwrapCondBr(index);
                try a.ops(&.{cond.condition});
                try a.body("then", cond.then_body);
                try a.body("else", cond.else_body);
            },
            .@"try" => {
                const t = air.unwrapTry(index);
                try a.ops(&.{t.error_union});
                try a.body("error", t.else_body);
            },
            .try_ptr => {
                const t = air.unwrapTryPtr(index);
                try a.ops(&.{t.error_union_ptr});
                try a.body("error", t.else_body);
            },
            .switch_br, .loop_switch_br => {
                const sw = air.unwrapSwitch(index);
                try a.ops(&.{sw.operand});
                var it = sw.iterateCases();
                while (it.next()) |case| {
                    const ranges = try c.arena.alloc([2]Operand, case.ranges.len);
                    for (case.ranges, ranges) |range, *out| out.* = .{ try c.operand(range[0]), try c.operand(range[1]) };
                    try a.bodies.append(c.arena, .{
                        .label = "case",
                        .items = try c.operands(case.items),
                        .ranges = ranges,
                        .insts = try c.body(case.body),
                    });
                }
                try a.body("else", it.elseBody());
            },
            .assembly => {
                const asm_ = air.unwrapAsm(index);
                try a.ops(asm_.outputs);
                try a.ops(asm_.inputs);
                try a.str("source", asm_.source);
                try a.flag("volatile", asm_.is_volatile);
            },
        };

        switch (tag) {
            .arg => try a.int("index", data.arg.zir_param_index),
            .dbg_stmt => {
                c.loc = .{ .file = c.file, .line = c.base_line + data.dbg_stmt.line + 1, .col = data.dbg_stmt.column + 1 };
                try a.int("line", c.loc.?.line);
                try a.int("col", c.loc.?.col);
            },
            .dbg_var_ptr, .dbg_var_val, .dbg_arg_inline => {
                const name: Air.NullTerminatedString = @fromBackingInt(@intCast(data.pl_op.payload));
                try a.str("name", name.toSlice(air.*));
            },
            .atomic_store_unordered, .atomic_store_monotonic, .atomic_store_release, .atomic_store_seq_cst => {
                try a.str("order", @tagName(tag)["atomic_store_".len..]);
            },
            .runtime_nav_ptr => try a.str("nav", ip.getNav(data.ty_nav.nav).fqn.toSlice(ip)),
            else => {},
        }

        return .{
            .id = i,
            .tag = @tagName(tag),
            .ty = try c.typeId(air.typeOfIndex(index, ip)),
            .operands = a.ops_list.items,
            .attrs = a.attr_list.items,
            .loc = if (tag == .dbg_stmt) c.loc else loc,
            .bodies = a.bodies.items,
        };
    }
};

const Acc = struct {
    c: *Ctx,
    ops_list: std.ArrayList(Operand) = .empty,
    attr_list: std.ArrayList(Attr) = .empty,
    bodies: std.ArrayList(Body) = .empty,

    pub fn ops(a: *Acc, refs: []const Air.Inst.Ref) Error!void {
        for (refs) |ref| try a.ops_list.append(a.c.arena, try a.c.operand(ref));
    }

    fn body(a: *Acc, label: []const u8, indices: []const Air.Inst.Index) Error!void {
        try a.bodies.append(a.c.arena, .{ .label = label, .insts = try a.c.body(indices) });
    }

    fn int(a: *Acc, key: []const u8, v: u64) Error!void {
        try a.attr_list.append(a.c.arena, .{ .key = key, .value = .{ .int = v } });
    }

    fn str(a: *Acc, key: []const u8, v: []const u8) Error!void {
        try a.attr_list.append(a.c.arena, .{ .key = key, .value = .{ .str = v } });
    }

    fn flag(a: *Acc, key: []const u8, v: bool) Error!void {
        try a.attr_list.append(a.c.arena, .{ .key = key, .value = .{ .flag = v } });
    }

    fn target(a: *Acc, block: Air.Inst.Index) Error!void {
        try a.attr_list.append(a.c.arena, .{ .key = "target", .value = .{ .inst = @backingInt(block) } });
    }

    pub fn field(a: *Acc, comptime name: std.meta.FieldEnum(Air.Inst.Data), value: anytype) Error!void {
        switch (name) {
            .bin_op, .un_op, .ty_op, .ty_pl, .pl_op => {},
            .atomic_load => try a.str("order", @tagName(value.order)),
            .prefetch => try a.int("locality", value.locality),
            .reduce => try a.str("operation", @tagName(value.operation)),
            .no_op, .ty, .arg, .br, .repeat, .dbg_stmt, .ty_nav => comptime unreachable,
            .legalize_compiler_rt_call, .inferred_alloc_comptime, .inferred_alloc => comptime unreachable,
        }
    }

    pub fn extra(a: *Acc, payload: anytype) Error!void {
        switch (@TypeOf(payload)) {
            Air.Bin => {},
            Air.StructField, Air.UnionInit, Air.FieldParentPtr => try a.int("field", payload.field_index),
            Air.Cmpxchg => {
                try a.str("success", @tagName(payload.successOrder()));
                try a.str("failure", @tagName(payload.failureOrder()));
            },
            Air.AtomicRmw => {
                try a.str("op", @tagName(payload.op()));
                try a.str("order", @tagName(payload.ordering()));
            },
            Air.VectorCmp => try a.str("op", @tagName(payload.compareOperator())),
            else => @compileError("undecoded Air payload " ++ @typeName(@TypeOf(payload))),
        }
    }
};
