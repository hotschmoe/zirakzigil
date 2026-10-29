//! The only file that reads Air, InternPool and Zcu. It turns one function's
//! finished AIR into a `Function` view that does not mention compiler types.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Air = @import("../Air.zig");
const InternPool = @import("../InternPool.zig");
const Type = @import("../Type.zig");
const Value = @import("../Value.zig");
const Zcu = @import("../Zcu.zig");

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

    fn inst(c: *Ctx, index: Air.Inst.Index) Error!Inst {
        const zcu = c.zcu;
        const ip = &zcu.intern_pool;
        const air = c.air;
        const i = @backingInt(index);
        const tag = air.instructions.items(.tag)[i];
        const data = air.instructions.items(.data)[i];
        const loc = c.loc;
        var a: Acc = .{ .c = c };

        // Grouped by payload shape, as in Air/print.zig.
        switch (tag) {
            .add, .add_optimized, .add_safe, .add_wrap, .add_sat,
            .sub, .sub_optimized, .sub_safe, .sub_wrap, .sub_sat,
            .mul, .mul_optimized, .mul_safe, .mul_wrap, .mul_sat,
            .div_float, .div_trunc, .div_floor, .div_ceil, .div_exact,
            .div_float_optimized, .div_trunc_optimized, .div_floor_optimized, .div_ceil_optimized, .div_exact_optimized,
            .rem, .mod, .rem_optimized, .mod_optimized,
            .bit_and, .bit_or, .xor,
            .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq,
            .cmp_lt_optimized, .cmp_lte_optimized, .cmp_eq_optimized, .cmp_gte_optimized, .cmp_gt_optimized, .cmp_neq_optimized,
            .store, .store_safe,
            .array_elem_val, .slice_elem_val, .ptr_elem_val,
            .shl, .shl_exact, .shl_sat, .shr, .shr_exact,
            .set_union_tag, .min, .max,
            .memcpy, .memmove, .memset, .memset_safe,
            => try a.ops(&.{ data.bin_op.lhs, data.bin_op.rhs }),

            .atomic_store_unordered, .atomic_store_monotonic, .atomic_store_release, .atomic_store_seq_cst => {
                try a.ops(&.{ data.bin_op.lhs, data.bin_op.rhs });
                try a.str("order", @tagName(tag)["atomic_store_".len..]);
            },

            .is_null, .is_non_null, .is_null_ptr, .is_non_null_ptr,
            .is_err, .is_non_err, .is_err_ptr, .is_non_err_ptr,
            .ret, .ret_safe, .ret_load,
            .is_named_enum_value, .tag_name, .error_name,
            .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10,
            .floor, .ceil, .round, .trunc_float, .neg, .neg_optimized,
            .cmp_lte_errors_len, .set_err_return_trace, .c_va_end,
            => try a.ops(&.{data.un_op}),

            .trap, .breakpoint, .dbg_empty_stmt, .unreach, .ret_addr, .frame_addr, .save_err_return_trace_index => {},

            .alloc, .ret_ptr, .err_return_trace, .c_va_start => {},

            .arg => try a.int("index", data.arg.zir_param_index),

            .not, .bit_cast, .bit_cast_safe, .ptr_cast, .ptr_from_int, .int_from_ptr,
            .error_cast, .error_from_int, .int_from_error, .union_from_enum, .load,
            .fptrunc, .fpext, .int_cast, .int_cast_safe, .trunc,
            .optional_payload, .optional_payload_ptr, .optional_payload_ptr_set, .errunion_payload_ptr_set,
            .wrap_optional, .unwrap_errunion_payload, .unwrap_errunion_err,
            .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr,
            .wrap_errunion_payload, .wrap_errunion_err,
            .slice_ptr, .slice_len, .ptr_slice_len_ptr, .ptr_slice_ptr_ptr,
            .struct_field_ptr_index_0, .struct_field_ptr_index_1, .struct_field_ptr_index_2, .struct_field_ptr_index_3,
            .array_to_slice, .array_to_vector, .float_from_int, .splat,
            .int_from_float, .int_from_float_optimized, .int_from_float_safe, .int_from_float_optimized_safe,
            .get_union_tag, .clz, .ctz, .popcount, .byte_swap, .bit_reverse, .abs,
            .error_set_has_value, .addrspace_cast, .c_va_arg, .c_va_copy,
            => try a.ops(&.{data.ty_op.operand}),

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

            .slice, .slice_elem_ptr, .ptr_elem_ptr, .ptr_add, .ptr_sub,
            .add_with_overflow, .sub_with_overflow, .mul_with_overflow, .shl_with_overflow,
            => {
                const bin = air.extraData(Air.Bin, data.ty_pl.payload).data;
                try a.ops(&.{ bin.lhs, bin.rhs });
            },

            .call, .call_always_tail, .call_never_tail, .call_never_inline => {
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

            .dbg_var_ptr, .dbg_var_val, .dbg_arg_inline => {
                try a.ops(&.{data.pl_op.operand});
                const name: Air.NullTerminatedString = @fromBackingInt(@intCast(data.pl_op.payload));
                try a.str("name", name.toSlice(air.*));
            },

            .struct_field_ptr, .agg_field_val, .spirv_runtime_array_len => {
                const extra = air.extraData(Air.StructField, data.ty_pl.payload).data;
                try a.ops(&.{extra.struct_operand});
                try a.int("field", extra.field_index);
            },

            .dbg_stmt => {
                c.loc = .{ .file = c.file, .line = c.base_line + data.dbg_stmt.line + 1, .col = data.dbg_stmt.column + 1 };
                try a.int("line", c.loc.?.line);
                try a.int("col", c.loc.?.col);
            },

            .aggregate_init => {
                const len: usize = @intCast(data.ty_pl.ty.arrayLen(zcu));
                try a.ops(@ptrCast(air.extra.items[data.ty_pl.payload..][0..len]));
            },
            .union_init => {
                const extra = air.extraData(Air.UnionInit, data.ty_pl.payload).data;
                try a.ops(&.{extra.init});
                try a.int("field", extra.field_index);
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
            .@"try", .try_cold => {
                const t = air.unwrapTry(index);
                try a.ops(&.{t.error_union});
                try a.body("error", t.else_body);
            },
            .try_ptr, .try_ptr_cold => {
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

            .cmpxchg_weak, .cmpxchg_strong => {
                const extra = air.extraData(Air.Cmpxchg, data.ty_pl.payload).data;
                try a.ops(&.{ extra.ptr, extra.expected_value, extra.new_value });
                try a.str("success", @tagName(extra.successOrder()));
                try a.str("failure", @tagName(extra.failureOrder()));
            },
            .atomic_load => {
                try a.ops(&.{data.atomic_load.ptr});
                try a.str("order", @tagName(data.atomic_load.order));
            },
            .atomic_rmw => {
                const extra = air.extraData(Air.AtomicRmw, data.pl_op.payload).data;
                try a.ops(&.{ data.pl_op.operand, extra.operand });
                try a.str("op", @tagName(extra.op()));
                try a.str("order", @tagName(extra.ordering()));
            },
            .field_parent_ptr => {
                const extra = air.extraData(Air.FieldParentPtr, data.ty_pl.payload).data;
                try a.ops(&.{extra.field_ptr});
                try a.int("field", extra.field_index);
            },
            .mul_add, .select => {
                const extra = air.extraData(Air.Bin, data.pl_op.payload).data;
                try a.ops(&.{ data.pl_op.operand, extra.lhs, extra.rhs });
            },
            .reduce, .reduce_optimized => {
                try a.ops(&.{data.reduce.operand});
                try a.str("operation", @tagName(data.reduce.operation));
            },
            .cmp_vector, .cmp_vector_optimized => {
                const extra = air.extraData(Air.VectorCmp, data.ty_pl.payload).data;
                try a.ops(&.{ extra.lhs, extra.rhs });
                try a.str("op", @tagName(extra.compareOperator()));
            },
            .prefetch => {
                try a.ops(&.{data.prefetch.ptr});
                try a.int("locality", data.prefetch.locality);
            },
            .runtime_nav_ptr => try a.str("nav", ip.getNav(data.ty_nav.nav).fqn.toSlice(ip)),
            .assembly => {
                const asm_ = air.unwrapAsm(index);
                try a.ops(asm_.outputs);
                try a.ops(asm_.inputs);
                try a.str("source", asm_.source);
                try a.flag("volatile", asm_.is_volatile);
            },

            // Not produced before legalization, or not decoded yet.
            .legalize_vec_elem_val,
            .legalize_vec_store_elem,
            .legalize_compiler_rt_call,
            .inferred_alloc,
            .inferred_alloc_comptime,
            .shuffle_one,
            .shuffle_two,
            .wasm_memory_size,
            .wasm_memory_grow,
            .work_item_id,
            .work_group_size,
            .work_group_id,
            => {
                c.unsupported += 1;
                return .{ .id = i, .tag = @tagName(tag), .supported = false };
            },
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

    fn ops(a: *Acc, refs: []const Air.Inst.Ref) Error!void {
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
};
