//! Turns the AIR text of an unpatched compiler into schema v1 JSON (docs/phase1.md), out of tree.
//! Input: stderr of `zig test -fno-emit-bin --verbose-air` (0.16, 0.17, compiler built with
//! -Ddebug-extensions) or of `--debug-log illegal-air` (0.18-dev, built with -Dlog=debug).
//! The grammar is strict: any token it does not know is an error naming the line, never a guess.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ast = std.zig.Ast;

const Shape = enum {
    bin_op,
    un_op,
    no_op,
    ty,
    arg,
    ty_op,
    ty_pl_bin,
    block,
    loop,
    dbg_inline_block,
    call,
    dbg_var,
    struct_field,
    asm_,
    dbg_stmt,
    aggregate_init,
    union_init,
    br,
    repeat,
    cond_br,
    try_,
    try_ptr,
    switch_br,
    cmpxchg,
    atomic_load,
    prefetch,
    atomic_store,
    atomic_rmw,
    field_parent_ptr,
    mul_add,
    select,
    reduce,
    cmp_vector,
    runtime_nav_ptr,
    unsupported,
};

const shapes: std.StaticStringMap(Shape) = blk: {
    @setEvalBranchQuota(100_000);
    const groups = .{
        .{ .bin_op, "add add_optimized add_safe add_wrap add_sat sub sub_optimized sub_safe sub_wrap sub_sat mul mul_optimized mul_safe mul_wrap mul_sat div_float div_trunc div_floor div_ceil div_exact rem mod bit_and bit_or xor cmp_lt cmp_lte cmp_eq cmp_gte cmp_gt cmp_neq store store_safe array_elem_val slice_elem_val ptr_elem_val shl shl_exact shl_sat shr shr_exact set_union_tag min max div_float_optimized div_trunc_optimized div_floor_optimized div_ceil_optimized div_exact_optimized rem_optimized mod_optimized cmp_lt_optimized cmp_lte_optimized cmp_eq_optimized cmp_gte_optimized cmp_gt_optimized cmp_neq_optimized memcpy memmove memset memset_safe" },
        .{ .un_op, "is_null is_non_null is_null_ptr is_non_null_ptr is_err is_non_err is_err_ptr is_non_err_ptr ret ret_safe ret_load is_named_enum_value tag_name error_name sqrt sin cos tan exp exp2 log log2 log10 floor ceil round trunc_float neg neg_optimized cmp_lte_errors_len set_err_return_trace c_va_end" },
        .{ .no_op, "trap breakpoint dbg_empty_stmt unreach ret_addr frame_addr save_err_return_trace_index" },
        .{ .ty, "alloc ret_ptr err_return_trace c_va_start" },
        .{ .arg, "arg" },
        .{ .ty_op, "not bit_cast bit_cast_safe ptr_cast ptr_from_int int_from_ptr error_cast error_from_int int_from_error union_from_enum load fptrunc fpext int_cast int_cast_safe trunc optional_payload optional_payload_ptr optional_payload_ptr_set errunion_payload_ptr_set wrap_optional unwrap_errunion_payload unwrap_errunion_err unwrap_errunion_payload_ptr unwrap_errunion_err_ptr wrap_errunion_payload wrap_errunion_err slice_ptr slice_len ptr_slice_len_ptr ptr_slice_ptr_ptr struct_field_ptr_index_0 struct_field_ptr_index_1 struct_field_ptr_index_2 struct_field_ptr_index_3 array_to_slice array_to_vector float_from_int splat int_from_float int_from_float_optimized int_from_float_safe int_from_float_optimized_safe get_union_tag clz ctz popcount byte_swap bit_reverse abs error_set_has_value addrspace_cast c_va_arg c_va_copy" },
        .{ .block, "block" },
        .{ .loop, "loop" },
        .{ .ty_pl_bin, "slice slice_elem_ptr ptr_elem_ptr ptr_add ptr_sub add_with_overflow sub_with_overflow mul_with_overflow shl_with_overflow" },
        .{ .call, "call call_always_tail call_never_tail call_never_inline" },
        .{ .dbg_var, "dbg_var_ptr dbg_var_val dbg_arg_inline" },
        .{ .struct_field, "struct_field_ptr agg_field_val spirv_runtime_array_len" },
        .{ .asm_, "assembly" },
        .{ .dbg_stmt, "dbg_stmt" },
        .{ .aggregate_init, "aggregate_init" },
        .{ .union_init, "union_init" },
        .{ .br, "br switch_dispatch" },
        .{ .repeat, "repeat" },
        .{ .cond_br, "cond_br" },
        .{ .try_, "try try_cold" },
        .{ .try_ptr, "try_ptr try_ptr_cold" },
        .{ .switch_br, "loop_switch_br switch_br" },
        .{ .cmpxchg, "cmpxchg_weak cmpxchg_strong" },
        .{ .atomic_load, "atomic_load" },
        .{ .prefetch, "prefetch" },
        .{ .atomic_store, "atomic_store_unordered atomic_store_monotonic atomic_store_release atomic_store_seq_cst" },
        .{ .atomic_rmw, "atomic_rmw" },
        .{ .field_parent_ptr, "field_parent_ptr" },
        .{ .unsupported, "wasm_memory_size wasm_memory_grow shuffle_one shuffle_two legalize_vec_store_elem legalize_compiler_rt_call work_item_id work_group_size work_group_id inferred_alloc inferred_alloc_comptime legalize_vec_elem_val" },
        .{ .mul_add, "mul_add" },
        .{ .select, "select" },
        .{ .reduce, "reduce reduce_optimized" },
        .{ .cmp_vector, "cmp_vector cmp_vector_optimized" },
        .{ .runtime_nav_ptr, "runtime_nav_ptr" },
        .{ .dbg_inline_block, "dbg_inline_block" },
    };
    var n: usize = 0;
    for (groups) |g| {
        var it = std.mem.tokenizeScalar(u8, g[1], ' ');
        while (it.next()) |_| n += 1;
    }
    var kvs: [n]struct { []const u8, Shape } = undefined;
    var i: usize = 0;
    for (groups) |g| {
        var it = std.mem.tokenizeScalar(u8, g[1], ' ');
        while (it.next()) |name| : (i += 1) kvs[i] = .{ name, g[0] };
    }
    break :blk .initComptime(kvs);
};

/// Tags 0.16 spelled differently; the rest of the program only knows the 0.17 spelling.
const renames_016: std.StaticStringMap([]const u8) = .initComptime(.{
    .{ "bitcast", "bit_cast" },
    .{ "bitcast_safe", "bit_cast_safe" },
    .{ "intcast", "int_cast" },
    .{ "intcast_safe", "int_cast_safe" },
    .{ "bool_and", "bit_and" },
    .{ "bool_or", "bit_or" },
    .{ "struct_field_val", "agg_field_val" },
});

const Error = error{ BadLine, BadOperand, UnknownTag, UnknownStaticRef, Unbalanced, BadCloser } || Allocator.Error;

const Operand = union(enum) {
    none,
    inst: u32,
    constant: struct { ty: []const u8, val: []const u8 },
};

const Attr = struct {
    key: []const u8,
    value: union(enum) { int: u64, str: []const u8, flag: bool, inst: u32 },
};

const Loc = struct { file: u32, line: u32, col: u32 };

const RawBody = struct {
    label: []const u8,
    items: []const Operand = &.{},
    ranges: []const [2]Operand = &.{},
    insts: []const RawInst = &.{},
};

