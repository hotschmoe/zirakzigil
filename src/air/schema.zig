//! Schema v2 of the zig-zv AIR export: the single definition of the binary pack, the index entry and
//! (with json.zig) the JSON form. Depends on std only, so the compiler and out-of-compiler readers
//! (`zvc`, `zv-own`) share it without sharing compiler code.
//!
//! A pack holds the functions one compilation analyzed. Every table is shared by all of its functions.
//! All records are extern structs without padding, laid out little-endian, so a reader casts the bytes
//! in place: no parsing beyond the header's section table. The writer is deterministic: records follow
//! first use, functions follow (fqn, content id), and no compiler-internal id reaches a name.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const version = 2;
pub const magic: [8]u8 = "ZVAIRPK\x00".*;
pub const pack_ext = ".zvp";
pub const index_ext = ".zvi";
pub const json_ext = ".json";

comptime {
    assert(builtin.cpu.arch.endian() == .little);
}

pub const StrId = enum(u32) { _ };
pub const FileId = enum(u32) { _ };
pub const TypeId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const ConstId = enum(u32) { _ };
pub const CalleeId = enum(u32) { _ };
pub const LocId = enum(u32) { none = std.math.maxInt(u32), _ };

pub const Range = extern struct { off: u32, len: u32 };

pub const StrEntry = extern struct { off: u32, len: u32 };

pub const FileRec = extern struct { module: StrId, path: StrId };

/// The names of `std.builtin.TypeId`.
pub const TypeKind = enum(u8) {
    type,
    void,
    bool,
    noreturn,
    int,
    float,
    pointer,
    array,
    @"struct",
    comptime_float,
    comptime_int,
    undefined,
    null,
    optional,
    error_union,
    error_set,
    @"enum",
    @"union",
    @"fn",
    @"opaque",
    frame,
    @"anyframe",
    vector,
    enum_literal,
};

pub const PointerSize = enum(u2) { one, many, slice, c };

pub const TypeFlags = packed struct(u8) {
    size: PointerSize = .one,
    is_const: bool = false,
    is_volatile: bool = false,
    allow_zero: bool = false,
    signed: bool = false,
    _: u2 = 0,
};

/// `child` is the pointee, element, payload or child type; `bits` is the width of ints and floats;
/// `len` is the length of arrays and vectors.
pub const TypeRec = extern struct {
    len: u64 = 0,
    name: StrId,
    child: TypeId = .none,
    bits: u16 = 0,
    kind: TypeKind,
    flags: TypeFlags = .{},
    reserved: u32 = 0,
};

pub const ConstKind = enum(u32) {
    /// `a` is unused for undef, void and null.
    undef,
    void,
    null,
    /// `a` is 0 or 1.
    bool,
    /// `a` is the value, sign-extended to 64 bits for signed types.
    int,
    /// `a` is the IEEE bit pattern of an f16, f32 or f64, widened to f64.
    float,
    /// `a` is a StrId: the name of an enum literal, of an enum value, or of an error.
    enum_literal,
    enum_tag,
    @"error",
    /// `a` is a CalleeId: a function or extern used as a value.
    func,
    /// `a` is a TypeId: the value is that type.
    type,
    /// `a` is a StrId: the value as the compiler prints it, for everything not decoded above.
    text,
};

/// `ty` is the type of the value.
pub const ConstRec = extern struct { a: u64, ty: TypeId, kind: ConstKind };

pub const LocRec = extern struct { file: FileId, line: u32, col: u32 };

pub const Param = extern struct { ty: TypeId, zir_index: u32 };

pub const CalleeRef = packed struct(u32) { inlined: bool, callee: u31 };

pub const FuncFlags = packed struct(u32) { generic_instance: bool = false, _: u31 = 0 };

pub const Func = extern struct {
    /// A hash of the function's own encoding: tells generic instances of one name apart.
    id: u64,
    fqn: StrId,
    file: FileId,
    line: u32,
    ret: TypeId,
    params: Range,
    callees: Range,
    insts: Range,
    unsupported: u32,
    flags: FuncFlags,
};

