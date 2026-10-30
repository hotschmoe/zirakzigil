//! The program generator. A program is a list of units (one or a few statements each) in groups (one group per
//! motif, wrapped in a block), drawn from the fixed library in prelude.zig. Every unit carries the construct tags
//! it exercises; a program's constructs are the union of its enabled units' tags. Generation is deterministic in
//! (seed, program id). The minimizer switches units and groups off and keeps what still compiles.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Tag = enum {
    // motifs
    m_buf,
    m_realloc,
    m_list,
    m_list_copy,
    m_elems,
    m_map,
    m_amap,
    m_skey,
    m_struct,
    m_bag,
    m_opt,
    m_union,
    m_err,
    m_helper,
    m_global,
    m_fnptr,
    m_arena,
    m_linear,
    m_pool,
    m_node,
    // constructs
    alloc,
    dupe,
    print,
    free,
    realloc,
    create,
    list,
    list_view,
    list_elem_ptr,
    list_copy,
    to_owned,
    map,
    map_ptr,
    map_remove,
    amap,
    skey,
    struct_field,
    struct_copy,
    struct_val_param,
    struct_ptr_param,
    opt_val,
    opt_ptr,
    union_tag,
    errdefer_,
    catch_free,
    catch_fallback,
    err_return,
    loop,
    helper_val,
    helper_ptr,
    alias_params,
    global,
    fnptr,
    fn_field,
    arena,
    arena_dupe,
    linear,
    linear_copy,
    linear_slice,
    pool,
    branch,
    defer_,
    alias,
    subslice,
    // steps that are a mistake when the paths line up
    bug_uaf,
    bug_double_free,
    bug_alias_uaf,
    bug_alias_free,
    bug_invalid_free,
    bug_cond_free,
    bug_loop_free,
    bug_defer_free,
    bug_helper_reuse,
    bug_helper_twice,
    bug_helper_alias,
    bug_realloc_stale,
    bug_realloc_old_free,
    bug_list_stale,
    bug_list_copy,
    bug_elem_double,
    bug_elem_stale,
    bug_elem_pop,
    bug_map_stale,
    bug_map_double,
    bug_map_uaf,
    bug_skey_literal,
    bug_struct_copy,
    bug_struct_field,
    bug_opt_stale,
    bug_opt_double,
    bug_union_double,
    bug_union_uaf,
    bug_union_tag,
    bug_errdefer_double,
    bug_catch_double,
    bug_catch_fallback,
    bug_global_stale,
    bug_global_double,
    bug_fnptr_free,
    bug_arena_uaf,
    bug_arena_foreign_free,
    bug_linear_twice,
    bug_linear_leak,
    bug_linear_copy,
    bug_linear_slice,
    bug_pool_stale,
    bug_pool_double,
    bug_node_uaf,
    bug_node_double,
    bug_bag_stale,
    bug_bag_copy,
};

pub const TagSet = std.EnumSet(Tag);

pub const Unit = struct {
    text: []const u8,
    tags: TagSet,
    group: u16,
    fixed: bool,
};

pub const Program = struct {
    id: u32,
    units: []const Unit,

    pub fn groups(p: Program) u16 {
        return p.units[p.units.len - 1].group;
    }
};

pub const Mask = []bool;

pub fn fullMask(arena: Allocator, p: Program) Allocator.Error!Mask {
    const mask = try arena.alloc(bool, p.units.len);
    @memset(mask, true);
    return mask;
}

pub fn tagsOf(p: Program, mask: []const bool) TagSet {
    var set: TagSet = .{};
    for (p.units, mask) |u, on| if (on) set.setUnion(u.tags);
    return set;
}

pub fn unitCount(p: Program, mask: []const bool) usize {
    var n: usize = 0;
    for (p.units, mask) |u, on| {
        if (on and !u.fixed) n += 1;
    }
    return n;
}

/// The name a program has in its batch file.
pub fn fnName(w: *Io.Writer, id: u32) Io.Writer.Error!void {
    try w.print("p{d}", .{id});
}

pub fn render(w: *Io.Writer, p: Program, mask: []const bool, compact: bool) Io.Writer.Error!void {
    try w.print("pub fn p{d}(a: Allocator, selv: u8) anyerror!void {{\n", .{p.id});
    var uses_sel = false;
    for (p.units, mask) |u, on| {
        if (on and std.mem.find(u8, u.text, "selv") != null) uses_sel = true;
    }
    if (!uses_sel and !compact) try w.writeAll("    _ = selv;\n");
    if (!compact) try w.writeAll("    _ = &a;\n");
    for (p.units, mask) |u, on| {
        if (on and !(compact and u.group == 0)) try w.writeAll(u.text);
    }
    try w.writeAll("}\n\n");
}

const Gen = struct {
    arena: Allocator,
    r: std.Random,
    units: std.ArrayList(Unit) = .empty,
    group: u16 = 0,
    vars: u16 = 0,

    fn unit(g: *Gen, tags: []const Tag, text: []const u8, fixed: bool) !void {
        try g.units.append(g.arena, .{ .text = text, .tags = .initMany(tags), .group = g.group, .fixed = fixed });
    }

    fn e(g: *Gen, tags: []const Tag, comptime fmt: []const u8, args: anytype) !void {
        try g.unit(tags, try std.fmt.allocPrint(g.arena, "    " ++ fmt ++ "\n", args), false);
    }

    fn open(g: *Gen, motif: Tag) !void {
        g.group += 1;
        g.vars = 0;
        try g.unit(&.{motif}, "    {\n", true);
    }

    fn close(g: *Gen, motif: Tag) !void {
        try g.unit(&.{motif}, "    }\n", true);
    }

    fn v(g: *Gen) ![]const u8 {
        g.vars += 1;
        return std.fmt.allocPrint(g.arena, "v{d}_{d}", .{ g.group, g.vars });
    }

    fn pct(g: *Gen, p: u8) bool {
        return g.r.uintLessThan(u8, 100) < p;
    }

    fn below(g: *Gen, n: u8) u8 {
        return g.r.uintLessThan(u8, n);
    }

    fn size(g: *Gen) usize {
        return g.r.intRangeAtMost(usize, 3, 20);
    }

    fn cond(g: *Gen) []const u8 {
        const options = [_][]const u8{ "selv == 0", "selv & 1 == 1", "selv >= 2", "selv == 3" };
        return options[g.below(options.len)];
    }
};

const motifs = [_]*const fn (*Gen) anyerror!void{
    buf, realloc, list, listCopy, elems, map, amap, skey, structs, bag, opt, union_, err, helper, global, fnptr, arenaMotif, linear, pool, node,
};

pub fn generate(arena: Allocator, seed: u64, id: u32) !Program {
    var prng = std.Random.DefaultPrng.init(seed ^ (@as(u64, id) *% 0x9E3779B97F4A7C15));
    var g: Gen = .{ .arena = arena, .r = prng.random() };
    try g.unit(&.{}, "    g_slice = &.{};\n    g_opt = null;\n", true);
    const roll = g.below(100);
    const count: usize = if (roll < 35) 1 else if (roll < 75) 2 else 3;
    for (0..count) |_| {
        const motif = motifs[g.below(motifs.len)];
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const mark = g.units.items.len;
            const group = g.group;
            try motif(&g);
            if (attempt == 6 or !hasBug(g.units.items[mark..]) or g.pct(45)) break;
            g.units.shrinkRetainingCapacity(mark);
            g.group = group;
        }
    }
    return .{ .id = id, .units = try g.units.toOwnedSlice(arena) };
}