const RawInst = struct {
    id: u32,
    tag: []const u8,
    shape: Shape,
    /// Result type as printed or inferred from the text; null when the text does not say.
    ty: ?[]const u8 = null,
    operands: []const Operand = &.{},
    attrs: []const Attr = &.{},
    /// Short callee name from `(function 'name')`, for calls and inline blocks.
    callee: ?[]const u8 = null,
    bodies: []const RawBody = &.{},
};

const Out = struct {
    const Inst = struct {
        id: u32,
        tag: []const u8,
        supported: bool = true,
        ty: ?u32 = null,
        operands: []const Operand2 = &.{},
        attrs: []const Attr = &.{},
        loc: ?Loc = null,
        bodies: []const Body = &.{},
    };
    const Operand2 = union(enum) { none, inst: u32, constant: struct { ty: u32, val: []const u8 } };
    const Body = struct {
        label: []const u8,
        items: []const Operand2 = &.{},
        ranges: []const [2]Operand2 = &.{},
        insts: []const Inst,
    };
    const Param = struct { ty: u32, zir_index: u32 };
    const SourceFile = struct { module: []const u8, path: []const u8 };
    const TypeEntry = struct { name: []const u8, kind: []const u8 };
    const Callee = struct { fqn: []const u8, inlined: bool };
    const Function = struct {
        fqn: []const u8,
        file: u32,
        line: u32,
        generic_instance: bool,
        params: []const Param,
        ret: ?u32,
        files: []const SourceFile,
        types: []const TypeEntry,
        insts: []const Inst,
        callees: []const Callee,
        unsupported: u32,
    };
};

/// What the run could not take from the text. Printed to stderr; the numbers are the tripwire.
const Stats = struct {
    functions: u32 = 0,
    skipped: u32 = 0,
    insts: u32 = 0,
    unsupported: u32 = 0,
    unknown_ty: u32 = 0,
    callee_unresolved: u32 = 0,
    callee_ambiguous: u32 = 0,
    decl_unresolved: u32 = 0,
    kind_unknown: u32 = 0,
    failed: u32 = 0,
};

// ---------------------------------------------------------------- text scanning

fn isOpen(c: u8) bool {
    return c == '(' or c == '[' or c == '{';
}

fn closerOf(c: u8) u8 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '<' => '>',
        else => unreachable,
    };
}

/// Walks `s` once and calls `visit(index)` for each byte outside brackets and strings. `<` opens a
/// bracket only where an operand starts (after a comma, `[` or `(`), because only constants `<ty, val>`
/// use it; elsewhere it is a plain byte. Returns the bracket depth left at the end.
fn scanTop(s: []const u8, ctx: anytype, comptime visit: fn (@TypeOf(ctx), usize) bool) Error!usize {
    var stack: [64]u8 = undefined;
    var depth: usize = 0;
    var in_str = false;
    var prev: u8 = ',';
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        defer if (c != ' ') {
            prev = c;
        };
        if (in_str) {
            if (c == '\\') i += 1 else if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') {
            in_str = true;
            continue;
        }
        if (isOpen(c) or (c == '<' and (prev == ',' or prev == '[' or prev == '(' or prev == '.'))) {
            if (depth == stack.len) return error.Unbalanced;
            stack[depth] = closerOf(c);
            depth += 1;
            continue;
        }
        if (depth > 0 and c == stack[depth - 1]) {
            depth -= 1;
            continue;
        }
        if (depth == 0 and !visit(ctx, i)) return depth;
    }
    return depth;
}

const Splitter = struct {
    s: []const u8,
    sep: u8,
    cuts: *std.ArrayList(usize),
    arena: Allocator,
    failed: bool = false,

    fn visit(self: *Splitter, i: usize) bool {
        if (self.s[i] == self.sep) self.cuts.append(self.arena, i) catch {
            self.failed = true;
            return false;
        };
        return true;
    }
};

/// Splits at top-level `sep`, trimming each piece. An empty input gives no pieces.
fn splitTop(arena: Allocator, s: []const u8, sep: u8) Error![]const []const u8 {
    const text = std.mem.trim(u8, s, " ");
    if (text.len == 0) return &.{};
    var cuts: std.ArrayList(usize) = .empty;
    var sp: Splitter = .{ .s = text, .sep = sep, .cuts = &cuts, .arena = arena };
    const left = try scanTop(text, &sp, Splitter.visit);
    if (sp.failed) return error.OutOfMemory;
    if (left != 0) return error.Unbalanced;
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    for (cuts.items) |cut| {
        try out.append(arena, std.mem.trim(u8, text[start..cut], " "));
        start = cut + 1;
    }
    try out.append(arena, std.mem.trim(u8, text[start..], " "));
    return out.items;
}

const Finder = struct {
    s: []const u8,
    needle: u8,
    found: ?usize = null,

    fn visit(self: *Finder, i: usize) bool {
        if (self.s[i] != self.needle) return true;
        self.found = i;
        return false;
    }
};

fn findTop(s: []const u8, needle: u8) ?usize {
    var f: Finder = .{ .s = s, .needle = needle };
    _ = scanTop(s, &f, Finder.visit) catch return null;
    return f.found;
}

fn unbalanced(s: []const u8) bool {
    const Nop = struct {
        fn visit(_: void, _: usize) bool {
            return true;
        }
    };
    const left = scanTop(s, {}, Nop.visit) catch return true;
    return left != 0;
}

fn stringLiteral(arena: Allocator, token: []const u8) Error![]const u8 {
    if (token.len < 2 or token[0] != '"' or token[token.len - 1] != '"') return error.BadOperand;
    return std.zig.string_literal.parseAlloc(arena, token) catch error.BadOperand;
}

// ---------------------------------------------------------------- type text

fn stripQualifiers(t: []const u8) []const u8 {
    var s = t;
    outer: while (true) {
        inline for (.{ "const ", "volatile ", "allowzero " }) |q| if (std.mem.startsWith(u8, s, q)) {
            s = s[q.len..];
            continue :outer;
        };
        inline for (.{ "align(", "addrspace(" }) |q| if (std.mem.startsWith(u8, s, q)) {
            const close = findClose(s, q.len - 1) orelse return s;
            s = std.mem.trimStart(u8, s[close + 1 ..], " ");
            continue :outer;
        };
        return s;
    }
}