pub const OperandKind = enum(u2) { none, inst, constant };

pub const Operand = packed struct(u32) {
    kind: OperandKind,
    value: u30,

    pub const nil: Operand = .{ .kind = .none, .value = 0 };

    pub fn inst(id: u32) Operand {
        return .{ .kind = .inst, .value = @intCast(id) };
    }

    pub fn constant(id: ConstId) Operand {
        return .{ .kind = .constant, .value = @intCast(@backingInt(id)) };
    }
};

pub const AttrKind = enum { int, str, flag, inst, callee };

pub const AttrKey = enum(u32) {
    index,
    field,
    callee,
    target,
    order,
    name,
    op,
    success,
    failure,
    operation,
    locality,
    nav,
    source,
    @"volatile",

    pub fn kind(key: AttrKey) AttrKind {
        return switch (key) {
            .index, .field, .locality => .int,
            .callee => .callee,
            .target => .inst,
            .@"volatile" => .flag,
            .order, .name, .op, .success, .failure, .operation, .nav, .source => .str,
        };
    }
};

pub const Attr = extern struct { key: AttrKey, value: u32 };

pub const BodyLabel = enum(u32) { then, @"else", @"error", block, loop, @"inline", case };

/// `items` and `ranges` (pairs of operands) belong to a switch prong.
pub const Body = extern struct { label: BodyLabel, items: Range, ranges: Range, insts: Range };

