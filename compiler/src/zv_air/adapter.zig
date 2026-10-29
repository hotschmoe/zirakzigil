//! The only file that reads Air, InternPool and Zcu. It turns one function's finished AIR into a
//! single-function pack (see src/air/schema.zig) built by `Builder`; nothing else here mentions
//! compiler types.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Air = @import("../Air.zig");
const InternPool = @import("../InternPool.zig");
const Type = @import("../Type.zig");
const Value = @import("../Value.zig");
const Zcu = @import("../Zcu.zig");
const schema = @import("schema.zig");
const builder = @import("builder.zig");
const Builder = builder.Builder;

pub const Error = builder.Error;

/// Whether the function comes from std or another module shipped in the Zig lib directory
/// (compiler_rt, ubsan_rt, the test runner).
pub fn isToolchain(zcu: *Zcu, func_index: InternPool.Index) bool {
    const func = zcu.funcInfo(func_index);
    const mod = zcu.navFileScope(func.owner_nav).mod.?;
    return mod == zcu.std_mod or mod.root.root == .zig_lib;
}

/// Whether the compilation is the `zig build` configure script: the project's build.zig and every
/// dependency's. It is compiled only when the configuration cache misses, so exporting it would make
/// the export depend on that cache.
pub fn isBuildScript(zcu: *Zcu) bool {
    return zcu.root_mod.deps.contains("@build");
}

/// Adds the function to `b`. Everything else is allocated from `arena`.
pub fn build(b: *Builder, arena: Allocator, zcu: *Zcu, func_index: InternPool.Index, air: *const Air) Error!void {
    const ip = &zcu.intern_pool;
    const func = zcu.funcInfo(func_index);
    var c: Ctx = .{ .b = b, .arena = arena, .zcu = zcu, .air = air, .file = undefined };
    c.file = try c.fileId(zcu.navFileScopeIndex(func.owner_nav));
    c.base_line = zcu.navSrcLine(func.owner_nav);
    const file = c.file;

    const main = air.getMainBody();
    var params: std.ArrayList(schema.Param) = .empty;
    for (main) |index| {
        const i = @backingInt(index);
        if (air.instructions.items(.tag)[i] != .arg) break;
        const arg = air.instructions.items(.data)[i].arg;
        try params.append(arena, .{ .ty = try c.typeId(arg.ty), .zir_index = arg.zir_param_index });
    }

    const ret = try c.typeId(.fromInterned(ip.funcTypeReturnType(func.ty)));
    const insts = try c.body(main);
    try b.addFunc(.{
        .fqn = try b.str(try schema.scrub(arena, ip.getNav(func.owner_nav).fqn.toSlice(ip))),
        .file = file,
        .line = zcu.navSrcLine(func.owner_nav) + 1,
        .generic_instance = func.generic_owner != .none,
        .params = params.items,
        .ret = ret,
        .callees = c.refs.items,
        .insts = insts,
        .unsupported = c.unsupported,
    });
}

fn kindOf(tag: std.lang.TypeId) schema.TypeKind {
    return switch (tag) {
        .spirv => .@"opaque",
        inline else => |t| @field(schema.TypeKind, @tagName(t)),
    };
}

fn tagOf(tag: Air.Inst.Tag) schema.Tag {
    return switch (tag) {
        inline else => |t| @field(schema.Tag, @tagName(t)),
    };
}