/// Index of the bracket matching the one at `open`.
fn findClose(s: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    for (s[open..], open..) |c, i| {
        if (isOpen(c)) depth += 1;
        if (c == ')' or c == ']' or c == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Element, pointee or payload type of a pointer, slice, array, optional or vector type.
fn childOf(t: []const u8) ?[]const u8 {
    if (t.len == 0) return null;
    switch (t[0]) {
        '*' => return stripQualifiers(t[1..]),
        '?' => return t[1..],
        '[' => {
            const close = findClose(t, 0) orelse return null;
            return stripQualifiers(t[close + 1 ..]);
        },
        '@' => {
            if (!std.mem.startsWith(u8, t, "@Vector(")) return null;
            const inner = t["@Vector(".len .. t.len - 1];
            const comma = findTop(inner, ',') orelse return null;
            return std.mem.trim(u8, inner[comma + 1 ..], " ");
        },
        else => return null,
    }
}

fn payloadOf(t: []const u8) ?[]const u8 {
    const bang = findTop(t, '!') orelse return null;
    return t[bang + 1 ..];
}

fn stripFnPrefix(t: []const u8) []const u8 {
    inline for (.{ "noinline ", "inline " }) |q| if (std.mem.startsWith(u8, t, q)) return t[q.len..];
    return t;
}

fn returnOf(t: []const u8) ?[]const u8 {
    var s = t;
    if (s.len > 0 and s[0] == '*') s = stripQualifiers(s[1..]);
    s = stripFnPrefix(s);
    if (!std.mem.startsWith(u8, s, "fn (")) return null;
    const close = findClose(s, 3) orelse return null;
    var rest = std.mem.trimStart(u8, s[close + 1 ..], " ");
    outer: while (true) {
        inline for (.{ "callconv(", "align(", "addrspace(" }) |q| if (std.mem.startsWith(u8, rest, q)) {
            const c = findClose(rest, q.len - 1) orelse return null;
            rest = std.mem.trimStart(u8, rest[c + 1 ..], " ");
            continue :outer;
        };
        return rest;
    }
}

// ---------------------------------------------------------------- source index

/// The text has no file names and no declaration lines, so both come from parsing the sources.
const SourceIndex = struct {
    const Decl = struct { line: u32, kind: []const u8 };
    /// Full fqn (module prefix included) to the declaration.
    decls: std.StringHashMapUnmanaged(Decl) = .empty,
    modules: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn addModule(index: *SourceIndex, arena: Allocator, io: Io, module: []const u8, path: []const u8) !void {
        const bytes = try Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(16 << 20), .of(u8), 0);
        const tree = try Ast.parse(arena, bytes, .{ .mode = .zig });
        try index.modules.put(arena, module, std.fs.path.basename(path));
        try index.walk(arena, &tree, tree.rootDecls(), module);
    }

    fn walk(index: *SourceIndex, arena: Allocator, tree: *const Ast, members: []const Ast.Node.Index, prefix: []const u8) Allocator.Error!void {
        for (members) |node| switch (tree.nodeTag(node)) {
            .fn_decl => {
                var buf: [1]Ast.Node.Index = undefined;
                const proto = tree.nodeData(node).node_and_node[0];
                const full = tree.fullFnProto(&buf, proto) orelse continue;
                const name = tree.tokenSlice(full.name_token orelse continue);
                const key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, name });
                try index.decls.put(arena, key, .{ .line = lineOf(tree, node), .kind = "fn" });
            },
            .test_decl => {
                const name_token = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse continue;
                const raw = tree.tokenSlice(name_token);
                const name = if (raw.len > 0 and raw[0] == '"') raw[1 .. raw.len - 1] else raw;
                const key = try std.fmt.allocPrint(arena, "{s}.test.{s}", .{ prefix, name });
                try index.decls.put(arena, key, .{ .line = lineOf(tree, node), .kind = "fn" });
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const full = tree.fullVarDecl(node) orelse continue;
                const init = full.ast.init_node.unwrap() orelse continue;
                var buf: [2]Ast.Node.Index = undefined;
                const container = tree.fullContainerDecl(&buf, init) orelse continue;
                const name = tree.tokenSlice(full.ast.mut_token + 1);
                const key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, name });
                const kind: []const u8 = switch (tree.tokenTag(container.ast.main_token)) {
                    .keyword_struct => "struct",
                    .keyword_union => "union",
                    .keyword_enum => "enum",
                    .keyword_opaque => "opaque",
                    else => "struct",
                };
                try index.decls.put(arena, key, .{ .line = lineOf(tree, node), .kind = kind });
                try index.walk(arena, tree, container.ast.members, key);
            },
            else => {},
        };
    }

    fn lineOf(tree: *const Ast, node: Ast.Node.Index) u32 {
        return @intCast(tree.tokenLocation(0, tree.firstToken(node)).line + 1);
    }

    /// Generic instances append `__func_N`, `__struct_N` and so on to the declaration name.
    fn lookup(index: *const SourceIndex, fqn: []const u8) ?Decl {
        return index.decls.get(stripInstance(fqn));
    }

    fn moduleOf(index: *const SourceIndex, fqn: []const u8) ?[]const u8 {
        const dot = std.mem.indexOfScalar(u8, fqn, '.') orelse fqn.len;
        return if (index.modules.contains(fqn[0..dot])) fqn[0..dot] else null;
    }
};

/// Position of the `__func_830` style suffix generic instances carry, if the name has one.
fn instanceSuffix(fqn: []const u8) ?usize {
    const at = std.mem.lastIndexOf(u8, fqn, "__") orelse return null;
    const tail = fqn[at + 2 ..];
    const us = std.mem.indexOfScalar(u8, tail, '_') orelse return null;
    inline for (.{ "anon", "func", "enum", "struct", "union", "opaque" }) |kind| {
        if (std.mem.eql(u8, tail[0..us], kind)) {
            _ = std.fmt.parseUnsigned(u32, tail[us + 1 ..], 10) catch return null;
            return at;
        }
    }
    return null;
}

fn stripInstance(fqn: []const u8) []const u8 {
    return fqn[0 .. instanceSuffix(fqn) orelse fqn.len];
}

fn lastSegment(fqn: []const u8) []const u8 {
    var depth: usize = 0;
    var i = fqn.len;
    while (i > 0) {
        i -= 1;
        switch (fqn[i]) {
            ')', ']', '}' => depth += 1,
            '(', '[', '{' => depth -|= 1,
            '.' => if (depth == 0) return fqn[i + 1 ..],
            else => {},
        }
    }
    return fqn;
}

fn parentOf(fqn: []const u8) []const u8 {
    const last = lastSegment(fqn);
    return std.mem.trimEnd(u8, fqn[0 .. fqn.len - last.len], ".");
}

// ---------------------------------------------------------------- static refs

/// `@.name` operands are InternPool static indices; the printer shows only the name.
fn staticRef(name: []const u8) Error!Operand {
    const fixed = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "void_value", "void", "{}" },
        .{ "bool_true", "bool", "true" },
        .{ "bool_false", "bool", "false" },
        .{ "empty_tuple", "@TypeOf(.{})", ".{}" },
        .{ "one", "comptime_int", "1" },
        .{ "zero", "comptime_int", "0" },
        .{ "unreachable_value", "noreturn", "unreachable" },
    };
    for (fixed) |f| if (std.mem.eql(u8, f[0], name)) return .{ .constant = .{ .ty = f[1], .val = f[2] } };
    const prefixes = [_]struct { []const u8, []const u8 }{
        .{ "zero_", "0" }, .{ "one_", "1" }, .{ "four_", "4" }, .{ "undef_", "undefined" },
    };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p[0])) {
        const ty = name[p[0].len..];
        if (isIntName(ty)) return .{ .constant = .{ .ty = ty, .val = p[1] } };
    };
    return error.UnknownStaticRef;
}

fn isIntName(t: []const u8) bool {
    if (std.mem.eql(u8, t, "usize") or std.mem.eql(u8, t, "isize")) return true;
    if (t.len < 2 or (t[0] != 'u' and t[0] != 'i')) return false;
    _ = std.fmt.parseUnsigned(u16, t[1..], 10) catch return false;
    return true;
}