/// The names of `Air.Inst.Tag` in 0.17.0, in its order. New tags are added at the end.
pub const Tag = enum(u8) {
    arg,
    add,
    add_safe,
    add_optimized,
    add_wrap,
    add_sat,
    sub,
    sub_safe,
    sub_optimized,
    sub_wrap,
    sub_sat,
    mul,
    mul_safe,
    mul_optimized,
    mul_wrap,
    mul_sat,
    div_float,
    div_float_optimized,
    div_trunc,
    div_trunc_optimized,
    div_floor,
    div_floor_optimized,
    div_ceil,
    div_ceil_optimized,
    div_exact,
    div_exact_optimized,
    rem,
    rem_optimized,
    mod,
    mod_optimized,
    ptr_add,
    ptr_sub,
    max,
    min,
    add_with_overflow,
    sub_with_overflow,
    mul_with_overflow,
    shl_with_overflow,
    alloc,
    inferred_alloc,
    inferred_alloc_comptime,
    ret_ptr,
    assembly,
    bit_and,
    bit_or,
    shr,
    shr_exact,
    shl,
    shl_exact,
    shl_sat,
    xor,
    not,
    bit_cast,
    bit_cast_safe,
    ptr_cast,
    ptr_from_int,
    int_from_ptr,
    error_cast,
    error_from_int,
    int_from_error,
    union_from_enum,
    block,
    loop,
    repeat,
    br,
    trap,
    breakpoint,
    ret_addr,
    frame_addr,
    call,
    call_always_tail,
    call_never_tail,
    call_never_inline,
    clz,
    ctz,
    popcount,
    byte_swap,
    bit_reverse,
    sqrt,
    sin,
    cos,
    tan,
    exp,
    exp2,
    log,
    log2,
    log10,
    abs,
    floor,
    ceil,
    round,
    trunc_float,
    neg,
    neg_optimized,
    cmp_lt,
    cmp_lt_optimized,
    cmp_lte,
    cmp_lte_optimized,
    cmp_eq,
    cmp_eq_optimized,
    cmp_gte,
    cmp_gte_optimized,
    cmp_gt,
    cmp_gt_optimized,
    cmp_neq,
    cmp_neq_optimized,
    cmp_vector,
    cmp_vector_optimized,
    cond_br,
    switch_br,
    loop_switch_br,
    switch_dispatch,
    @"try",
    try_cold,
    try_ptr,
    try_ptr_cold,
    dbg_stmt,
    dbg_empty_stmt,
    dbg_inline_block,
    dbg_var_ptr,
    dbg_var_val,
    dbg_arg_inline,
    is_null,
    is_non_null,
    is_null_ptr,
    is_non_null_ptr,
    is_err,
    is_non_err,
    is_err_ptr,
    is_non_err_ptr,
    load,
    ret,
    ret_safe,
    ret_load,
    store,
    store_safe,
    unreach,
    fptrunc,
    fpext,
    int_cast,
    int_cast_safe,
    trunc,
    optional_payload,
    optional_payload_ptr,
    optional_payload_ptr_set,
    wrap_optional,
    unwrap_errunion_payload,
    unwrap_errunion_err,
    unwrap_errunion_payload_ptr,
    unwrap_errunion_err_ptr,
    errunion_payload_ptr_set,
    wrap_errunion_payload,
    wrap_errunion_err,
    struct_field_ptr,
    struct_field_ptr_index_0,
    struct_field_ptr_index_1,
    struct_field_ptr_index_2,
    struct_field_ptr_index_3,
    agg_field_val,
    set_union_tag,
    get_union_tag,
    slice,
    slice_len,
    slice_ptr,
    ptr_slice_len_ptr,
    ptr_slice_ptr_ptr,
    array_elem_val,
    slice_elem_val,
    slice_elem_ptr,
    ptr_elem_val,
    ptr_elem_ptr,
    array_to_slice,
    array_to_vector,
    int_from_float,
    int_from_float_optimized,
    int_from_float_safe,
    int_from_float_optimized_safe,
    float_from_int,
    reduce,
    reduce_optimized,
    splat,
    shuffle_one,
    shuffle_two,
    select,
    memset,
    memset_safe,
    memcpy,
    memmove,
    cmpxchg_weak,
    cmpxchg_strong,
    atomic_load,
    atomic_store_unordered,
    atomic_store_monotonic,
    atomic_store_release,
    atomic_store_seq_cst,
    atomic_rmw,
    is_named_enum_value,
    tag_name,
    error_name,
    error_set_has_value,
    aggregate_init,
    union_init,
    prefetch,
    mul_add,
    field_parent_ptr,
    wasm_memory_size,
    wasm_memory_grow,
    cmp_lte_errors_len,
    err_return_trace,
    set_err_return_trace,
    addrspace_cast,
    save_err_return_trace_index,
    runtime_nav_ptr,
    c_va_arg,
    c_va_copy,
    c_va_end,
    c_va_start,
    spirv_runtime_array_len,
    work_item_id,
    work_group_size,
    work_group_id,
    legalize_vec_store_elem,
    legalize_vec_elem_val,
    legalize_compiler_rt_call,
};

/// `ty` is `.none` for an instruction the adapter does not decode (counted in `Func.unsupported`).
/// `id` is the AIR instruction index that operands and `target` attributes name. `loc` is the nearest
/// preceding `dbg_stmt`. The instructions of a body are contiguous in `Tables.insts`.
pub const Inst = extern struct {
    id: u32,
    ty: TypeId,
    loc: LocId,
    ops: u32,
    ops_len: u32,
    attrs: u32,
    bodies: u32,
    bodies_len: u16,
    attrs_len: u8,
    tag: Tag,
};

pub const Optimize = enum(u32) { debug, safe, fast, small };

pub const Tables = struct {
    strings: []const u8 = &.{},
    str_index: []const StrEntry = &.{},
    files: []const FileRec = &.{},
    types: []const TypeRec = &.{},
    consts: []const ConstRec = &.{},
    callees: []const StrId = &.{},
    locs: []const LocRec = &.{},
    params: []const Param = &.{},
    callee_refs: []const CalleeRef = &.{},
    funcs: []const Func = &.{},
    insts: []const Inst = &.{},
    operands: []const Operand = &.{},
    attrs: []const Attr = &.{},
    bodies: []const Body = &.{},
};