fn hasBug(units: []const Unit) bool {
    for (units) |u| {
        var it = u.tags.iterator();
        while (it.next()) |t| {
            if (std.mem.startsWith(u8, @tagName(t), "bug_")) return true;
        }
    }
    return false;
}

fn buf(g: *Gen) !void {
    const m = Tag.m_buf;
    const v = try g.v();
    const w = try g.v();
    const n = g.size();
    try g.open(m);
    switch (g.below(5)) {
        0, 1 => try g.e(&.{ m, .alloc }, "const {s} = try mk(a, {d});", .{ v, n }),
        2 => try g.e(&.{ m, .dupe }, "const {s} = try a.dupe(u8, \"hello world\");", .{v}),
        3 => try g.e(&.{ m, .print }, "const {s} = try std.fmt.allocPrint(a, \"{{d}}-{{d}}\", .{{ {d}, {d} }});", .{ v, n, n * 7 }),
        else => try g.e(&.{ m, .alloc }, "const {s} = try a.alloc(u8, {d});\n    @memset({s}, 7);", .{ v, n, v }),
    }
    const kind: u8 = g.below(4); // 0 none, 1 same, 2 through a call, 3 subslice
    if (kind != 0) {
        const rhs = switch (kind) {
            1 => v,
            2 => try std.fmt.allocPrint(g.arena, "ident({s})", .{v}),
            else => try std.fmt.allocPrint(g.arena, "{s}[1..]", .{v}),
        };
        try g.e(&.{ m, .alias, if (kind == 3) .subslice else .alias }, "const {s} = {s};", .{ w, rhs });
    }
    const early_alias = kind != 0 and g.pct(50);
    if (early_alias) try g.e(&.{m}, "_ = rd({s});", .{w});
    const late_alias = kind != 0 and !early_alias;
    const c = g.cond();
    const variant: u8 = if (late_alias) 20 + g.below(2) else g.below(11);
    switch (variant) {
        0, 1, 2 => {
            try g.e(&.{m}, "_ = rd({s});", .{v});
            try g.e(&.{ m, .free }, "a.free({s});", .{v});
        },
        3 => {
            try g.e(&.{ m, .free }, "a.free({s});", .{v});
            try g.e(&.{ m, .bug_uaf }, "_ = rd({s});", .{v});
        },
        4 => {
            try g.e(&.{ m, .free }, "a.free({s});", .{v});
            try g.e(&.{ m, .free, .bug_double_free }, "a.free({s});", .{v});
        },
        5 => {
            try g.e(&.{ m, .free, .branch, .bug_cond_free }, "if ({s}) a.free({s});", .{ c, v });
            try g.e(&.{ m, .free }, "a.free({s});", .{v});
        },
        6 => {
            try g.e(&.{ m, .free, .branch }, "if ({s}) {{ _ = rd({s}); a.free({s}); }} else {{ a.free({s}); }}", .{ c, v, v, v });
        },
        7 => {
            try g.e(&.{ m, .free, .loop, .bug_loop_free }, "for (0..2) |_| a.free({s});", .{v});
        },
        8 => {
            try g.e(&.{ m, .defer_ }, "defer a.free({s});", .{v});
            try g.e(&.{ m, .free, .bug_defer_free }, "a.free({s});", .{v});
        },
        9 => {
            try g.e(&.{ m, .defer_ }, "defer a.free({s});", .{v});
            try g.e(&.{m}, "_ = rd({s});", .{v});
        },
        10 => {
            try g.e(&.{ m, .helper_val }, "consume(a, {s});", .{v});
            try g.e(&.{ m, .bug_helper_reuse }, "_ = rd({s});", .{v});
        },
        20 => {
            try g.e(&.{ m, .free }, "a.free({s});", .{v});
            try g.e(&.{ m, .bug_alias_uaf }, "_ = rd({s});", .{w});
        },
        else => if (kind == 3) {
            try g.e(&.{ m, .free, .bug_invalid_free }, "a.free({s});", .{w});
        } else {
            try g.e(&.{ m, .free }, "a.free({s});", .{v});
            try g.e(&.{ m, .free, .bug_alias_free }, "a.free({s});", .{w});
        },
    }
    if (kind == 3 and variant < 20 and g.pct(30)) try g.e(&.{ m, .bug_invalid_free, .free }, "a.free({s});", .{w});
    try g.close(m);
}

fn realloc(g: *Gen) !void {
    const m = Tag.m_realloc;
    const v = try g.v();
    const old = try g.v();
    try g.open(m);
    try g.e(&.{ m, .alloc }, "var {s} = try mk(a, 4);", .{v});
    const keep = g.pct(60);
    if (keep) try g.e(&.{ m, .alias }, "const {s} = {s};", .{ old, v });
    const grow = g.pct(70);
    const len: usize = if (grow) 24 else 2;
    try g.e(&.{ m, .realloc }, "{s} = try a.realloc({s}, {d});", .{ v, v, len });
    if (grow) try g.e(&.{m}, "fill({s}, 4);", .{v});
    if (keep) switch (g.below(3)) {
        0 => {
            try g.e(&.{ m, .bug_realloc_stale }, "_ = rd({s});", .{old});
            try g.e(&.{ m, .free }, "a.free({s});", .{v});
        },
        1 => {
            try g.e(&.{ m, .free }, "a.free({s});", .{v});
            try g.e(&.{ m, .free, .bug_realloc_old_free }, "a.free({s});", .{old});
        },
        else => {
            try g.e(&.{ m, .free, .bug_realloc_old_free }, "a.free({s});", .{old});
        },
    } else {
        try g.e(&.{m}, "_ = rd({s});", .{v});
        try g.e(&.{ m, .free }, "a.free({s});", .{v});
    }
    try g.close(m);
}

fn viewUse(g: *Gen, view: u8, name: []const u8) ![]const u8 {
    if (view == 2) return std.fmt.allocPrint(g.arena, "rdb({s})", .{name});
    return std.fmt.allocPrint(g.arena, "rd({s})", .{name});
}