const Ctx = struct {
    b: *Builder,
    arena: Allocator,
    zcu: *Zcu,
    air: *const Air,
    /// Declaration line (zero-based) of the function whose body is being walked.
    base_line: u32 = 0,
    file: schema.FileId,
    loc: schema.LocId = .none,
    type_ids: std.AutoHashMapUnmanaged(InternPool.Index, schema.TypeId) = .empty,
    file_ids: std.AutoHashMapUnmanaged(Zcu.File.Index, schema.FileId) = .empty,
    refs: std.ArrayList(schema.CalleeRef) = .empty,
    unsupported: u32 = 0,

    fn typeId(c: *Ctx, ty: Type) Error!schema.TypeId {
        if (c.type_ids.get(ty.toIntern())) |id| return id;
        const zcu = c.zcu;
        const tag = ty.zigTypeTag(zcu);
        var rec: schema.TypeRec = .{
            .name = try c.b.str(try schema.scrub(c.arena, try std.fmt.allocPrint(c.arena, "{f}", .{ty.fmt(zcu)}))),
            .kind = kindOf(tag),
        };
        switch (tag) {
            .int => {
                const info = ty.intInfo(zcu);
                rec.bits = info.bits;
                rec.flags.signed = info.signedness == .signed;
            },
            .float => rec.bits = ty.floatBits(zcu.getTarget()),
            .pointer => {
                const info = ty.ptrInfo(zcu);
                rec.child = try c.typeId(.fromInterned(info.child));
                rec.flags = .{
                    .size = @fromBackingInt(@intCast(@backingInt(info.flags.size))),
                    .is_const = info.flags.is_const,
                    .is_volatile = info.flags.is_volatile,
                    .allow_zero = info.flags.is_allowzero,
                };
            },
            .array => {
                rec.child = try c.typeId(ty.childType(zcu));
                rec.len = ty.arrayLen(zcu);
            },
            .vector => {
                rec.child = try c.typeId(ty.childType(zcu));
                rec.len = ty.vectorLen(zcu);
            },
            .optional => rec.child = try c.typeId(ty.optionalChild(zcu)),
            .error_union => rec.child = try c.typeId(ty.errorUnionPayload(zcu)),
            else => {},
        }
        const id = try c.b.typeRec(rec);
        try c.type_ids.put(c.arena, ty.toIntern(), id);
        return id;
    }

    fn fileId(c: *Ctx, index: Zcu.File.Index) Error!schema.FileId {
        if (c.file_ids.get(index)) |id| return id;
        const file = c.zcu.fileByIndex(index);
        const id = try c.b.file(
            if (file.mod) |mod| try schema.scrub(c.arena, mod.fully_qualified_name) else "",
            try schema.normalizePath(c.arena, file.sub_file_path),
        );
        try c.file_ids.put(c.arena, index, id);
        return id;
    }

    fn text(c: *Ctx, bytes: []const u8) Error!u64 {
        return @backingInt(try c.b.str(try schema.scrub(c.arena, bytes)));
    }

    fn calleeId(c: *Ctx, nav: InternPool.Nav.Index) Error!schema.CalleeId {
        const ip = &c.zcu.intern_pool;
        return c.b.callee(try schema.scrub(c.arena, ip.getNav(nav).fqn.toSlice(ip)));
    }

    /// Everything the compiler can say about a constant that the schema has a kind for; the rest is
    /// kept as the compiler's own printed form.
    fn constant(c: *Ctx, interned: InternPool.Index) Error!schema.ConstId {
        const zcu = c.zcu;
        const ip = &zcu.intern_pool;
        const ty: Type = .fromInterned(ip.typeOf(interned));
        var rec: schema.ConstRec = .{ .a = 0, .ty = try c.typeId(ty), .kind = .text };
        if (ty.toIntern() == .type_type) {
            rec.kind = .type;
            rec.a = @backingInt(try c.typeId(.fromInterned(interned)));
        } else switch (ip.indexToKey(interned)) {
            .undef => rec.kind = .undef,
            .simple_value => |value| switch (value) {
                .void => rec.kind = .void,
                .null => rec.kind = .null,
                .true, .false => {
                    rec.kind = .bool;
                    rec.a = @intFromBool(value == .true);
                },
                .@"unreachable" => {},
            },
            .int => |int| switch (int.storage) {
                // Sign extension to 64 bits cannot tell 2^63 from -2^63 in a wider signed type: that stays text.
                .u64 => |v| if (v <= std.math.maxInt(i64) or !ty.isSignedInt(zcu)) {
                    rec.kind = .int;
                    rec.a = v;
                },
                .i64 => |v| {
                    rec.kind = .int;
                    rec.a = @bitCast(v);
                },
                .big_int => {},
            },
            .float => |float| switch (float.storage) {
                .f16 => |v| {
                    rec.kind = .float;
                    rec.a = @bitCast(@as(f64, v));
                },
                .f32 => |v| {
                    rec.kind = .float;
                    rec.a = @bitCast(@as(f64, v));
                },
                .f64 => |v| {
                    rec.kind = .float;
                    rec.a = @bitCast(v);
                },
                .f80, .f128 => {},
            },
            .enum_literal => |name| {
                rec.kind = .enum_literal;
                rec.a = try c.text(name.toSlice(ip));
            },
            .enum_tag => |tag| {
                const enum_ty: Type = .fromInterned(tag.ty);
                if (enum_ty.enumTagFieldIndex(.fromInterned(interned), zcu)) |field| {
                    rec.kind = .enum_tag;
                    rec.a = try c.text(enum_ty.enumFieldName(field, zcu).toSlice(ip));
                }
            },
            .err => |err| {
                rec.kind = .@"error";
                rec.a = try c.text(err.name.toSlice(ip));
            },
            .func => |f| {
                rec.kind = .func;
                rec.a = @backingInt(try c.calleeId(f.owner_nav));
            },
            .@"extern" => |e| {
                rec.kind = .func;
                rec.a = @backingInt(try c.calleeId(e.owner_nav));
            },
            .opt => |opt| if (opt.val == .none) {
                rec.kind = .null;
            },
            else => {},
        }
        if (rec.kind == .text) rec.a = try c.text(try std.fmt.allocPrint(c.arena, "{f}", .{Value.fromInterned(interned).fmtValue(zcu)}));
        return c.b.constant(rec);
    }

    fn operand(c: *Ctx, ref: Air.Inst.Ref) Error!schema.Operand {
        if (ref == .none) return .nil;
        if (ref.toIndex()) |index| return .inst(@backingInt(index));
        return .constant(try c.constant(ref.toInterned().?));
    }

    fn operands(c: *Ctx, refs: []const Air.Inst.Ref) Error![]const schema.Operand {
        const out = try c.arena.alloc(schema.Operand, refs.len);
        for (refs, out) |ref, *slot| slot.* = try c.operand(ref);
        return out;
    }

    /// Reserves the body's records first so they stay contiguous, then fills them in order.
    fn body(c: *Ctx, indices: []const Air.Inst.Index) Error!schema.Range {
        const range = try c.b.reserve(indices.len);
        for (indices, range.off..) |index, slot| try c.inst(index, @intCast(slot));
        return range;
    }

    fn funcName(c: *Ctx, func_index: InternPool.Index) Error![]const u8 {
        const ip = &c.zcu.intern_pool;
        return schema.scrub(c.arena, ip.getNav(c.zcu.funcInfo(func_index).owner_nav).fqn.toSlice(ip));
    }

    fn inst(c: *Ctx, index: Air.Inst.Index, slot: u32) Error!void {
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
            .add,
            .add_optimized,
            .add_safe,
            .add_wrap,
            .add_sat,
            .sub,
            .sub_optimized,
            .sub_safe,
            .sub_wrap,
            .sub_sat,
            .mul,
            .mul_optimized,
            .mul_safe,
            .mul_wrap,
            .mul_sat,
            .div_float,
            .div_trunc,
            .div_floor,
            .div_ceil,
            .div_exact,
            .div_float_optimized,
            .div_trunc_optimized,
            .div_floor_optimized,
            .div_ceil_optimized,
            .div_exact_optimized,
            .rem,
            .mod,
            .rem_optimized,
            .mod_optimized,
            .bit_and,
            .bit_or,
            .xor,
            .cmp_lt,
            .cmp_lte,
            .cmp_eq,
            .cmp_gte,
            .cmp_gt,
            .cmp_neq,
            .cmp_lt_optimized,
            .cmp_lte_optimized,
            .cmp_eq_optimized,
            .cmp_gte_optimized,
            .cmp_gt_optimized,
            .cmp_neq_optimized,
            .store,
            .store_safe,
            .array_elem_val,
            .slice_elem_val,
            .ptr_elem_val,
            .shl,
            .shl_exact,
            .shl_sat,
            .shr,
            .shr_exact,
            .set_union_tag,
            .min,
            .max,
            .memcpy,
            .memmove,
            .memset,
            .memset_safe,
            => try a.ops(&.{ data.bin_op.lhs, data.bin_op.rhs }),

            .atomic_store_unordered, .atomic_store_monotonic, .atomic_store_release, .atomic_store_seq_cst => {
                try a.ops(&.{ data.bin_op.lhs, data.bin_op.rhs });
                try a.str(.order, @tagName(tag)["atomic_store_".len..]);
            },

            .is_null,
            .is_non_null,
            .is_null_ptr,
            .is_non_null_ptr,
            .is_err,
            .is_non_err,
            .is_err_ptr,
            .is_non_err_ptr,
            .ret,
            .ret_safe,
            .ret_load,
            .is_named_enum_value,
            .tag_name,
            .error_name,
            .sqrt,
            .sin,
            .cos,
            .tan,
            .exp,
            .exp2,
            .log,
            .log2,
            .log10,
            .floor,
            .ceil,
            .round,
            .trunc_float,
            .neg,
            .neg_optimized,
            .cmp_lte_errors_len,
            .set_err_return_trace,
            .c_va_end,
            => try a.ops(&.{data.un_op}),

            .trap, .breakpoint, .dbg_empty_stmt, .unreach, .ret_addr, .frame_addr, .save_err_return_trace_index => {},

            .alloc, .ret_ptr, .err_return_trace, .c_va_start => {},

            .arg => try a.int(.index, data.arg.zir_param_index),

            .not,
            .bit_cast,
            .bit_cast_safe,
            .ptr_cast,
            .ptr_from_int,
            .int_from_ptr,
            .error_cast,
            .error_from_int,
            .int_from_error,
            .union_from_enum,
            .load,
            .fptrunc,
            .fpext,
            .int_cast,
            .int_cast_safe,
            .trunc,
            .optional_payload,
            .optional_payload_ptr,
            .optional_payload_ptr_set,
            .errunion_payload_ptr_set,
            .wrap_optional,
            .unwrap_errunion_payload,
            .unwrap_errunion_err,
            .unwrap_errunion_payload_ptr,
            .unwrap_errunion_err_ptr,
            .wrap_errunion_payload,
            .wrap_errunion_err,
            .slice_ptr,
            .slice_len,
            .ptr_slice_len_ptr,
            .ptr_slice_ptr_ptr,
            .struct_field_ptr_index_0,
            .struct_field_ptr_index_1,
            .struct_field_ptr_index_2,
            .struct_field_ptr_index_3,
            .array_to_slice,
            .array_to_vector,
            .float_from_int,
            .splat,
            .int_from_float,
            .int_from_float_optimized,
            .int_from_float_safe,
            .int_from_float_optimized_safe,
            .get_union_tag,
            .clz,
            .ctz,
            .popcount,
            .byte_swap,
            .bit_reverse,
            .abs,
            .error_set_has_value,
            .addrspace_cast,
            .c_va_arg,
            .c_va_copy,
            => try a.ops(&.{data.ty_op.operand}),

            .block => try a.body(.block, air.unwrapBlock(index).body),
            .loop => try a.body(.loop, air.unwrapBlock(index).body),
            .dbg_inline_block => {
                const inlined = air.unwrapDbgBlock(index);
                const name = try c.funcName(inlined.func);
                try a.callee(name, true);
                const callee = zcu.funcInfo(inlined.func);
                const saved_line, const saved_file, const saved_loc = .{ c.base_line, c.file, c.loc };
                c.base_line = zcu.navSrcLine(callee.owner_nav);
                c.file = try c.fileId(zcu.navFileScopeIndex(callee.owner_nav));
                try a.body(.@"inline", inlined.body);
                c.base_line, c.file, c.loc = .{ saved_line, saved_file, saved_loc };
            },

            .slice,
            .slice_elem_ptr,
            .ptr_elem_ptr,
            .ptr_add,
            .ptr_sub,
            .add_with_overflow,
            .sub_with_overflow,
            .mul_with_overflow,
            .shl_with_overflow,
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
                        try a.callee(name, false);
                    }
                }
            },

            .dbg_var_ptr, .dbg_var_val, .dbg_arg_inline => {
                try a.ops(&.{data.pl_op.operand});
                const name: Air.NullTerminatedString = @fromBackingInt(@intCast(data.pl_op.payload));
                try a.str(.name, name.toSlice(air.*));
            },

            .struct_field_ptr, .agg_field_val, .spirv_runtime_array_len => {
                const extra = air.extraData(Air.StructField, data.ty_pl.payload).data;
                try a.ops(&.{extra.struct_operand});
                try a.int(.field, extra.field_index);
            },

            .dbg_stmt => {
                c.loc = try c.b.loc(c.file, c.base_line + data.dbg_stmt.line + 1, data.dbg_stmt.column + 1);
            },

            .aggregate_init => {
                const len: usize = @intCast(data.ty_pl.ty.arrayLen(zcu));
                try a.ops(@ptrCast(air.extra.items[data.ty_pl.payload..][0..len]));
            },
            .union_init => {
                const extra = air.extraData(Air.UnionInit, data.ty_pl.payload).data;
                try a.ops(&.{extra.init});
                try a.int(.field, extra.field_index);
            },

            .br, .switch_dispatch => {
                try a.ops(&.{data.br.operand});
                try a.target(data.br.block_inst);
            },
            .repeat => try a.target(data.repeat.loop_inst),

            .cond_br => {
                const cond = air.unwrapCondBr(index);
                try a.ops(&.{cond.condition});
                try a.body(.then, cond.then_body);
                try a.body(.@"else", cond.else_body);
            },
            .@"try", .try_cold => {
                const t = air.unwrapTry(index);
                try a.ops(&.{t.error_union});
                try a.body(.@"error", t.else_body);
            },
            .try_ptr, .try_ptr_cold => {
                const t = air.unwrapTryPtr(index);
                try a.ops(&.{t.error_union_ptr});
                try a.body(.@"error", t.else_body);
            },
            .switch_br, .loop_switch_br => {
                const sw = air.unwrapSwitch(index);
                try a.ops(&.{sw.operand});
                var it = sw.iterateCases();
                while (it.next()) |case| {
                    const ranges = try c.arena.alloc([2]schema.Operand, case.ranges.len);
                    for (case.ranges, ranges) |range, *out| out.* = .{ try c.operand(range[0]), try c.operand(range[1]) };
                    try a.bodies.append(c.arena, .{
                        .label = .case,
                        .items = try c.operands(case.items),
                        .ranges = ranges,
                        .insts = try c.body(case.body),
                    });
                }
                try a.body(.@"else", it.elseBody());
            },

            .cmpxchg_weak, .cmpxchg_strong => {
                const extra = air.extraData(Air.Cmpxchg, data.ty_pl.payload).data;
                try a.ops(&.{ extra.ptr, extra.expected_value, extra.new_value });
                try a.str(.success, @tagName(extra.successOrder()));
                try a.str(.failure, @tagName(extra.failureOrder()));
            },
            .atomic_load => {
                try a.ops(&.{data.atomic_load.ptr});
                try a.str(.order, @tagName(data.atomic_load.order));
            },
            .atomic_rmw => {
                const extra = air.extraData(Air.AtomicRmw, data.pl_op.payload).data;
                try a.ops(&.{ data.pl_op.operand, extra.operand });
                try a.str(.op, @tagName(extra.op()));
                try a.str(.order, @tagName(extra.ordering()));
            },
            .field_parent_ptr => {
                const extra = air.extraData(Air.FieldParentPtr, data.ty_pl.payload).data;
                try a.ops(&.{extra.field_ptr});
                try a.int(.field, extra.field_index);
            },
            .mul_add => {
                const extra = air.extraData(Air.Bin, data.pl_op.payload).data;
                try a.ops(&.{ extra.lhs, extra.rhs, data.pl_op.operand });
            },
            .select => {
                const extra = air.extraData(Air.Bin, data.pl_op.payload).data;
                try a.ops(&.{ data.pl_op.operand, extra.lhs, extra.rhs });
            },
            .reduce, .reduce_optimized => {
                try a.ops(&.{data.reduce.operand});
                try a.str(.operation, @tagName(data.reduce.operation));
            },
            .cmp_vector, .cmp_vector_optimized => {
                const extra = air.extraData(Air.VectorCmp, data.ty_pl.payload).data;
                try a.ops(&.{ extra.lhs, extra.rhs });
                try a.str(.op, @tagName(extra.compareOperator()));
            },
            .prefetch => {
                try a.ops(&.{data.prefetch.ptr});
                try a.int(.locality, data.prefetch.locality);
            },
            .runtime_nav_ptr => try a.str(.nav, ip.getNav(data.ty_nav.nav).fqn.toSlice(ip)),
            .assembly => {
                const asm_ = air.unwrapAsm(index);
                try a.ops(asm_.outputs);
                try a.ops(asm_.inputs);
                try a.str(.source, asm_.source);
                try a.flag(.@"volatile", asm_.is_volatile);
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
                try c.b.set(slot, .{ .id = i, .tag = tagOf(tag), .ty = .none });
                return;
            },
        }

        try c.b.set(slot, .{
            .id = i,
            .tag = tagOf(tag),
            .ty = try c.typeId(air.typeOfIndex(index, ip)),
            .loc = if (tag == .dbg_stmt) c.loc else loc,
            .ops = a.ops_list.items,
            .attrs = a.attr_list.items,
            .bodies = a.bodies.items,
        });
    }
};