const table_names = @typeInfo(Tables).@"struct".field_names;
pub const table_count = table_names.len;

fn Elem(comptime name: []const u8) type {
    return @typeInfo(@FieldType(Tables, name)).pointer.child;
}

pub const Span = extern struct { off: u32, len: u32 };

pub const Header = extern struct {
    magic: [8]u8,
    schema: u32,
    optimize: Optimize,
    zig_version: StrId,
    target: StrId,
    root: StrId,
    size: u32,
    spans: [table_count]Span,
};

/// What a pack says about the compilation that made it.
pub const Meta = struct {
    zig_version: StrId,
    target: StrId,
    root: StrId,
    optimize: Optimize,
};

comptime {
    for ([_]type{ StrEntry, FileRec, TypeRec, ConstRec, LocRec, Param, Func, Attr, Body, Inst, Span, Header, Range }) |T| {
        var sum: usize = 0;
        for (@typeInfo(T).@"struct".field_types) |ft| sum += @sizeOf(ft);
        assert(sum == @sizeOf(T));
    }
    assert(@sizeOf(Inst) == 32 and @sizeOf(TypeRec) == 24 and @alignOf(Header) == 4);
}

pub const Pack = struct {
    meta: Meta,
    t: Tables,

    pub const Error = error{ BadMagic, BadSchema, Truncated, Misaligned };

    /// Views `bytes` in place; nothing is copied.
    pub fn parse(bytes: []align(8) const u8) Error!Pack {
        if (bytes.len < @sizeOf(Header)) return error.Truncated;
        const header: *const Header = @ptrCast(bytes.ptr);
        if (!std.mem.eql(u8, &header.magic, &magic)) return error.BadMagic;
        if (header.schema != version) return error.BadSchema;
        if (header.size != bytes.len) return error.Truncated;
        var t: Tables = .{};
        inline for (table_names, header.spans) |name, span| {
            const T = Elem(name);
            const len = @as(usize, span.len) * @sizeOf(T);
            if (span.off % @alignOf(T) != 0) return error.Misaligned;
            if (span.off > bytes.len or len > bytes.len - span.off) return error.Truncated;
            @field(t, name) = @ptrCast(@alignCast(bytes[span.off..][0..len]));
        }
        return .{
            .meta = .{ .zig_version = header.zig_version, .target = header.target, .root = header.root, .optimize = header.optimize },
            .t = t,
        };
    }

    pub fn str(p: Pack, id: StrId) []const u8 {
        const entry = p.t.str_index[@backingInt(id)];
        return p.t.strings[entry.off..][0..entry.len];
    }

    pub fn instsOf(p: Pack, r: Range) []const Inst {
        return p.t.insts[r.off..][0..r.len];
    }

    pub fn operandsOf(p: Pack, inst: Inst) []const Operand {
        return p.t.operands[inst.ops..][0..inst.ops_len];
    }

    pub fn attrsOf(p: Pack, inst: Inst) []const Attr {
        return p.t.attrs[inst.attrs..][0..inst.attrs_len];
    }

    pub fn bodiesOf(p: Pack, inst: Inst) []const Body {
        return p.t.bodies[inst.bodies..][0..inst.bodies_len];
    }

    pub fn paramsOf(p: Pack, f: Func) []const Param {
        return p.t.params[f.params.off..][0..f.params.len];
    }

    pub fn calleeRefsOf(p: Pack, f: Func) []const CalleeRef {
        return p.t.callee_refs[f.callees.off..][0..f.callees.len];
    }

    pub fn typeName(p: Pack, id: TypeId) []const u8 {
        return p.str(p.t.types[@backingInt(id)].name);
    }

    pub fn calleeName(p: Pack, id: CalleeId) []const u8 {
        return p.str(p.t.callees[@backingInt(id)]);
    }

    /// Checks every reference of every record: ids in range, ranges inside their tables, types after
    /// their children, the unsupported counts and the function order. A pack that passes is safe to
    /// walk without further checks.
    pub fn validate(p: Pack) error{Invalid}!void {
        const t = p.t;
        const strs = t.str_index.len;
        for (t.str_index) |e| if (!inside(.{ .off = e.off, .len = e.len }, t.strings.len)) return error.Invalid;
        for (t.files) |f| if (@backingInt(f.module) >= strs or @backingInt(f.path) >= strs) return error.Invalid;
        for (t.types, 0..) |ty, i| {
            if (@backingInt(ty.name) >= strs) return error.Invalid;
            if (ty.child != .none and @backingInt(ty.child) >= i) return error.Invalid;
        }
        for (t.consts) |c| {
            if (c.ty != .none and @backingInt(c.ty) >= t.types.len) return error.Invalid;
            const bad = switch (c.kind) {
                .enum_literal, .enum_tag, .@"error", .text => c.a >= strs,
                .func => c.a >= t.callees.len,
                .type => c.a >= t.types.len,
                .bool => c.a > 1,
                else => false,
            };
            if (bad) return error.Invalid;
        }
        for (t.callees) |c| if (@backingInt(c) >= strs) return error.Invalid;
        for (t.locs) |l| if (@backingInt(l.file) >= t.files.len) return error.Invalid;
        for (t.params) |q| if (@backingInt(q.ty) >= t.types.len) return error.Invalid;
        for (t.callee_refs) |r| if (r.callee >= t.callees.len) return error.Invalid;
        for (t.operands) |o| if (o.kind == .constant and o.value >= t.consts.len) return error.Invalid;
        for (t.attrs) |a| switch (a.key.kind()) {
            .str => if (a.value >= strs) return error.Invalid,
            .callee => if (a.value >= t.callees.len) return error.Invalid,
            .flag => if (a.value > 1) return error.Invalid,
            .int, .inst => {},
        };
        for (t.bodies) |b| {
            const pairs: Range = .{ .off = b.ranges.off, .len = b.ranges.len *| 2 };
            if (!inside(b.items, t.operands.len) or !inside(pairs, t.operands.len) or !inside(b.insts, t.insts.len)) return error.Invalid;
        }
        for (t.insts) |inst| {
            if (inst.ty != .none and @backingInt(inst.ty) >= t.types.len) return error.Invalid;
            if (inst.loc != .none and @backingInt(inst.loc) >= t.locs.len) return error.Invalid;
            if (!inside(.{ .off = inst.ops, .len = inst.ops_len }, t.operands.len)) return error.Invalid;
            if (!inside(.{ .off = inst.attrs, .len = inst.attrs_len }, t.attrs.len)) return error.Invalid;
            if (!inside(.{ .off = inst.bodies, .len = inst.bodies_len }, t.bodies.len)) return error.Invalid;
        }
        var previous: ?Func = null;
        for (t.funcs) |f| {
            if (@backingInt(f.fqn) >= strs or @backingInt(f.file) >= t.files.len) return error.Invalid;
            if (f.ret == .none or @backingInt(f.ret) >= t.types.len) return error.Invalid;
            if (!inside(f.params, t.params.len) or !inside(f.callees, t.callee_refs.len) or !inside(f.insts, t.insts.len)) return error.Invalid;
            if (previous) |q| {
                const order = std.mem.order(u8, p.str(q.fqn), p.str(f.fqn));
                if (order == .gt or (order == .eq and q.id > f.id)) return error.Invalid;
            }
            previous = f;
            var unsupported: u32 = 0;
            for (p.instsOf(f.insts)) |inst| unsupported += p.countUnsupported(inst);
            if (unsupported != f.unsupported) return error.Invalid;
        }
    }

    fn countUnsupported(p: Pack, inst: Inst) u32 {
        var n: u32 = @intFromBool(inst.ty == .none);
        for (p.bodiesOf(inst)) |body| for (p.instsOf(body.insts)) |child| {
            n += p.countUnsupported(child);
        };
        return n;
    }
};