fn list(g: *Gen) !void {
    const m = Tag.m_list;
    const l = try g.v();
    const it = try g.v();
    const o = try g.v();
    try g.open(m);
    try g.e(&.{ m, .list }, "var {s}: std.ArrayList(u8) = .empty;", .{l});
    const deferred = g.pct(35);
    if (deferred) try g.e(&.{ m, .defer_ }, "defer {s}.deinit(a);", .{l});
    try g.e(&.{m}, "try {s}.append(a, 1);", .{l});
    try g.e(&.{m}, "try {s}.appendSlice(a, \"abc\");", .{l});
    const view = g.below(4); // 0 none, 1 slice, 2 element pointer, 3 sub slice
    switch (view) {
        1 => try g.e(&.{ m, .list_view }, "const {s} = {s}.items;", .{ it, l }),
        2 => try g.e(&.{ m, .list_elem_ptr }, "const {s} = &{s}.items[0];", .{ it, l }),
        3 => try g.e(&.{ m, .list_view, .subslice }, "const {s} = {s}.items[1..];", .{ it, l }),
        else => {},
    }
    const read = try viewUse(g, view, it);
    const use_before = view != 0 and g.pct(40);
    if (use_before) try g.e(&.{m}, "_ = {s};", .{read});
    switch (g.below(5)) {
        1 => try g.e(&.{m}, "try {s}.appendSlice(a, \"the quick brown fox jumps over the lazy dog\");", .{l}),
        2 => try g.e(&.{m}, "try {s}.ensureTotalCapacity(a, 64);", .{l}),
        3 => try g.e(&.{m}, "try {s}.append(a, 9);", .{l}),
        4 => try g.e(&.{m}, "try {s}.insert(a, 0, 5);", .{l}),
        else => {},
    }
    if (view != 0 and !use_before) try g.e(&.{ m, .bug_list_stale }, "_ = {s};", .{read});
    switch (g.below(4)) {
        0, 1 => if (!deferred) try g.e(&.{m}, "{s}.deinit(a);", .{l}),
        2 => {
            try g.e(&.{ m, .to_owned }, "const {s} = try {s}.toOwnedSlice(a);", .{ o, l });
            try g.e(&.{ m, .free }, "a.free({s});", .{o});
            if (!deferred) try g.e(&.{m}, "{s}.deinit(a);", .{l});
        },
        else => {
            if (!deferred) try g.e(&.{m}, "{s}.deinit(a);", .{l});
            if (view != 0) try g.e(&.{ m, .bug_list_stale }, "_ = {s};", .{read});
        },
    }
    try g.close(m);
}

fn listCopy(g: *Gen) !void {
    const m = Tag.m_list_copy;
    const l = try g.v();
    const l2 = try g.v();
    try g.open(m);
    try g.e(&.{ m, .list }, "var {s}: std.ArrayList(u8) = .empty;", .{l});
    try g.e(&.{m}, "try {s}.append(a, 1);", .{l});
    try g.e(&.{ m, .list_copy, .struct_copy }, "var {s} = {s};", .{ l2, l });
    switch (g.below(3)) {
        0 => try g.e(&.{m}, "try {s}.appendSlice(a, \"the quick brown fox jumps over the lazy dog\");", .{l2}),
        1 => try g.e(&.{m}, "try {s}.append(a, 3);", .{l2}),
        else => try g.e(&.{m}, "_ = &{s};", .{l2}),
    }
    switch (g.below(5)) {
        0, 1 => try g.e(&.{m}, "{s}.deinit(a);", .{l2}),
        2 => {
            try g.e(&.{m}, "{s}.deinit(a);", .{l});
            try g.e(&.{ m, .bug_list_copy }, "{s}.deinit(a);", .{l2});
        },
        3 => {
            try g.e(&.{m}, "{s}.deinit(a);", .{l2});
            try g.e(&.{ m, .bug_list_copy }, "{s}.deinit(a);", .{l});
        },
        else => {
            try g.e(&.{m}, "{s}.deinit(a);", .{l2});
            try g.e(&.{ m, .bug_list_copy, .list_elem_ptr }, "_ = rdb(&{s}.items[0]);", .{l});
        },
    }
    try g.close(m);
}

fn elems(g: *Gen) !void {
    const m = Tag.m_elems;
    const l = try g.v();
    const x = try g.v();
    try g.open(m);
    try g.e(&.{ m, .list }, "var {s}: std.ArrayList([]u8) = .empty;", .{l});
    const k = g.r.intRangeAtMost(usize, 2, 4);
    const early_free = g.pct(12);
    if (early_free) {
        try g.e(&.{ m, .loop, .alloc, .bug_elem_double }, "for (0..{d}) |i| {{ const s = try mk(a, 3 + i); try {s}.append(a, s); a.free(s); }}", .{ k, l });
    } else {
        try g.e(&.{ m, .loop, .alloc }, "for (0..{d}) |i| {{ try {s}.append(a, try mk(a, 3 + i)); }}", .{ k, l });
    }
    switch (g.below(10)) {
        0, 1 => {
            try g.e(&.{ m, .loop, .free }, "for ({s}.items) |s| a.free(s);", .{l});
            try g.e(&.{m}, "{s}.deinit(a);", .{l});
        },
        2 => {
            try g.e(&.{ m, .loop, .free }, "for ({s}.items) |s| a.free(s);", .{l});
            try g.e(&.{ m, .loop, .free, .bug_elem_double }, "for ({s}.items) |s| a.free(s);", .{l});
            try g.e(&.{m}, "{s}.deinit(a);", .{l});
        },
        3 => {
            try g.e(&.{ m, .free, .bug_elem_double }, "a.free({s}.items[0]);", .{l});
            try g.e(&.{ m, .loop, .free }, "for ({s}.items) |s| a.free(s);", .{l});
            try g.e(&.{m}, "{s}.deinit(a);", .{l});
        },
        4 => {
            try g.e(&.{ m, .alias }, "const {s} = {s}.items[0];", .{ x, l });
            try g.e(&.{ m, .loop, .free }, "for ({s}.items) |s| a.free(s);", .{l});
            try g.e(&.{ m, .bug_elem_stale }, "_ = rd({s});", .{x});
            try g.e(&.{m}, "{s}.deinit(a);", .{l});
        },
        5 => {
            try g.e(&.{ m, .free }, "a.free({s}.pop().?);", .{l});
            try g.e(&.{ m, .loop, .free }, "for ({s}.items) |s| a.free(s);", .{l});
            try g.e(&.{m}, "{s}.deinit(a);", .{l});
        },
        6 => {
            try g.e(&.{ m, .free, .bug_elem_pop }, "a.free({s}.items[{s}.items.len - 1]);", .{ l, l });
            try g.e(&.{ m, .loop, .free }, "for ({s}.items) |s| a.free(s);", .{l});
            try g.e(&.{m}, "{s}.deinit(a);", .{l});
        },
        7 => {
            try g.e(&.{ m, .free }, "a.free({s}.swapRemove(0));", .{l});
            try g.e(&.{ m, .loop, .free }, "for ({s}.items) |s| a.free(s);", .{l});
            try g.e(&.{m}, "{s}.deinit(a);", .{l});
        },
        8 => {
            try g.e(&.{ m, .loop, .free, .bug_elem_double, .branch }, "for ({s}.items, 0..) |s, i| {{ if (i % 2 == 0) a.free(s); }}", .{l});
            try g.e(&.{ m, .loop, .free }, "for ({s}.items) |s| a.free(s);", .{l});
            try g.e(&.{m}, "{s}.deinit(a);", .{l});
        },
        else => {
            try g.e(&.{ m, .to_owned }, "const {s} = try {s}.toOwnedSlice(a);", .{ x, l });
            try g.e(&.{ m, .loop, .free }, "for ({s}) |s| a.free(s);", .{x});
            try g.e(&.{ m, .free }, "a.free({s});", .{x});
            try g.e(&.{m}, "{s}.deinit(a);", .{l});
        },
    }
    try g.close(m);
}