fn parseOperand(token: []const u8) Error!Operand {
    if (token.len == 0) return error.BadOperand;
    switch (token[0]) {
        '%' => {
            const digits = std.mem.trimEnd(u8, token[1..], "!");
            return .{ .inst = std.fmt.parseUnsigned(u32, digits, 10) catch return error.BadOperand };
        },
        '@' => {
            if (token.len < 3 or token[1] != '.') return error.BadOperand;
            return staticRef(token[2..]);
        },
        '<' => {
            if (token[token.len - 1] != '>') return error.BadOperand;
            const inner = token[1 .. token.len - 1];
            const comma = findTop(inner, ',') orelse return error.BadOperand;
            return .{ .constant = .{
                .ty = std.mem.trim(u8, inner[0..comma], " "),
                .val = std.mem.trim(u8, inner[comma + 1 ..], " "),
            } };
        },
        else => return error.BadOperand,
    }
}

// ---------------------------------------------------------------- parsing

const Segment = struct { head: []const u8, insts: []const RawInst };

const Parser = struct {
    arena: Allocator,
    lines: []const []const u8,
    pos: usize = 0,
    tys: std.AutoHashMapUnmanaged(u32, ?[]const u8) = .empty,
    legacy_tags: bool,
    /// Line number in the dump of the first line, for error messages.
    first_line: usize,

    fn fail(p: *Parser, err: Error) Error {
        const at = if (p.pos > 0) p.pos - 1 else 0;
        std.debug.print("error: {t} at dump line {d}: {s}\n", .{ err, p.first_line + at, if (at < p.lines.len) p.lines[at] else "" });
        return err;
    }

    fn atCloser(p: *Parser) bool {
        const line = std.mem.trimStart(u8, p.lines[p.pos], " ");
        return line.len > 0 and line[0] == '}';
    }

    /// A line like `%26! %1! %25!` lists operands that die; it carries no instruction.
    fn isDeathLine(line: []const u8) bool {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        while (it.next()) |tok| {
            if (tok.len < 3 or tok[0] != '%' or tok[tok.len - 1] != '!') return false;
        }
        return true;
    }

    fn parseInsts(p: *Parser, nested: bool) Error![]const RawInst {
        var out: std.ArrayList(RawInst) = .empty;
        while (p.pos < p.lines.len) {
            if (nested and p.atCloser()) break;
            if (isDeathLine(p.lines[p.pos])) {
                p.pos += 1;
                continue;
            }
            try out.append(p.arena, try p.parseInst());
        }
        return out.items;
    }

    fn parseInst(p: *Parser) Error!RawInst {
        const line = std.mem.trimStart(u8, p.lines[p.pos], " ");
        p.pos += 1;
        if (line.len < 4 or line[0] != '%') return p.fail(error.BadLine);
        var i: usize = 1;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        const id = std.fmt.parseUnsigned(u32, line[1..i], 10) catch return p.fail(error.BadLine);
        while (i < line.len and (line[i] == '!' or line[i] == ' ')) i += 1;
        if (!std.mem.startsWith(u8, line[i..], "= ")) return p.fail(error.BadLine);
        i += 2;
        const open = std.mem.indexOfScalarPos(u8, line, i, '(') orelse return p.fail(error.BadLine);
        const raw_tag = line[i..open];
        const tag = if (p.legacy_tags) renames_016.get(raw_tag) orelse raw_tag else raw_tag;
        const shape = shapes.get(tag) orelse return p.fail(error.UnknownTag);
        const rest = line[open + 1 ..];

        const multi = std.mem.endsWith(u8, rest, "{") and unbalanced(rest);
        var segments: std.ArrayList(Segment) = .empty;
        var head: []const u8 = undefined;
        if (!multi) {
            if (rest.len == 0 or rest[rest.len - 1] != ')') return p.fail(error.BadLine);
            head = rest[0 .. rest.len - 1];
        } else {
            head = std.mem.trimEnd(u8, rest[0 .. rest.len - 1], " ,");
            while (true) {
                const insts = try p.parseInsts(true);
                try segments.append(p.arena, .{ .head = head, .insts = insts });
                if (p.pos >= p.lines.len) return p.fail(error.BadCloser);
                const closer = std.mem.trimStart(u8, p.lines[p.pos], " ");
                p.pos += 1;
                const after = std.mem.trim(u8, closer[1..], " ");
                if (after.len > 0 and after[0] == ',') {
                    const next = std.mem.trim(u8, after[1..], " ");
                    if (!std.mem.endsWith(u8, next, "{")) return p.fail(error.BadCloser);
                    head = std.mem.trimEnd(u8, next[0 .. next.len - 1], " ,");
                    continue;
                }
                if (std.mem.indexOfScalar(u8, after, ')') == null) {
                    if (p.pos >= p.lines.len or !std.mem.eql(u8, std.mem.trim(u8, p.lines[p.pos], " "), ")")) return p.fail(error.BadCloser);
                    p.pos += 1;
                }
                break;
            }
        }
        const inst = p.build(id, tag, shape, if (multi) segments.items[0].head else head, segments.items) catch |err| {
            std.debug.print("error: {t} in `{s}` (head `{s}`)\n", .{ err, tag, head });
            return err;
        };
        try p.tys.put(p.arena, id, inst.ty);
        return inst;
    }

    fn opType(p: *Parser, op: Operand) ?[]const u8 {
        return switch (op) {
            .none => null,
            .constant => |c| c.ty,
            .inst => |id| p.tys.get(id) orelse null,
        };
    }

    fn operands(p: *Parser, tokens: []const []const u8) Error![]const Operand {
        const out = try p.arena.alloc(Operand, tokens.len);
        for (tokens, out) |tok, *slot| slot.* = try parseOperand(tok);
        return out;
    }

    fn calleeName(op: Operand) ?[]const u8 {
        const c = switch (op) {
            .constant => |c| c,
            else => return null,
        };
        const prefix = "(function '";
        if (!std.mem.startsWith(u8, c.val, prefix) or !std.mem.endsWith(u8, c.val, "')")) return null;
        return c.val[prefix.len .. c.val.len - 2];
    }

    fn intToken(tok: []const u8) Error!u64 {
        return std.fmt.parseUnsigned(u64, tok, 10) catch error.BadOperand;
    }

    fn attrs(p: *Parser, list: []const Attr) Error![]const Attr {
        return p.arena.dupe(Attr, list);
    }

    fn bodies(p: *Parser, list: []const RawBody) Error![]const RawBody {
        return p.arena.dupe(RawBody, list);
    }

    fn build(p: *Parser, id: u32, tag: []const u8, shape: Shape, head: []const u8, segs: []const Segment) Error!RawInst {
        const a = p.arena;
        const t = try splitTop(a, head, ',');
        var inst: RawInst = .{ .id = id, .tag = tag, .shape = shape };
        const eql = std.mem.eql;
        switch (shape) {
            .bin_op => {
                if (t.len != 2) return error.BadLine;
                inst.operands = try p.operands(t);
                inst.ty = p.binOpType(tag, inst.operands);
            },
            .un_op => {
                if (t.len != 1) return error.BadLine;
                inst.operands = try p.operands(t);
                inst.ty = p.unOpType(tag, inst.operands[0]);
            },
            .no_op => {
                if (t.len != 0) return error.BadLine;
                inst.ty = if (eql(u8, tag, "trap") or eql(u8, tag, "unreach")) "noreturn" else if (eql(u8, tag, "breakpoint") or eql(u8, tag, "dbg_empty_stmt")) "void" else "usize";
            },
            .ty => {
                if (t.len != 1) return error.BadLine;
                inst.ty = t[0];
            },
            .arg => {
                if (t.len != 2) return error.BadLine;
                inst.ty = t[0];
                inst.attrs = try p.attrs(&.{.{ .key = "index", .value = .{ .int = try intToken(t[1]) } }});
            },
            .ty_op => {
                if (t.len != 2) return error.BadLine;
                inst.ty = t[0];
                inst.operands = try p.operands(t[1..]);
            },
            .ty_pl_bin => {
                if (t.len != 3) return error.BadLine;
                inst.ty = t[0];
                inst.operands = try p.operands(t[1..]);
            },
            .block, .loop => {
                if (t.len != 1 or segs.len != 1) return error.BadLine;
                inst.ty = t[0];
                inst.bodies = try p.bodies(&.{.{ .label = if (shape == .block) "block" else "loop", .insts = segs[0].insts }});
            },
            .dbg_inline_block => {
                if (t.len != 2 or segs.len != 1) return error.BadLine;
                inst.ty = t[0];
                inst.callee = calleeName(try parseOperand(t[1])) orelse return error.BadOperand;
                inst.bodies = try p.bodies(&.{.{ .label = "inline", .insts = segs[0].insts }});
            },
            .call => {
                if (t.len != 2 or t[1].len < 2 or t[1][0] != '[') return error.BadLine;
                const args = try splitTop(a, t[1][1 .. t[1].len - 1], ',');
                const all = try a.alloc([]const u8, 1 + args.len);
                all[0] = t[0];
                @memcpy(all[1..], args);
                inst.operands = try p.operands(all);
                inst.callee = calleeName(inst.operands[0]);
                inst.ty = if (p.opType(inst.operands[0])) |ft| returnOf(ft) else null;
            },
            .dbg_var => {
                if (t.len != 2) return error.BadLine;
                inst.operands = try p.operands(t[0..1]);
                inst.attrs = try p.attrs(&.{.{ .key = "name", .value = .{ .str = try stringLiteral(a, t[1]) } }});
                inst.ty = "void";
            },
            .struct_field => {
                if (t.len != 2) return error.BadLine;
                inst.operands = try p.operands(t[0..1]);
                inst.attrs = try p.attrs(&.{.{ .key = "field", .value = .{ .int = try intToken(t[1]) } }});
            },
            .dbg_stmt => {
                if (t.len != 1) return error.BadLine;
                const colon = std.mem.indexOfScalar(u8, t[0], ':') orelse return error.BadLine;
                inst.attrs = try p.attrs(&.{
                    .{ .key = "line", .value = .{ .int = try intToken(t[0][0..colon]) } },
                    .{ .key = "col", .value = .{ .int = try intToken(t[0][colon + 1 ..]) } },
                });
                inst.ty = "void";
            },
            .aggregate_init => {
                if (t.len != 2 or t[1].len < 2 or t[1][0] != '[') return error.BadLine;
                inst.ty = t[0];
                inst.operands = try p.operands(try splitTop(a, t[1][1 .. t[1].len - 1], ','));
            },
            .union_init => {
                if (t.len != 2) return error.BadLine;
                inst.operands = try p.operands(t[1..]);
                inst.attrs = try p.attrs(&.{.{ .key = "field", .value = .{ .int = try intToken(t[0]) } }});
            },
            .br => {
                if (t.len != 2) return error.BadLine;
                const target = try parseOperand(t[0]);
                inst.operands = try p.operands(t[1..]);
                inst.attrs = try p.attrs(&.{.{ .key = "target", .value = .{ .inst = target.inst } }});
                inst.ty = "noreturn";
            },
            .repeat => {
                if (t.len != 1) return error.BadLine;
                const target = try parseOperand(t[0]);
                inst.attrs = try p.attrs(&.{.{ .key = "target", .value = .{ .inst = target.inst } }});
                inst.ty = "noreturn";
            },
            .cond_br => {
                if (t.len < 1 or segs.len != 2) return error.BadLine;
                inst.operands = try p.operands(t[0..1]);
                inst.bodies = try p.bodies(&.{ .{ .label = "then", .insts = segs[0].insts }, .{ .label = "else", .insts = segs[1].insts } });
                inst.ty = "noreturn";
            },
            .try_, .try_ptr => {
                if (t.len < 1 or segs.len != 1) return error.BadLine;
                inst.operands = try p.operands(t[0..1]);
                inst.bodies = try p.bodies(&.{.{ .label = "error", .insts = segs[0].insts }});
                inst.ty = if (shape == .try_ptr)
                    (if (t.len == 2) t[1] else null)
                else if (p.opType(inst.operands[0])) |et|
                    payloadOf(et)
                else
                    null;
            },
            .switch_br => try p.buildSwitch(&inst, segs),
            .cmpxchg => {
                if (t.len != 5) return error.BadLine;
                inst.operands = try p.operands(t[0..3]);
                inst.attrs = try p.attrs(&.{
                    .{ .key = "success", .value = .{ .str = t[3] } },
                    .{ .key = "failure", .value = .{ .str = t[4] } },
                });
                if (p.opType(inst.operands[0])) |pt| if (childOf(pt)) |c| {
                    inst.ty = try std.fmt.allocPrint(a, "?{s}", .{c});
                };
            },
            .atomic_load => {
                if (t.len != 2) return error.BadLine;
                inst.operands = try p.operands(t[0..1]);
                inst.attrs = try p.attrs(&.{.{ .key = "order", .value = .{ .str = t[1] } }});
                inst.ty = if (p.opType(inst.operands[0])) |pt| childOf(pt) else null;
            },
            .atomic_store => {
                if (t.len != 3) return error.BadLine;
                inst.operands = try p.operands(t[0..2]);
                inst.attrs = try p.attrs(&.{.{ .key = "order", .value = .{ .str = tag["atomic_store_".len..] } }});
                inst.ty = "void";
            },
            .atomic_rmw => {
                if (t.len != 4) return error.BadLine;
                inst.operands = try p.operands(t[0..2]);
                inst.attrs = try p.attrs(&.{
                    .{ .key = "op", .value = .{ .str = t[2] } },
                    .{ .key = "order", .value = .{ .str = t[3] } },
                });
                inst.ty = if (p.opType(inst.operands[0])) |pt| childOf(pt) else null;
            },
            .field_parent_ptr => {
                if (t.len != 2) return error.BadLine;
                inst.operands = try p.operands(t[0..1]);
                inst.attrs = try p.attrs(&.{.{ .key = "field", .value = .{ .int = try intToken(t[1]) } }});
            },
            .mul_add => {
                if (t.len != 3) return error.BadLine;
                inst.operands = try p.operands(&.{ t[2], t[0], t[1] });
                inst.ty = p.opType(inst.operands[0]);
            },
            .select => {
                if (t.len != 4) return error.BadLine;
                inst.operands = try p.operands(t[1..]);
            },
            .reduce => {
                if (t.len != 2) return error.BadLine;
                inst.operands = try p.operands(t[0..1]);
                inst.attrs = try p.attrs(&.{.{ .key = "operation", .value = .{ .str = t[1] } }});
                inst.ty = if (p.opType(inst.operands[0])) |vt| childOf(vt) else null;
            },
            .cmp_vector => {
                if (t.len != 3) return error.BadLine;
                inst.operands = try p.operands(t[1..]);
                inst.attrs = try p.attrs(&.{.{ .key = "op", .value = .{ .str = t[0] } }});
            },
            .prefetch => {
                if (t.len != 4) return error.BadLine;
                inst.operands = try p.operands(t[0..1]);
                inst.attrs = try p.attrs(&.{.{ .key = "locality", .value = .{ .int = try intToken(t[2]) } }});
                inst.ty = "void";
            },
            .runtime_nav_ptr => {
                if (t.len != 2 or t[1].len < 2) return error.BadLine;
                inst.ty = t[0];
                inst.attrs = try p.attrs(&.{.{ .key = "nav", .value = .{ .str = t[1][1 .. t[1].len - 1] } }});
            },
            .asm_, .unsupported => {},
        }
        return inst;
    }

    fn buildSwitch(p: *Parser, inst: *RawInst, segs: []const Segment) Error!void {
        const a = p.arena;
        if (segs.len == 0) return error.BadLine;
        const first = std.mem.trim(u8, segs[0].head, " ");
        const comma = findTop(first, ',') orelse return error.BadLine;
        inst.operands = try p.operands(&.{first[0..comma]});
        inst.ty = "noreturn";
        var list: std.ArrayList(RawBody) = .empty;
        var has_else = false;
        for (segs, 0..) |seg, n| {
            var h = std.mem.trim(u8, seg.head, " ");
            if (n == 0) h = std.mem.trim(u8, h[comma + 1 ..], " ");
            if (std.mem.startsWith(u8, h, "else")) {
                has_else = true;
                try list.append(a, .{ .label = "else", .insts = seg.insts });
                continue;
            }
            if (h.len == 0 or h[0] != '[') return error.BadLine;
            const close = findClose(h, 0) orelse return error.Unbalanced;
            var items: std.ArrayList(Operand) = .empty;
            var ranges: std.ArrayList([2]Operand) = .empty;
            for (try splitTop(a, h[1..close], ',')) |tok| {
                if (findRange(tok)) |dots| {
                    try ranges.append(a, .{ try parseOperand(tok[0..dots]), try parseOperand(tok[dots + 3 ..]) });
                } else try items.append(a, try parseOperand(tok));
            }
            try list.append(a, .{ .label = "case", .items = items.items, .ranges = ranges.items, .insts = seg.insts });
        }
        if (!has_else) try list.append(a, .{ .label = "else", .insts = &.{} });
        inst.bodies = list.items;
    }

    /// Top-level `...` of a range item such as `@.one_u8...<u8, 9>`.
    fn findRange(tok: []const u8) ?usize {
        var depth: usize = 0;
        var i: usize = 0;
        while (i + 2 < tok.len) : (i += 1) {
            switch (tok[i]) {
                '<', '(', '[', '{' => depth += 1,
                '>', ')', ']', '}' => depth -|= 1,
                '.' => if (depth == 0 and tok[i + 1] == '.' and tok[i + 2] == '.') return i,
                else => {},
            }
        }
        return null;
    }

    fn binOpType(p: *Parser, tag: []const u8, ops: []const Operand) ?[]const u8 {
        const starts = std.mem.startsWith;
        if (starts(u8, tag, "cmp_")) return "bool";
        if (starts(u8, tag, "store") or starts(u8, tag, "mem") or std.mem.eql(u8, tag, "set_union_tag")) return "void";
        if (std.mem.eql(u8, tag, "array_elem_val") or std.mem.eql(u8, tag, "slice_elem_val") or std.mem.eql(u8, tag, "ptr_elem_val"))
            return if (p.opType(ops[0])) |t| childOf(t) else null;
        return p.opType(ops[0]);
    }

    fn unOpType(p: *Parser, tag: []const u8, op: Operand) ?[]const u8 {
        const eql = std.mem.eql;
        if (std.mem.startsWith(u8, tag, "is_") or eql(u8, tag, "cmp_lte_errors_len")) return "bool";
        if (std.mem.startsWith(u8, tag, "ret")) return "noreturn";
        if (eql(u8, tag, "tag_name") or eql(u8, tag, "error_name")) return "[:0]const u8";
        if (eql(u8, tag, "set_err_return_trace") or eql(u8, tag, "c_va_end")) return "void";
        return p.opType(op);
    }
};