fn inside(r: Range, len: usize) bool {
    return r.off <= len and r.len <= len - r.off;
}

/// Lays `p` out as a pack. The bytes are a function of the tables and meta alone.
pub fn serialize(gpa: Allocator, p: Pack) Allocator.Error![]align(8) u8 {
    var header: Header = .{
        .magic = magic,
        .schema = version,
        .optimize = p.meta.optimize,
        .zig_version = p.meta.zig_version,
        .target = p.meta.target,
        .root = p.meta.root,
        .size = undefined,
        .spans = undefined,
    };
    var size: usize = @sizeOf(Header);
    inline for (table_names, &header.spans) |name, *span| {
        size = std.mem.alignForward(usize, size, 8);
        span.* = .{ .off = @intCast(size), .len = @intCast(@field(p.t, name).len) };
        size += @field(p.t, name).len * @sizeOf(Elem(name));
    }
    size = std.mem.alignForward(usize, size, 8);
    header.size = @intCast(size);
    const out = try gpa.alignedAlloc(u8, .@"8", size);
    @memset(out, 0);
    @memcpy(out[0..@sizeOf(Header)], std.mem.asBytes(&header));
    inline for (table_names, header.spans) |name, span| {
        const bytes = std.mem.sliceAsBytes(@field(p.t, name));
        @memcpy(out[span.off..][0..bytes.len], bytes);
    }
    return out;
}