fn map(g: *Gen) !void {
    const m = Tag.m_map;
    const mp = try g.v();
    const p = try g.v();
    const x = try g.v();
    try g.open(m);
    try g.e(&.{ m, .map }, "var {s} = std.AutoHashMap(u8, []u8).init(a);", .{mp});
    try g.e(&.{m}, "try {s}.put(1, try mk(a, 3));", .{mp});
    try g.e(&.{m}, "try {s}.put(2, try mk(a, 4));", .{mp});
    const mode = g.below(4); // 0 none, 1 pointer into the table, 2 value copy, 3 pointer and removal
    switch (mode) {
        1, 3 => try g.e(&.{ m, .map_ptr }, "const {s} = {s}.getPtr(1).?;", .{ p, mp }),
        2 => {
            try g.e(&.{ m, .alias }, "const {s} = {s}.get(1).?;", .{ x, mp });
            try g.e(&.{m}, "_ = rd({s});", .{x});
        },
        else => {},
    }
    if (mode == 1 and g.pct(60)) try g.e(&.{ m, .loop }, "for (0..40) |i| try {s}.put(@intCast(10 + i), try mk(a, 3));", .{mp});
    if (mode == 3) try g.e(&.{ m, .map_remove, .free }, "if ({s}.fetchRemove(1)) |kv| a.free(kv.value);", .{mp});
    switch (mode) {
        1, 3 => try g.e(&.{ m, .bug_map_stale }, "_ = rdp({s});", .{p}),
        else => {},
    }
    switch (g.below(4)) {
        0, 1 => {
            try g.e(&.{ m, .loop, .free }, "{{ var it = {s}.valueIterator(); while (it.next()) |q| a.free(q.*); }}", .{mp});
        },
        2 => {
            try g.e(&.{ m, .loop, .free }, "{{ var it = {s}.valueIterator(); while (it.next()) |q| a.free(q.*); }}", .{mp});
            if (mode == 2) try g.e(&.{ m, .bug_map_uaf }, "_ = rd({s});", .{x});
        },
        else => {
            if (mode == 2) try g.e(&.{ m, .free, .bug_map_double }, "a.free({s});", .{x});
            try g.e(&.{ m, .loop, .free }, "{{ var it = {s}.valueIterator(); while (it.next()) |q| a.free(q.*); }}", .{mp});
        },
    }
    try g.e(&.{m}, "{s}.deinit();", .{mp});
    try g.close(m);
}

fn amap(g: *Gen) !void {
    const m = Tag.m_amap;
    const mp = try g.v();
    const vs = try g.v();
    try g.open(m);
    try g.e(&.{ m, .amap }, "var {s}: std.array_hash_map.Auto(u8, []u8) = .empty;", .{mp});
    try g.e(&.{m}, "try {s}.put(a, 1, try mk(a, 3));", .{mp});
    try g.e(&.{m}, "try {s}.put(a, 2, try mk(a, 4));", .{mp});
    const view = g.pct(50);
    if (view) try g.e(&.{ m, .list_view }, "const {s} = {s}.values();", .{ vs, mp });
    const grow = g.pct(50);
    if (grow) try g.e(&.{ m, .loop }, "for (0..40) |i| try {s}.put(a, @intCast(10 + i), try mk(a, 3));", .{mp});
    if (view) try g.e(&.{ m, .bug_map_stale }, "_ = rdp(&{s}[0]);", .{vs});
    switch (g.below(3)) {
        0 => try g.e(&.{ m, .map_remove, .free }, "if ({s}.fetchSwapRemove(1)) |kv| a.free(kv.value);", .{mp}),
        1 => {
            try g.e(&.{ m, .free, .bug_map_double }, "if ({s}.get(2)) |s| a.free(s);", .{mp});
        },
        else => {},
    }
    try g.e(&.{ m, .loop, .free }, "for ({s}.values()) |s| a.free(s);", .{mp});
    try g.e(&.{m}, "{s}.deinit(a);", .{mp});
    try g.close(m);
}

fn skey(g: *Gen) !void {
    const m = Tag.m_skey;
    const mp = try g.v();
    const k = try g.v();
    try g.open(m);
    try g.e(&.{ m, .skey, .map }, "var {s} = std.StringHashMap([]u8).init(a);", .{mp});
    try g.e(&.{ m, .dupe }, "const {s} = try a.dupe(u8, \"key\");", .{k});
    try g.e(&.{m}, "try {s}.put({s}, try mk(a, 3));", .{ mp, k });
    const literal = g.pct(35);
    if (literal) try g.e(&.{ m, .bug_skey_literal }, "try {s}.put(&static_buf, try mk(a, 3));", .{mp});
    const early = g.pct(30);
    if (early) try g.e(&.{ m, .free, .bug_double_free }, "a.free({s});", .{k});
    try g.e(&.{ m, .loop, .free }, "{{ var it = {s}.iterator(); while (it.next()) |e| {{ a.free(e.key_ptr.*); a.free(e.value_ptr.*); }} }}", .{mp});
    try g.e(&.{m}, "{s}.deinit();", .{mp});
    try g.close(m);
}

fn structs(g: *Gen) !void {
    const m = Tag.m_struct;
    const r = try g.v();
    const r2 = try g.v();
    try g.open(m);
    const case = g.below(10);
    try g.e(&.{ m, .struct_field, .alloc }, "{s} {s} = try Rec.init(a, {d});", .{ if (case == 5) "const" else "var", r, g.size() });
    switch (case) {
        0, 1 => {
            try g.e(&.{m}, "_ = {s}.sum();", .{r});
            try g.e(&.{ m, .free }, "{s}.deinit(a);", .{r});
        },
        2 => {
            try g.e(&.{ m, .struct_copy }, "const {s} = {s};", .{ r2, r });
            try g.e(&.{ m, .free }, "{s}.deinit(a);", .{r});
            try g.e(&.{ m, .bug_struct_copy }, "_ = {s}.sum();", .{r2});
        },
        3 => {
            try g.e(&.{ m, .struct_copy }, "var {s} = {s};", .{ r2, r });
            try g.e(&.{ m, .free }, "{s}.deinit(a);", .{r});
            try g.e(&.{ m, .free, .bug_struct_copy }, "{s}.deinit(a);", .{r2});
        },
        4 => {
            try g.e(&.{ m, .struct_val_param, .free }, "dropRec(a, {s});", .{r});
            try g.e(&.{ m, .free, .bug_struct_copy }, "{s}.deinit(a);", .{r});
        },
        5 => {
            try g.e(&.{ m, .struct_val_param, .free }, "dropRec(a, {s});", .{r});
            try g.e(&.{ m, .bug_struct_copy }, "_ = {s}.sum();", .{r});
        },
        6 => {
            try g.e(&.{ m, .free }, "a.free({s}.name);", .{r});
            try g.e(&.{ m, .free, .bug_struct_field }, "{s}.deinit(a);", .{r});
        },
        7 => {
            try g.e(&.{ m, .free, .alloc }, "a.free({s}.vals);", .{r});
            try g.e(&.{m}, "{s}.vals = try mk(a, 5);", .{r});
            try g.e(&.{ m, .free }, "{s}.deinit(a);", .{r});
        },
        8 => {
            try g.e(&.{ m, .free, .struct_ptr_param }, "{s}.deinit(a);", .{r});
            try g.e(&.{ m, .free, .bug_struct_field }, "a.free({s}.vals);", .{r});
        },
        else => {
            try g.e(&.{ m, .struct_ptr_param }, "_ = {s}.sum();", .{r});
            try g.e(&.{ m, .free }, "{s}.deinit(a);", .{r});
            try g.e(&.{ m, .bug_struct_field }, "_ = rd({s}.vals);", .{r});
        },
    }
    try g.close(m);
}