// ---------------------------------------------------------------- dump splitting

const Dump = struct {
    const Function = struct { fqn: []const u8, lines: []const []const u8, first_line: usize };
    functions: []const Function,
};

/// `# Begin Function AIR: fqn:` ... `# End Function AIR: fqn` (--verbose-air), or
/// `debug(illegal-air): "fqn":` followed by the body (--debug-log illegal-air).
fn splitDump(arena: Allocator, text: []const u8) Error!Dump {
    var funcs: std.ArrayList(Dump.Function) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var fqn: ?[]const u8 = null;
    var first: usize = 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    const begin = "# Begin Function AIR: ";
    const log_head = "debug(illegal-air): ";
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const starts_log = std.mem.startsWith(u8, line, log_head);
        if (std.mem.startsWith(u8, line, "debug(") and !starts_log) continue;
        if (std.mem.startsWith(u8, line, begin) or starts_log) {
            if (fqn) |name| try funcs.append(arena, .{ .fqn = name, .lines = lines.items, .first_line = first });
            lines = .empty;
            const header = if (starts_log) line[log_head.len..] else line[begin.len..];
            if (header.len < 2 or header[header.len - 1] != ':') return error.BadLine;
            const name = header[0 .. header.len - 1];
            fqn = if (starts_log) try stringLiteral(arena, name) else name;
            first = n + 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "# End Function AIR")) {
            if (fqn) |name| try funcs.append(arena, .{ .fqn = name, .lines = lines.items, .first_line = first });
            fqn = null;
            lines = .empty;
            continue;
        }
        if (fqn == null or line.len == 0 or line[0] == '#') continue;
        try lines.append(arena, line);
    }
    if (fqn) |name| try funcs.append(arena, .{ .fqn = name, .lines = lines.items, .first_line = first });
    return .{ .functions = funcs.items };
}