const Acc = struct {
    c: *Ctx,
    ops_list: std.ArrayList(schema.Operand) = .empty,
    attr_list: std.ArrayList(schema.Attr) = .empty,
    bodies: std.ArrayList(builder.BodySpec) = .empty,

    fn ops(a: *Acc, refs: []const Air.Inst.Ref) Error!void {
        for (refs) |ref| try a.ops_list.append(a.c.arena, try a.c.operand(ref));
    }

    fn body(a: *Acc, label: schema.BodyLabel, indices: []const Air.Inst.Index) Error!void {
        try a.bodies.append(a.c.arena, .{ .label = label, .insts = try a.c.body(indices) });
    }

    fn attr(a: *Acc, key: schema.AttrKey, value: u32) Error!void {
        try a.attr_list.append(a.c.arena, .{ .key = key, .value = value });
    }

    fn int(a: *Acc, key: schema.AttrKey, v: u32) Error!void {
        try a.attr(key, v);
    }

    fn str(a: *Acc, key: schema.AttrKey, v: []const u8) Error!void {
        try a.attr(key, @intCast(try a.c.text(v)));
    }

    fn flag(a: *Acc, key: schema.AttrKey, v: bool) Error!void {
        try a.attr(key, @intFromBool(v));
    }

    fn target(a: *Acc, block: Air.Inst.Index) Error!void {
        try a.attr(.target, @backingInt(block));
    }

    /// A direct call or an inlined body: the attribute, and an entry in the function's callee list.
    fn callee(a: *Acc, name: []const u8, inlined: bool) Error!void {
        const id = try a.c.b.callee(try schema.scrub(a.c.arena, name));
        try a.attr(.callee, @backingInt(id));
        try a.c.refs.append(a.c.arena, .{ .inlined = inlined, .callee = @intCast(@backingInt(id)) });
    }
};