fn bag(g: *Gen) !void {
    const m = Tag.m_bag;
    const b = try g.v();
    const c = try g.v();
    const vw = try g.v();
    const o = try g.v();
    try g.open(m);
    try g.e(&.{ m, .struct_field, .list }, "var {s}: Bag = .{{}};", .{b});
    try g.e(&.{m}, "try {s}.add(a, 1);", .{b});
    switch (g.below(6)) {
        0 => {
            try g.e(&.{ m, .list_view }, "const {s} = {s}.view();", .{ vw, b });
            for (0..g.r.intRangeAtMost(usize, 1, 12)) |_| try g.e(&.{m}, "try {s}.add(a, 2);", .{b});
            try g.e(&.{ m, .bug_bag_stale }, "_ = rd({s});", .{vw});
            try g.e(&.{m}, "{s}.deinit(a);", .{b});
        },
        1 => {
            try g.e(&.{ m, .list_view }, "const {s} = {s}.view();", .{ vw, b });
            try g.e(&.{m}, "_ = rd({s});", .{vw});
            try g.e(&.{m}, "{s}.deinit(a);", .{b});
        },
        2 => {
            try g.e(&.{ m, .struct_copy }, "var {s} = {s};", .{ c, b });
            try g.e(&.{m}, "try {s}.add(a, 2);", .{b});
            try g.e(&.{m}, "{s}.deinit(a);", .{b});
            try g.e(&.{ m, .bug_bag_copy }, "{s}.deinit(a);", .{c});
        },
        3 => {
            try g.e(&.{ m, .to_owned }, "const {s} = try {s}.take(a);", .{ o, b });
            try g.e(&.{ m, .free }, "a.free({s});", .{o});
            try g.e(&.{m}, "{s}.deinit(a);", .{b});
        },
        4 => {
            try g.e(&.{ m, .to_owned }, "const {s} = try {s}.take(a);", .{ o, b });
            try g.e(&.{ m, .list_view }, "const {s} = {s}.view();", .{ vw, b });
            try g.e(&.{ m, .free }, "a.free({s});", .{o});
            try g.e(&.{m}, "_ = rd({s});", .{vw});
            try g.e(&.{m}, "{s}.deinit(a);", .{b});
        },
        else => {
            try g.e(&.{ m, .to_owned }, "const {s} = try {s}.take(a);", .{ o, b });
            try g.e(&.{ m, .free }, "a.free({s});", .{o});
            try g.e(&.{ m, .free, .bug_bag_copy }, "a.free({s});", .{o});
            try g.e(&.{m}, "{s}.deinit(a);", .{b});
        },
    }
    try g.close(m);
}

fn opt(g: *Gen) !void {
    const m = Tag.m_opt;
    const o = try g.v();
    try g.open(m);
    const case = g.below(9);
    const kw = switch (case) {
        0, 1, 2, 5, 6 => "var",
        else => "const",
    };
    try g.e(&.{ m, .opt_val, .alloc }, "{s} {s}: ?[]u8 = try mk(a, {d});", .{ kw, o, g.size() });
    switch (case) {
        0, 1 => try g.e(&.{ m, .opt_ptr, .free }, "takeOpt(a, &{s});", .{o}),
        2 => {
            try g.e(&.{ m, .free }, "if ({s}) |s| {{ _ = rd(s); a.free(s); {s} = null; }}", .{ o, o });
        },
        3 => {
            try g.e(&.{ m, .free }, "if ({s}) |s| a.free(s);", .{o});
            try g.e(&.{ m, .bug_opt_stale }, "_ = rdOpt({s});", .{o});
        },
        4 => {
            try g.e(&.{ m, .free }, "if ({s}) |s| a.free(s);", .{o});
            try g.e(&.{ m, .opt_val, .bug_opt_double }, "dropOpt(a, {s});", .{o});
        },
        5 => {
            try g.e(&.{ m, .opt_ptr, .free }, "takeOpt(a, &{s});", .{o});
            try g.e(&.{ m, .opt_ptr, .free }, "takeOpt(a, &{s});", .{o});
        },
        6 => {
            try g.e(&.{ m, .opt_ptr, .free }, "keepOpt(a, &{s});", .{o});
            try g.e(&.{ m, .opt_ptr, .free, .bug_opt_double }, "keepOpt(a, &{s});", .{o});
        },
        7 => {
            try g.e(&.{ m, .free }, "a.free({s}.?);", .{o});
            try g.e(&.{ m, .bug_opt_stale }, "_ = rd({s}.?);", .{o});
        },
        else => {
            try g.e(&.{ m, .opt_val, .free }, "dropOpt(a, {s});", .{o});
            try g.e(&.{ m, .bug_opt_stale }, "_ = rdOpt({s});", .{o});
        },
    }
    try g.close(m);
}

fn union_(g: *Gen) !void {
    const m = Tag.m_union;
    const u = try g.v();
    try g.open(m);
    const case = g.below(8);
    const kw = if (case == 5) "var" else "const";
    if (g.pct(50)) {
        try g.e(&.{ m, .union_tag, .alloc }, "{s} {s}: U = .{{ .owned = try mk(a, {d}) }};", .{ kw, u, g.size() });
    } else {
        try g.e(&.{ m, .union_tag, .alloc, .branch }, "{s} {s}: U = if (selv & 1 == 0) .{{ .owned = try mk(a, {d}) }} else .{{ .borrowed = &static_buf }};", .{ kw, u, g.size() });
    }
    switch (case) {
        0, 1 => try g.e(&.{ m, .free }, "dropU(a, {s});", .{u}),
        2 => {
            try g.e(&.{ m, .free }, "dropU(a, {s});", .{u});
            try g.e(&.{ m, .free, .bug_union_double }, "dropU(a, {s});", .{u});
        },
        3 => {
            try g.e(&.{ m, .free }, "switch ({s}) {{ .owned => |s| a.free(s), else => {{}} }}", .{u});
            try g.e(&.{ m, .bug_union_uaf }, "_ = rdU({s});", .{u});
        },
        4 => try g.e(&.{ m, .free, .bug_union_tag }, "dropAnyU(a, {s});", .{u}),
        5 => {
            try g.e(&.{ m, .free }, "dropU(a, {s});", .{u});
            try g.e(&.{m}, "{s} = .none;", .{u});
            try g.e(&.{ m, .free }, "dropU(a, {s});", .{u});
        },
        6 => {
            try g.e(&.{m}, "_ = rdU({s});", .{u});
            try g.e(&.{ m, .free }, "dropU(a, {s});", .{u});
        },
        else => {
            try g.e(&.{ m, .free, .bug_union_tag }, "switch ({s}) {{ .owned => |s| a.free(s), .borrowed => |s| a.free(@constCast(s)), .none => {{}} }}", .{u});
        },
    }
    try g.close(m);
}