// ---------------------------------------------------------------- conversion to schema v1

const Conv = struct {
    arena: Allocator,
    index: *const SourceIndex,
    by_last: *const std.StringHashMapUnmanaged(std.ArrayList([]const u8)),
    stats: *Stats,
    fqn: []const u8,
    module_name: []const u8,
    file: u32 = 0,
    base_line: u32 = 0,
    loc: ?Loc = null,
    types: std.ArrayList(Out.TypeEntry) = .empty,
    type_ids: std.StringHashMapUnmanaged(u32) = .empty,
    files: std.ArrayList(Out.SourceFile) = .empty,
    callees: std.ArrayList(Out.Callee) = .empty,
    unsupported: u32 = 0,

    fn typeId(c: *Conv, text: []const u8) Error!u32 {
        const gop = try c.type_ids.getOrPut(c.arena, text);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(c.types.items.len);
            try c.types.append(c.arena, .{ .name = text, .kind = c.kindOf(text) });
        }
        return gop.value_ptr.*;
    }

    fn kindOf(c: *Conv, t: []const u8) []const u8 {
        const starts = std.mem.startsWith;
        if (t.len == 0) return "unknown";
        switch (t[0]) {
            '*' => return "pointer",
            '[' => return if (t.len > 1 and (std.ascii.isDigit(t[1]) or t[1] == ':')) "array" else "pointer",
            '?' => return "optional",
            '@' => {
                if (starts(u8, t, "@Vector(")) return "vector";
                if (starts(u8, t, "@TypeOf(.{})")) return "struct";
                c.stats.kind_unknown += 1;
                return "unknown";
            },
            else => {},
        }
        if (starts(u8, stripFnPrefix(t), "fn (")) return "fn";
        if (findTop(t, '!') != null) return "error_union";
        if (starts(u8, t, "error{") or std.mem.eql(u8, t, "anyerror")) return "error_set";
        if (starts(u8, t, "struct {") or starts(u8, t, "struct{")) return "struct";
        if (starts(u8, t, "union {")) return "union";
        if (starts(u8, t, "enum {")) return "enum";
        const plain = [_][]const u8{ "bool", "void", "noreturn", "type", "comptime_int", "comptime_float", "null", "undefined" };
        for (plain) |name| if (std.mem.eql(u8, t, name)) return name;
        if (std.mem.eql(u8, t, "anyopaque")) return "opaque";
        if (isIntName(t)) return "int";
        if (t[0] == 'f' and t.len > 1 and std.ascii.isDigit(t[1])) return "float";
        if (instanceSuffix(t)) |at| {
            const tail = t[at + 2 ..];
            return tail[0..std.mem.indexOfScalar(u8, tail, '_').?];
        }
        if (c.index.decls.get(t)) |d| return d.kind;
        c.stats.kind_unknown += 1;
        return "unknown";
    }

    fn fileId(c: *Conv, path: []const u8) Error!u32 {
        for (c.files.items, 0..) |f, i| if (std.mem.eql(u8, f.path, path)) return @intCast(i);
        try c.files.append(c.arena, .{ .module = c.module_name, .path = path });
        return @intCast(c.files.items.len - 1);
    }

    const Decl = struct { file: u32, base: u32 };

    /// File id and zero-based declaration line of `fqn` in the indexed sources.
    fn declOf(c: *Conv, fqn: []const u8) Error!?Decl {
        const module = c.index.moduleOf(fqn) orelse return null;
        const decl = c.index.lookup(fqn) orelse return null;
        return .{ .file = try c.fileId(c.index.modules.get(module).?), .base = decl.line - 1 };
    }

    /// Calls print only `(function 'short')`. The full name comes from the other functions in the
    /// dump, or from the caller's own container in the source.
    fn resolveCallee(c: *Conv, short: []const u8) []const u8 {
        const candidates = if (c.by_last.get(short)) |list| list.items else &[_][]const u8{};
        if (candidates.len == 1) return candidates[0];
        const parent = parentOf(c.fqn);
        if (candidates.len > 1) {
            c.stats.callee_ambiguous += 1;
            for (candidates) |cand| if (std.mem.eql(u8, parentOf(cand), parent)) return cand;
            return candidates[0];
        }
        const guess = std.fmt.allocPrint(c.arena, "{s}.{s}", .{ parent, short }) catch return short;
        if (c.index.decls.contains(stripInstance(guess))) return guess;
        c.stats.callee_unresolved += 1;
        return short;
    }

    fn operand(c: *Conv, op: Operand) Error!Out.Operand2 {
        return switch (op) {
            .none => .none,
            .inst => |id| .{ .inst = id },
            .constant => |k| .{ .constant = .{ .ty = try c.typeId(k.ty), .val = k.val } },
        };
    }

    fn operandList(c: *Conv, ops: []const Operand) Error![]const Out.Operand2 {
        const out = try c.arena.alloc(Out.Operand2, ops.len);
        for (ops, out) |op, *slot| slot.* = try c.operand(op);
        return out;
    }

    fn body(c: *Conv, insts: []const RawInst) Error![]const Out.Inst {
        const out = try c.arena.alloc(Out.Inst, insts.len);
        for (insts, out) |raw, *slot| slot.* = try c.inst(raw);
        return out;
    }

    fn inst(c: *Conv, raw: RawInst) Error!Out.Inst {
        c.stats.insts += 1;
        const loc = c.loc;
        if (raw.shape == .unsupported or raw.shape == .asm_) {
            c.unsupported += 1;
            c.stats.unsupported += 1;
            return .{ .id = raw.id, .tag = raw.tag, .supported = false };
        }
        const ops = try c.operandList(raw.operands);
        var attrs: std.ArrayList(Attr) = .empty;
        var callee: ?[]const u8 = null;
        if (raw.shape == .dbg_inline_block or (raw.shape == .call and raw.callee != null)) {
            const name = c.resolveCallee(raw.callee.?);
            callee = name;
            try attrs.append(c.arena, .{ .key = "callee", .value = .{ .str = name } });
            try c.callees.append(c.arena, .{ .fqn = name, .inlined = raw.shape == .dbg_inline_block });
        }
        if (raw.shape == .dbg_stmt) {
            const rel: u32 = @intCast(raw.attrs[0].value.int);
            c.loc = .{ .file = c.file, .line = c.base_line + rel, .col = @intCast(raw.attrs[1].value.int) };
            try attrs.append(c.arena, .{ .key = "line", .value = .{ .int = c.loc.?.line } });
            try attrs.append(c.arena, .{ .key = "col", .value = .{ .int = c.loc.?.col } });
        } else try attrs.appendSlice(c.arena, raw.attrs);

        const bodies = try c.arena.alloc(Out.Body, raw.bodies.len);
        if (raw.shape == .dbg_inline_block) {
            const saved = .{ c.base_line, c.file, c.loc };
            if (try c.declOf(callee.?)) |d| {
                c.base_line, c.file = .{ d.base, d.file };
            } else c.stats.decl_unresolved += 1;
            bodies[0] = .{ .label = raw.bodies[0].label, .insts = try c.body(raw.bodies[0].insts) };
            c.base_line, c.file, c.loc = saved;
        } else for (raw.bodies, bodies) |rb, *slot| {
            const ranges = try c.arena.alloc([2]Out.Operand2, rb.ranges.len);
            for (rb.ranges, ranges) |r, *out| out.* = .{ try c.operand(r[0]), try c.operand(r[1]) };
            slot.* = .{
                .label = rb.label,
                .items = try c.operandList(rb.items),
                .ranges = ranges,
                .insts = try c.body(rb.insts),
            };
        }
        const ty: ?u32 = if (raw.ty) |t| try c.typeId(t) else blk: {
            c.stats.unknown_ty += 1;
            break :blk null;
        };
        return .{
            .id = raw.id,
            .tag = raw.tag,
            .ty = ty,
            .operands = ops,
            .attrs = attrs.items,
            .loc = if (raw.shape == .dbg_stmt) c.loc else loc,
            .bodies = bodies,
        };
    }
};