pub fn contentHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

/// Hides the compiler-internal ids that generated names carry (`foo__anon_1234`, `S__struct_77`):
/// `__word_digits` becomes `__word`.
pub fn scrub(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < name.len) {
        if (std.mem.startsWith(u8, name[i..], "__")) {
            var j = i + 2;
            while (j < name.len and std.ascii.isLower(name[j])) j += 1;
            if (j > i + 2 and j + 1 < name.len and name[j] == '_' and std.ascii.isDigit(name[j + 1])) {
                var k = j + 1;
                while (k < name.len and std.ascii.isDigit(name[k])) k += 1;
                if (k == name.len or !(std.ascii.isAlphanumeric(name[k]) or name[k] == '_')) {
                    try out.appendSlice(arena, name[i..j]);
                    i = k;
                    continue;
                }
            }
        }
        try out.append(arena, name[i]);
        i += 1;
    }
    return out.items;
}

/// One line of an index directory: where one compilation's pack (or JSON file) lives. `path` is
/// absolute, or relative to the index directory.
pub const Entry = struct {
    pub const Format = enum { pack, json };

    format: Format,
    size: u64,
    hash: u64,
    functions: u32,
    path: []const u8,

    pub fn write(e: Entry, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("zvi {d} {t} {d} {x:0>16} {d} {s}\n", .{ version, e.format, e.size, e.hash, e.functions, e.path });
    }

    pub fn parse(line: []const u8) error{BadEntry}!Entry {
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, line, "\r\n"), ' ');
        if (!std.mem.eql(u8, it.next() orelse "", "zvi")) return error.BadEntry;
        if ((std.fmt.parseInt(u32, it.next() orelse "", 10) catch return error.BadEntry) != version) return error.BadEntry;
        const format = std.meta.stringToEnum(Format, it.next() orelse "") orelse return error.BadEntry;
        const size = std.fmt.parseInt(u64, it.next() orelse "", 10) catch return error.BadEntry;
        const hash = std.fmt.parseInt(u64, it.next() orelse "", 16) catch return error.BadEntry;
        const functions = std.fmt.parseInt(u32, it.next() orelse "", 10) catch return error.BadEntry;
        const path = it.rest();
        if (path.len == 0) return error.BadEntry;
        return .{ .format = format, .size = size, .hash = hash, .functions = functions, .path = path };
    }
};

/// A file path with `/` separators, whatever the host's are.
pub fn normalizePath(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const out = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}