fn err(g: *Gen) !void {
    const m = Tag.m_err;
    const x = try g.v();
    const y = try g.v();
    const c = g.cond();
    try g.open(m);
    try g.e(&.{ m, .alloc }, "const {s} = try mk(a, 3);", .{x});
    switch (g.below(9)) {
        0, 1 => {
            try g.e(&.{ m, .errdefer_ }, "errdefer a.free({s});", .{x});
            try g.e(&.{ m, .alloc }, "const {s} = try mk(a, 4);", .{y});
            try g.e(&.{ m, .errdefer_ }, "errdefer a.free({s});", .{y});
            try g.e(&.{ m, .err_return, .branch }, "if ({s}) return error.Boom;", .{c});
            try g.e(&.{ m, .free }, "a.free({s});", .{y});
            try g.e(&.{ m, .free }, "a.free({s});", .{x});
        },
        2 => {
            try g.e(&.{ m, .errdefer_ }, "errdefer a.free({s});", .{x});
            try g.e(&.{ m, .alloc }, "const {s} = try mk(a, 4);", .{y});
            try g.e(&.{ m, .free }, "a.free({s});", .{x});
            try g.e(&.{ m, .free }, "a.free({s});", .{y});
            try g.e(&.{ m, .err_return, .bug_errdefer_double }, "try mayFail({s});", .{c});
        },
        3 => {
            try g.e(&.{ m, .errdefer_ }, "errdefer a.free({s});", .{x});
            try g.e(&.{ m, .alloc, .catch_free, .bug_catch_double }, "const {s} = mk(a, 4) catch |e| {{ a.free({s}); return e; }};", .{ y, x });
            try g.e(&.{ m, .free }, "a.free({s});", .{y});
            try g.e(&.{ m, .free }, "a.free({s});", .{x});
        },
        4 => {
            try g.e(&.{ m, .alloc, .catch_free }, "const {s} = mk(a, 4) catch |e| {{ a.free({s}); return e; }};", .{ y, x });
            try g.e(&.{ m, .free }, "a.free({s});", .{x});
            try g.e(&.{ m, .free }, "a.free({s});", .{y});
        },
        5 => {
            try g.e(&.{ m, .alloc, .catch_fallback }, "const {s} = mk(a, 4) catch {s};", .{ y, x });
            try g.e(&.{ m, .free }, "a.free({s});", .{x});
            try g.e(&.{ m, .free, .bug_catch_fallback }, "a.free({s});", .{y});
        },
        6 => {
            try g.e(&.{ m, .defer_ }, "defer a.free({s});", .{x});
            try g.e(&.{ m, .alloc }, "const {s} = try mk(a, 4);", .{y});
            try g.e(&.{ m, .defer_ }, "defer a.free({s});", .{y});
            try g.e(&.{m}, "_ = rd({s});", .{y});
            try g.e(&.{ m, .err_return, .branch }, "if ({s}) return error.Boom;", .{c});
        },
        7 => {
            try g.e(&.{ m, .defer_ }, "defer a.free({s});", .{x});
            try g.e(&.{ m, .alloc }, "const {s} = try mk(a, 4);", .{y});
            try g.e(&.{ m, .free }, "a.free({s});", .{y});
            try g.e(&.{ m, .free, .bug_defer_free }, "a.free({s});", .{x});
        },
        else => {
            try g.e(&.{ m, .alloc, .catch_free }, "const {s} = mk(a, 4) catch {{ a.free({s}); return; }};", .{ y, x });
            try g.e(&.{ m, .free }, "a.free({s});", .{y});
            try g.e(&.{ m, .free }, "a.free({s});", .{x});
        },
    }
    try g.close(m);
}

fn helper(g: *Gen) !void {
    const m = Tag.m_helper;
    const v = try g.v();
    const w = try g.v();
    const c = g.cond();
    try g.open(m);
    switch (g.below(14)) {
        0 => {
            try g.e(&.{ m, .alloc }, "const {s} = try mk(a, 5);", .{v});
            try g.e(&.{ m, .helper_val, .free }, "consume(a, {s});", .{v});
        },
        1 => {
            try g.e(&.{ m, .alloc }, "const {s} = try mk(a, 5);", .{v});
            try g.e(&.{ m, .helper_val, .free }, "consume(a, {s});", .{v});
            try g.e(&.{ m, .bug_helper_reuse }, "_ = rd({s});", .{v});
        },
        2 => {
            try g.e(&.{ m, .alloc }, "const {s} = try mk(a, 5);", .{v});
            try g.e(&.{ m, .helper_val, .free }, "consume(a, {s});", .{v});
            try g.e(&.{ m, .helper_val, .free, .bug_helper_twice }, "consume(a, {s});", .{v});
        },
        3 => {
            try g.e(&.{ m, .alloc }, "var {s} = try mk(a, 5);", .{v});
            try g.e(&.{ m, .helper_ptr, .free }, "freeRef(a, &{s});", .{v});
            try g.e(&.{m}, "_ = rd({s});", .{v});
        },
        4 => {
            try g.e(&.{ m, .alloc }, "var {s} = try mk(a, 5);", .{v});
            try g.e(&.{ m, .helper_ptr, .free }, "freeKeep(a, &{s});", .{v});
            try g.e(&.{ m, .bug_helper_reuse }, "_ = rd({s});", .{v});
        },
        5 => {
            try g.e(&.{ m, .alloc }, "var {s} = try mk(a, 5);", .{v});
            try g.e(&.{ m, .helper_ptr, .free }, "freeKeep(a, &{s});", .{v});
            try g.e(&.{ m, .helper_ptr, .free, .bug_helper_twice }, "freeKeep(a, &{s});", .{v});
        },
        6 => {
            try g.e(&.{ m, .alloc }, "var {s} = try mk(a, 5);", .{v});
            try g.e(&.{ m, .alias }, "var {s} = {s};", .{ w, v });
            try g.e(&.{ m, .alias_params, .helper_ptr, .free, .bug_helper_alias }, "freeBoth(a, &{s}, &{s});", .{ v, w });
        },
        7 => {
            try g.e(&.{ m, .alloc }, "var {s} = try mk(a, 5);", .{v});
            try g.e(&.{ m, .alias_params, .helper_ptr, .free, .bug_helper_alias }, "freeBoth(a, &{s}, &{s});", .{ v, v });
        },
        8 => {
            try g.e(&.{ m, .alloc }, "var {s} = try mk(a, 5);", .{v});
            try g.e(&.{ m, .alloc }, "var {s} = try mk(a, 4);", .{w});
            try g.e(&.{ m, .alias_params, .helper_ptr, .free }, "freeBoth(a, &{s}, &{s});", .{ v, w });
        },
        9 => {
            try g.e(&.{ m, .alloc }, "const {s} = try mk(a, 5);", .{v});
            try g.e(&.{ m, .helper_val, .free, .branch }, "freeIf(a, {s}, {s});", .{ v, c });
            try g.e(&.{ m, .free, .bug_cond_free }, "a.free({s});", .{v});
        },
        10 => {
            try g.e(&.{ m, .alloc }, "const {s} = try mk(a, 5);", .{v});
            try g.e(&.{ m, .helper_val, .free, .branch }, "freeIf(a, {s}, {s});", .{ v, c });
            try g.e(&.{ m, .free, .branch }, "if (!({s})) a.free({s});", .{ c, v });
        },
        11 => {
            try g.e(&.{ m, .alloc }, "var {s} = try mk(a, 5);", .{v});
            try g.e(&.{ m, .alias }, "const {s} = {s};", .{ w, v });
            try g.e(&.{ m, .helper_ptr, .alloc, .free }, "try swapIn(a, &{s});", .{v});
            try g.e(&.{ m, .bug_helper_reuse }, "_ = rd({s});", .{w});
            try g.e(&.{ m, .free }, "a.free({s});", .{v});
        },
        12 => {
            try g.e(&.{ m, .alloc }, "var {s} = try mk(a, 5);", .{v});
            try g.e(&.{ m, .helper_ptr, .alloc, .free }, "try swapIn(a, &{s});", .{v});
            try g.e(&.{ m, .free }, "a.free({s});", .{v});
        },
        else => {
            try g.e(&.{ m, .alloc }, "const {s} = try mk(a, 6);", .{v});
            try g.e(&.{ m, .alias, .subslice }, "const {s} = inner({s});", .{ w, v });
            try g.e(&.{ m, .helper_val, .free }, "consume(a, {s});", .{v});
            try g.e(&.{ m, .bug_helper_reuse, .bug_alias_uaf }, "_ = rd({s});", .{w});
        },
    }
    try g.close(m);
}