fn findRet(insts: []const RawInst, tys: *const std.AutoHashMapUnmanaged(u32, ?[]const u8)) ?[]const u8 {
    for (insts) |raw| {
        if (std.mem.startsWith(u8, raw.tag, "ret") and raw.operands.len == 1) {
            const via_ptr = std.mem.eql(u8, raw.tag, "ret_load");
            const ty: ?[]const u8 = switch (raw.operands[0]) {
                .constant => |k| k.ty,
                .inst => |id| tys.get(id) orelse null,
                .none => null,
            };
            if (ty) |t| return if (via_ptr) childOf(t) else t;
        }
        for (raw.bodies) |b| if (findRet(b.insts, tys)) |t| return t;
    }
    return null;
}

// ---------------------------------------------------------------- output

const Stringify = std.json.Stringify;

fn field(s: *Stringify, name: []const u8, value: anytype) Stringify.Error!void {
    try s.objectField(name);
    try s.write(value);
}

fn writeOperands(s: *Stringify, operands: []const Out.Operand2) Stringify.Error!void {
    try s.beginArray();
    for (operands) |operand| switch (operand) {
        .none => try s.write(null),
        .inst => |id| try s.write(.{ .inst = id }),
        .constant => |k| try s.write(.{ .ty = k.ty, .val = k.val }),
    };
    try s.endArray();
}