fn global(g: *Gen) !void {
    const m = Tag.m_global;
    const v = try g.v();
    try g.open(m);
    try g.e(&.{ m, .alloc }, "const {s} = try mk(a, 4);", .{v});
    switch (g.below(8)) {
        0 => {
            try g.e(&.{ m, .global }, "stash({s});", .{v});
            try g.e(&.{ m, .global, .free }, "dropStash(a);", .{});
        },
        1 => {
            try g.e(&.{ m, .global }, "stash({s});", .{v});
            try g.e(&.{ m, .free }, "a.free({s});", .{v});
            try g.e(&.{ m, .global, .bug_global_stale }, "_ = rd(g_slice);", .{});
        },
        2 => {
            try g.e(&.{ m, .global }, "stash({s});", .{v});
            try g.e(&.{ m, .global, .free }, "dropStashKeep(a);", .{});
            try g.e(&.{ m, .free, .bug_global_double }, "a.free({s});", .{v});
        },
        3 => {
            try g.e(&.{ m, .global }, "stash({s});", .{v});
            try g.e(&.{ m, .global, .free }, "dropStash(a);", .{});
            try g.e(&.{m}, "_ = rd(g_slice);", .{});
        },
        4 => {
            try g.e(&.{ m, .global, .opt_val }, "g_opt = {s};", .{v});
            try g.e(&.{ m, .free }, "a.free({s});", .{v});
            try g.e(&.{ m, .global, .opt_ptr, .bug_global_double }, "takeOpt(a, &g_opt);", .{});
        },
        5 => {
            try g.e(&.{ m, .global, .opt_val }, "g_opt = {s};", .{v});
            try g.e(&.{ m, .global, .opt_ptr, .free }, "takeOpt(a, &g_opt);", .{});
            try g.e(&.{ m, .global, .opt_ptr, .free }, "takeOpt(a, &g_opt);", .{});
        },
        6 => {
            try g.e(&.{ m, .global, .opt_val }, "g_opt = {s};", .{v});
            try g.e(&.{ m, .global, .opt_ptr, .free }, "keepOpt(a, &g_opt);", .{});
            try g.e(&.{ m, .global, .opt_ptr, .free, .bug_global_double }, "keepOpt(a, &g_opt);", .{});
        },
        else => {
            try g.e(&.{ m, .global }, "g_slice = {s};", .{v});
            try g.e(&.{ m, .free }, "a.free(g_slice);", .{});
            try g.e(&.{ m, .free, .bug_global_double }, "a.free({s});", .{v});
        },
    }
    try g.close(m);
}

fn fnptr(g: *Gen) !void {
    const m = Tag.m_fnptr;
    const v = try g.v();
    const f = try g.v();
    const h = try g.v();
    const c = g.cond();
    try g.open(m);
    try g.e(&.{ m, .alloc }, "const {s} = try mk(a, 4);", .{v});
    if (g.pct(50)) {
        try g.e(&.{ m, .fnptr, .branch }, "const {s}: FreeFn = if ({s}) &consume else &noop;", .{ f, c });
    } else {
        try g.e(&.{ m, .fnptr }, "const {s}: FreeFn = &consume;", .{f});
    }
    if (g.pct(35)) {
        try g.e(&.{ m, .fnptr, .fn_field }, "const {s}: Handler = .{{ .release = {s} }};", .{ h, f });
        try g.e(&.{ m, .fnptr, .fn_field, .free }, "{s}.release(a, {s});", .{ h, v });
    } else {
        try g.e(&.{ m, .fnptr, .free }, "{s}(a, {s});", .{ f, v });
    }
    switch (g.below(4)) {
        0 => try g.e(&.{ m, .bug_fnptr_free }, "_ = rd({s});", .{v}),
        1 => try g.e(&.{ m, .free, .bug_fnptr_free }, "a.free({s});", .{v}),
        else => {},
    }
    try g.close(m);
}

fn arenaMotif(g: *Gen) !void {
    const m = Tag.m_arena;
    const ar = try g.v();
    const s = try g.v();
    const t = try g.v();
    const l = try g.v();
    try g.open(m);
    try g.e(&.{ m, .arena }, "var {s} = std.heap.ArenaAllocator.init(a);", .{ar});
    switch (g.below(7)) {
        0 => {
            try g.e(&.{ m, .arena, .alloc }, "const {s} = try mk({s}.allocator(), 5);", .{ s, ar });
            try g.e(&.{m}, "_ = rd({s});", .{s});
            try g.e(&.{m}, "{s}.deinit();", .{ar});
        },
        1 => {
            try g.e(&.{ m, .arena, .alloc }, "const {s} = try mk({s}.allocator(), 5);", .{ s, ar });
            try g.e(&.{m}, "{s}.deinit();", .{ar});
            try g.e(&.{ m, .bug_arena_uaf }, "_ = rd({s});", .{s});
        },
        2 => {
            try g.e(&.{ m, .arena, .alloc }, "const {s} = try mk({s}.allocator(), 5);", .{ s, ar });
            try g.e(&.{m}, "_ = {s}.reset(.free_all);", .{ar});
            try g.e(&.{ m, .bug_arena_uaf }, "_ = rd({s});", .{s});
            try g.e(&.{m}, "{s}.deinit();", .{ar});
        },
        3 => {
            try g.e(&.{ m, .arena, .arena_dupe, .dupe }, "const {s} = try {s}.allocator().dupe(u8, \"hello\");", .{ t, ar });
            try g.e(&.{m}, "{s}.deinit();", .{ar});
            try g.e(&.{ m, .free, .bug_arena_foreign_free }, "a.free({s});", .{t});
        },
        4 => {
            try g.e(&.{ m, .arena, .list }, "var {s}: std.ArrayList(u8) = .empty;", .{l});
            try g.e(&.{m}, "try {s}.appendSlice({s}.allocator(), \"abcdef\");", .{ l, ar });
            try g.e(&.{m}, "_ = rd({s}.items);", .{l});
            try g.e(&.{m}, "{s}.deinit();", .{ar});
        },
        5 => {
            try g.e(&.{ m, .arena, .list }, "var {s}: std.ArrayList(u8) = .empty;", .{l});
            try g.e(&.{m}, "try {s}.appendSlice({s}.allocator(), \"abcdef\");", .{ l, ar });
            try g.e(&.{ m, .list_view }, "const {s} = {s}.items;", .{ s, l });
            try g.e(&.{m}, "{s}.deinit();", .{ar});
            try g.e(&.{ m, .bug_arena_uaf }, "_ = rd({s});", .{s});
        },
        else => {
            try g.e(&.{ m, .arena, .struct_field }, "var {s} = try Rec.init({s}.allocator(), 4);", .{ l, ar });
            try g.e(&.{m}, "_ = {s}.sum();", .{l});
            try g.e(&.{m}, "{s}.deinit({s}.allocator());", .{ l, ar });
            try g.e(&.{m}, "{s}.deinit();", .{ar});
        },
    }
    try g.close(m);
}

fn linear(g: *Gen) !void {
    const m = Tag.m_linear;
    const t = try g.v();
    const t2 = try g.v();
    const c = g.cond();
    try g.open(m);
    if (g.pct(20)) {
        try g.e(&.{ m, .linear, .linear_slice, .alloc }, "const {s} = STok.init(try mk(a, 3));", .{t});
        switch (g.below(3)) {
            0 => try g.e(&.{ m, .linear_slice, .free }, "a.free({s}.consume());", .{t}),
            1 => {
                try g.e(&.{ m, .linear_slice, .free }, "a.free({s}.consume());", .{t});
                try g.e(&.{ m, .linear_slice, .free, .bug_linear_twice }, "a.free({s}.consume());", .{t});
            },
            else => {
                try g.e(&.{ m, .linear_slice, .free }, "const {s} = {s}.consume();", .{ t2, t });
                try g.e(&.{ m, .free }, "a.free({s});", .{t2});
                try g.e(&.{ m, .bug_linear_slice }, "_ = rd({s});", .{t2});
            },
        }
        try g.close(m);
        return;
    }
    try g.e(&.{ m, .linear }, "const {s} = Tok.init({d});", .{ t, g.size() });
    switch (g.below(11)) {
        0, 1 => try g.e(&.{m}, "_ = {s}.consume();", .{t}),
        2 => {
            try g.e(&.{m}, "_ = {s}.consume();", .{t});
            try g.e(&.{ m, .bug_linear_twice }, "_ = {s}.consume();", .{t});
        },
        3 => {
            try g.e(&.{ m, .linear_copy }, "const {s} = {s};", .{ t2, t });
            try g.e(&.{m}, "_ = {s}.consume();", .{t});
            try g.e(&.{ m, .bug_linear_copy }, "_ = {s}.consume();", .{t2});
        },
        4 => try g.e(&.{ m, .bug_linear_leak }, "_ = lookTok(&{s});", .{t}),
        5 => try g.e(&.{ m, .branch, .bug_linear_leak }, "if ({s}) _ = sinkTok({s});", .{ c, t }),
        6 => {
            try g.e(&.{m}, "_ = {s}.consume();", .{t});
            try g.e(&.{ m, .bug_linear_twice }, "_ = lookTok(&{s});", .{t});
        },
        7 => try g.e(&.{m}, "_ = sinkTok({s});", .{t}),
        8 => {
            try g.e(&.{m}, "_ = sinkTok({s});", .{t});
            try g.e(&.{ m, .bug_linear_twice }, "_ = sinkTok({s});", .{t});
        },
        9 => {
            try g.e(&.{ m, .errdefer_ }, "errdefer _ = {s}.consume();", .{t});
            try g.e(&.{ m, .err_return, .branch }, "if ({s}) return error.Boom;", .{c});
            try g.e(&.{m}, "_ = {s}.consume();", .{t});
        },
        else => {
            try g.e(&.{ m, .err_return, .branch, .bug_linear_leak }, "if ({s}) return error.Boom;", .{c});
            try g.e(&.{m}, "_ = {s}.consume();", .{t});
        },
    }
    try g.close(m);
}

fn pool(g: *Gen) !void {
    const m = Tag.m_pool;
    const p = try g.v();
    const h1 = try g.v();
    const h2 = try g.v();
    const c = g.cond();
    try g.open(m);
    try g.e(&.{ m, .pool }, "var {s}: PoolT = .{{}};", .{p});
    try g.e(&.{ m, .pool }, "const {s} = try {s}.alloc(7);", .{ h1, p });
    switch (g.below(7)) {
        0, 1 => {
            try g.e(&.{m}, "{s}.get({s}).* += 1;", .{ p, h1 });
            try g.e(&.{ m, .free }, "{s}.free({s});", .{ p, h1 });
        },
        2 => {
            try g.e(&.{ m, .free }, "{s}.free({s});", .{ p, h1 });
            try g.e(&.{ m, .bug_pool_stale }, "_ = {s}.get({s}).*;", .{ p, h1 });
        },
        3 => {
            try g.e(&.{ m, .free }, "{s}.free({s});", .{ p, h1 });
            try g.e(&.{ m, .free, .bug_pool_double }, "{s}.free({s});", .{ p, h1 });
        },
        4 => {
            try g.e(&.{ m, .free }, "{s}.free({s});", .{ p, h1 });
            try g.e(&.{ m, .pool }, "const {s} = try {s}.alloc(8);", .{ h2, p });
            try g.e(&.{m}, "_ = {s}.get({s}).*;", .{ p, h2 });
            try g.e(&.{ m, .bug_pool_stale }, "_ = {s}.get({s}).*;", .{ p, h1 });
            try g.e(&.{ m, .free }, "{s}.free({s});", .{ p, h2 });
        },
        5 => {
            try g.e(&.{ m, .free, .branch, .bug_pool_stale }, "if ({s}) {s}.free({s});", .{ c, p, h1 });
            try g.e(&.{m}, "_ = {s}.get({s}).*;", .{ p, h1 });
        },
        else => {
            try g.e(&.{ m, .pool }, "const {s} = try {s}.alloc(8);", .{ h2, p });
            try g.e(&.{ m, .free }, "{s}.free({s});", .{ p, h1 });
            try g.e(&.{ m, .free }, "{s}.free({s});", .{ p, h2 });
        },
    }
    try g.close(m);
}

fn node(g: *Gen) !void {
    const m = Tag.m_node;
    const n = try g.v();
    const nd = try g.v();
    const cur = try g.v();
    try g.open(m);
    try g.e(&.{ m, .create }, "const {s} = try mkNode(a, 7, null);", .{n});
    try g.e(&.{ m, .create }, "const {s} = try mkNode(a, 8, {s});", .{ nd, n });
    switch (g.below(6)) {
        0 => {
            try g.e(&.{ m, .free }, "a.destroy({s});", .{nd});
            try g.e(&.{ m, .free }, "a.destroy({s});", .{n});
        },
        1 => {
            try g.e(&.{ m, .free }, "a.destroy({s});", .{n});
            try g.e(&.{ m, .bug_node_uaf }, "_ = rdn({s}.next.?);", .{nd});
            try g.e(&.{ m, .free }, "a.destroy({s});", .{nd});
        },
        2 => {
            try g.e(&.{ m, .loop, .free }, "var {s}: ?*Node = {s}; while ({s}) |c| {{ {s} = nextOf(c); a.destroy(c); }}", .{ cur, nd, cur, cur });
        },
        3 => {
            try g.e(&.{ m, .loop, .free, .bug_node_uaf }, "var {s}: ?*Node = {s}; while ({s}) |c| {{ a.destroy(c); {s} = nextOf(c); }}", .{ cur, nd, cur, cur });
        },
        4 => {
            try g.e(&.{ m, .free }, "a.destroy({s});", .{n});
            try g.e(&.{ m, .free, .bug_node_double }, "a.destroy({s});", .{n});
            try g.e(&.{ m, .free }, "a.destroy({s});", .{nd});
        },
        else => {
            try g.e(&.{ m, .loop, .free }, "var {s}: ?*Node = {s}; while ({s}) |c| {{ {s} = nextOf(c); a.destroy(c); }}", .{ cur, nd, cur, cur });
            try g.e(&.{ m, .free, .bug_node_double }, "a.destroy({s});", .{n});
        },
    }
    try g.close(m);
}