fn writeInsts(s: *Stringify, insts: []const Out.Inst) Stringify.Error!void {
    try s.beginArray();
    for (insts) |inst| try writeInst(s, inst);
    try s.endArray();
}

fn writeInst(s: *Stringify, inst: Out.Inst) Stringify.Error!void {
    try s.beginObject();
    try field(s, "id", inst.id);
    try field(s, "tag", inst.tag);
    if (!inst.supported) {
        try field(s, "unsupported", true);
        return s.endObject();
    }
    try field(s, "ty", inst.ty);
    if (inst.operands.len != 0) {
        try s.objectField("operands");
        try writeOperands(s, inst.operands);
    }
    if (inst.attrs.len != 0) {
        try s.objectField("attrs");
        try s.beginObject();
        for (inst.attrs) |attr| switch (attr.value) {
            inline .int, .str, .flag => |v| try field(s, attr.key, v),
            .inst => |id| try field(s, attr.key, id),
        };
        try s.endObject();
    }
    if (inst.loc) |loc| try field(s, "loc", .{ loc.file, loc.line, loc.col });
    if (inst.bodies.len != 0) {
        try s.objectField("bodies");
        try s.beginArray();
        for (inst.bodies) |b| {
            try s.beginObject();
            try field(s, "label", b.label);
            if (b.items.len != 0) {
                try s.objectField("items");
                try writeOperands(s, b.items);
            }
            if (b.ranges.len != 0) {
                try s.objectField("ranges");
                try s.beginArray();
                for (b.ranges) |range| try writeOperands(s, &range);
                try s.endArray();
            }
            try s.objectField("insts");
            try writeInsts(s, b.insts);
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
}

fn writeFunction(w: *Io.Writer, zig_version: []const u8, f: Out.Function) Io.Writer.Error!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "schema", 1);
    try field(&s, "zig_version", zig_version);
    try field(&s, "fqn", f.fqn);
    try field(&s, "file", f.file);
    try field(&s, "line", f.line);
    try field(&s, "generic_instance", f.generic_instance);
    try field(&s, "params", f.params);
    try field(&s, "ret", f.ret);
    try field(&s, "unsupported", f.unsupported);
    try field(&s, "files", f.files);
    try field(&s, "types", f.types);
    try field(&s, "callees", f.callees);
    try s.objectField("insts");
    try writeInsts(&s, f.insts);
    try s.endObject();
}

fn fileName(arena: Allocator, fqn: []const u8, content: []const u8) Allocator.Error![]const u8 {
    const stem = try arena.dupe(u8, fqn[0..@min(fqn.len, 80)]);
    for (stem) |*byte| switch (byte.*) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '-' => {},
        else => byte.* = '_',
    };
    return std.fmt.allocPrint(arena, "{s}.{x:0>16}.json", .{ stem, std.hash.Wyhash.hash(0, content) });
}

// ---------------------------------------------------------------- driver

const usage =
    \\usage: air_text --zig-version V --module NAME=FILE [--module ...] [--file-module NAME]
    \\                [--legacy-tags] --out DIR DUMP
    \\  DUMP is the compiler's stderr. Functions whose fqn starts with a --module NAME are exported.
    \\  --file-module is the compiler's name for the root module (`test` for `zig test`), which the text lacks.
    \\  --legacy-tags reads the 0.16 tag spelling.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var zig_version: []const u8 = "unknown";
    var file_module: []const u8 = "";
    var out_dir: ?[]const u8 = null;
    var dump_path: ?[]const u8 = null;
    var legacy_tags = false;
    var all = false;
    var index: SourceIndex = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--legacy-tags")) {
            legacy_tags = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (i + 1 < args.len and std.mem.eql(u8, arg, "--zig-version")) {
            i += 1;
            zig_version = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, arg, "--file-module")) {
            i += 1;
            file_module = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, arg, "--out")) {
            i += 1;
            out_dir = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, arg, "--module")) {
            i += 1;
            const eq = std.mem.indexOfScalar(u8, args[i], '=') orelse fatal("--module wants NAME=FILE");
            try index.addModule(arena, io, args[i][0..eq], args[i][eq + 1 ..]);
        } else if (dump_path == null and !std.mem.startsWith(u8, arg, "--")) {
            dump_path = arg;
        } else fatal(usage);
    }
    const dump_file = dump_path orelse fatal(usage);
    const out = out_dir orelse fatal(usage);

    const text = try Io.Dir.cwd().readFileAlloc(io, dump_file, arena, .limited(1 << 30));
    const dump = try splitDump(arena, text);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var by_last: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    for (dump.functions) |f| {
        if ((try seen.getOrPut(arena, f.fqn)).found_existing) continue;
        const list = try by_last.getOrPut(arena, lastSegment(f.fqn));
        if (!list.found_existing) list.value_ptr.* = .empty;
        try list.value_ptr.append(arena, f.fqn);
    }

    try Io.Dir.cwd().createDirPath(io, out);
    var stats: Stats = .{};
    for (dump.functions) |f| {
        if (!all and index.moduleOf(f.fqn) == null) {
            stats.skipped += 1;
            continue;
        }
        var parser: Parser = .{ .arena = arena, .lines = f.lines, .legacy_tags = legacy_tags, .first_line = f.first_line };
        const raw = parser.parseInsts(false) catch |err| {
            if (!all) return err;
            stats.failed += 1;
            continue;
        };

        var c: Conv = .{ .arena = arena, .index = &index, .by_last = &by_last, .stats = &stats, .fqn = f.fqn, .module_name = file_module };
        var line: u32 = 0;
        if (try c.declOf(f.fqn)) |d| {
            c.file, c.base_line, line = .{ d.file, d.base, d.base + 1 };
        } else {
            stats.decl_unresolved += 1;
            c.file = try c.fileId("");
        }
        var params: std.ArrayList(Out.Param) = .empty;
        for (raw) |r| {
            if (!std.mem.eql(u8, r.tag, "arg")) break;
            try params.append(arena, .{ .ty = try c.typeId(r.ty.?), .zir_index = @intCast(r.attrs[0].value.int) });
        }
        const ret: ?u32 = if (findRet(raw, &parser.tys)) |t| try c.typeId(t) else null;
        const insts = try c.body(raw);
        const function: Out.Function = .{
            .fqn = f.fqn,
            .file = 0,
            .line = line,
            .generic_instance = instanceSuffix(f.fqn) != null,
            .params = params.items,
            .ret = ret,
            .files = c.files.items,
            .types = c.types.items,
            .insts = insts,
            .callees = c.callees.items,
            .unsupported = c.unsupported,
        };
        var aw: Io.Writer.Allocating = .init(arena);
        try writeFunction(&aw.writer, zig_version, function);
        const name = try fileName(arena, f.fqn, aw.written());
        const sub_path = try std.fs.path.join(arena, &.{ out, name });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = sub_path, .data = aw.written() });
        stats.functions += 1;
    }
    std.debug.print("{any}\n", .{stats});
}

fn fatal(message: []const u8) noreturn {
    std.debug.print("{s}\n", .{message});
    std.process.exit(2);
}
