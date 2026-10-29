//! Symbolic values: what an AIR instruction or a memory cell holds during verification.
//! Scalars are terms; aggregates are structured so that fields stay separate. A struct's fields
//! are created on first use, so no layout is needed beyond the type of the access.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zv_air = @import("zv_air");
const schema = zv_air.schema;
const term = @import("term.zig");
const Term = term.Term;
const Sort = term.Sort;
const Pool = term.Pool;

/// A field of `owner`, a struct type: the type is how a store into a place that holds nothing yet knows what it builds.
pub const FieldStep = struct { index: u32, owner: schema.TypeId };

pub const Step = union(enum) {
    field: FieldStep,
    slice_len,
    slice_ptr,
    /// The payload of an optional.
    payload,
};

/// A pointer to part of a memory cell.
pub const Place = struct {
    cell: u32,
    path: []const Step,
};

/// `mem[off .. off + len]`.
pub const Slice = struct { mem: Term, off: Term, len: Term };

/// A many-item or element pointer: the element at `mem[off]`.
pub const ElemPtr = struct { mem: Term, off: Term };

pub const Array = struct { mem: Term, len: u64 };

pub const Field = struct { index: u32, value: Value };

pub const Obj = struct {
    base: ?[]const u8,
    fields: []const Field,
    /// The struct type, when known: it names the fields.
    ty: schema.TypeId = .none,
    /// The identity of a `zv.PointsTo` token (see `Ctx.isToken`); 0 for everything else.
    token: u32 = 0,
};

/// Finds the declared name of field `index` of a struct type, from wherever the source is.
pub const FieldNames = struct {
    context: *anyopaque,
    lookup: *const fn (context: *anyopaque, type_name: []const u8, index: u32) ?[]const u8,
};

pub const Opt = struct { has: Term, payload: Value };

pub const Eu = struct { is_err: Term, err: Term, payload: Value };

pub const Value = union(enum) {
    none,
    scalar: Term,
    slice: Slice,
    array: Array,
    elem_ptr: ElemPtr,
    place: Place,
    obj: *const Obj,
    opt: *const Opt,
    eu: *const Eu,
};

pub const IntInfo = struct { bits: u16, signed: bool };

/// A field of a symbolic struct that was created because something read it.
pub const Lazy = struct { base: []const u8, index: u32, value: Value };

pub const error_bits = 16;

/// A symbolic input worth printing in a counterexample.
pub const Input = struct {
    name: []const u8,
    kind: union(enum) {
        int: struct { term: Term, signed: bool },
        bool: Term,
        slice: struct { len: Term, mem: Term, signed: bool, bits: u16 },
        array: struct { mem: Term, len: u64, signed: bool },
    },
};

pub const Error = Allocator.Error || error{Unsupported};

pub const Ctx = struct {
    pool: *Pool,
    pack: *const schema.Pack,
    arena: Allocator,
    inputs: std.ArrayList(Input) = .empty,
    lazy: std.ArrayList(Lazy) = .empty,
    reason: []const u8 = "",
    /// Prefixed to the name of every input variable, so functions sharing a pool never share a variable.
    prefix: []const u8 = "",
    field_names: ?FieldNames = null,
    /// Tokens named so far, by the variable that stands for them: a token read twice is one token.
    token_names: std.StringHashMapUnmanaged(u32) = .empty,
    tokens: u32 = 0,

    pub fn unsupported(c: *Ctx, comptime fmt: []const u8, args: anytype) error{Unsupported} {
        c.reason = std.fmt.allocPrint(c.arena, fmt, args) catch "out of memory";
        return error.Unsupported;
    }

    pub fn named(c: *Ctx, name: []const u8, sort: Sort) Allocator.Error!Term {
        if (c.prefix.len == 0) return c.pool.variable(name, sort);
        return c.pool.variable(try std.fmt.allocPrint(c.arena, "{s}{s}", .{ c.prefix, name }), sort);
    }

    pub fn typeRec(c: *const Ctx, id: schema.TypeId) schema.TypeRec {
        return c.pack.t.types[@backingInt(id)];
    }

    pub fn intInfo(c: *const Ctx, id: schema.TypeId) ?IntInfo {
        if (id == .none) return null;
        const t = c.typeRec(id);
        if (t.kind != .int or t.bits == 0 or t.bits > 128) return null;
        return .{ .bits = t.bits, .signed = t.flags.signed };
    }

    pub fn scalarSort(c: *const Ctx, id: schema.TypeId) ?Sort {
        if (id == .none) return null;
        const t = c.typeRec(id);
        return switch (t.kind) {
            .bool => .bool,
            .int => if (c.intInfo(id)) |i| .{ .bv = i.bits } else null,
            else => null,
        };
    }

    pub fn typeName(c: *const Ctx, id: schema.TypeId) []const u8 {
        return c.pack.typeName(id);
    }

    /// Whether `id` is `zv.PointsTo`: a permission token, linear and built only by its own operations.
    pub fn isToken(c: *const Ctx, id: schema.TypeId) bool {
        return id != .none and std.mem.eql(u8, c.typeName(id), zv_air.tokens.type_name);
    }

    pub fn newToken(c: *Ctx) u32 {
        c.tokens += 1;
        return c.tokens;
    }

    /// The token that the variable `name` stands for.
    fn tokenNamed(c: *Ctx, name: []const u8) Allocator.Error!u32 {
        const entry = try c.token_names.getOrPut(c.arena, name);
        if (!entry.found_existing) entry.value_ptr.* = c.newToken();
        return entry.value_ptr.*;
    }

    pub fn create(c: *Ctx, comptime T: type, v: T) Allocator.Error!*const T {
        const p = try c.arena.create(T);
        p.* = v;
        return p;
    }

    /// An unconstrained value of type `id`. `record` adds the scalars to the counterexample inputs.
    pub fn symbolic(c: *Ctx, name: []const u8, id: schema.TypeId, record: bool) Error!Value {
        return c.symbolicShown(name, name, id, record);
    }

    fn addInput(c: *Ctx, input: Input) Allocator.Error!void {
        for (c.inputs.items) |x| if (std.mem.eql(u8, x.name, input.name)) return;
        try c.inputs.append(c.arena, input);
    }

    /// `name` names the variables; `shown` is what a counterexample calls them.
    fn symbolicShown(c: *Ctx, name: []const u8, shown: []const u8, id: schema.TypeId, record: bool) Error!Value {
        const t = c.typeRec(id);
        switch (t.kind) {
            .bool => {
                const v = try c.named(name, .bool);
                if (record) try c.addInput(.{ .name = shown, .kind = .{ .bool = v } });
                return .{ .scalar = v };
            },
            .int => {
                const info = c.intInfo(id) orelse return c.unsupported("integer type {s}", .{c.typeName(id)});
                const v = try c.named(name, .{ .bv = info.bits });
                if (record) try c.addInput(.{ .name = shown, .kind = .{ .int = .{ .term = v, .signed = info.signed } } });
                return .{ .scalar = v };
            },
            .pointer => {
                if (t.flags.size != .slice) return c.unsupported("pointer type {s}", .{c.typeName(id)});
                const elem = c.intInfo(t.child) orelse return c.unsupported("slice of {s}", .{c.typeName(t.child)});
                const len = try c.named(try std.fmt.allocPrint(c.arena, "{s}.len", .{name}), .{ .bv = 64 });
                const mem = try c.named(try std.fmt.allocPrint(c.arena, "{s}.mem", .{name}), .{ .array = .{ .idx = 64, .elem = elem.bits } });
                if (record) try c.addInput(.{ .name = shown, .kind = .{ .slice = .{ .len = len, .mem = mem, .signed = elem.signed, .bits = elem.bits } } });
                return .{ .slice = .{ .mem = mem, .off = try c.pool.bv(64, 0), .len = len } };
            },
            .array => {
                const elem = c.intInfo(t.child) orelse return c.unsupported("array of {s}", .{c.typeName(t.child)});
                const mem = try c.named(try std.fmt.allocPrint(c.arena, "{s}.mem", .{name}), .{ .array = .{ .idx = 64, .elem = elem.bits } });
                if (record) try c.addInput(.{ .name = shown, .kind = .{ .array = .{ .mem = mem, .len = t.len, .signed = elem.signed } } });
                return .{ .array = .{ .mem = mem, .len = t.len } };
            },
            .optional => {
                const has = try c.named(try std.fmt.allocPrint(c.arena, "{s}.has", .{name}), .bool);
                if (record) try c.addInput(.{ .name = try std.fmt.allocPrint(c.arena, "{s}.has", .{shown}), .kind = .{ .bool = has } });
                const payload = try c.symbolicShown(try std.fmt.allocPrint(c.arena, "{s}.val", .{name}), try std.fmt.allocPrint(c.arena, "{s}.val", .{shown}), t.child, record);
                return .{ .opt = try c.create(Opt, .{ .has = has, .payload = payload }) };
            },
            .error_union => {
                const is_err = try c.named(try std.fmt.allocPrint(c.arena, "{s}.is_err", .{name}), .bool);
                if (record) try c.addInput(.{ .name = try std.fmt.allocPrint(c.arena, "{s}.is_err", .{shown}), .kind = .{ .bool = is_err } });
                const err = try c.named(try std.fmt.allocPrint(c.arena, "{s}.err", .{name}), .{ .bv = error_bits });
                const payload: Value = if (c.typeRec(t.child).kind == .void) .none else try c.symbolicShown(try std.fmt.allocPrint(c.arena, "{s}.val", .{name}), try std.fmt.allocPrint(c.arena, "{s}.val", .{shown}), t.child, record);
                return .{ .eu = try c.create(Eu, .{ .is_err = is_err, .err = err, .payload = payload }) };
            },
            .@"struct" => return .{ .obj = try c.create(Obj, .{ .base = name, .fields = &.{}, .ty = id, .token = if (c.isToken(id)) try c.tokenNamed(name) else 0 }) },
            .void => return .none,
            else => return c.unsupported("type {s} ({t})", .{ c.typeName(id), t.kind }),
        }
    }

    /// The same shape as `like` with unconstrained contents.
    pub fn havoc(c: *Ctx, name: []const u8, like: Value) Error!Value {
        const p = c.pool;
        switch (like) {
            .none => return .none,
            .scalar => |t| return .{ .scalar = try p.fresh(name, p.sortOf(t)) },
            .slice => |s| return .{ .slice = .{
                .mem = try p.fresh(name, p.sortOf(s.mem)),
                .off = try p.bv(64, 0),
                .len = try p.fresh(name, .{ .bv = 64 }),
            } },
            .array => |a| return .{ .array = .{ .mem = try p.fresh(name, p.sortOf(a.mem)), .len = a.len } },
            .elem_ptr, .place => return c.unsupported("a pointer changes inside a loop", .{}),
            .obj => |o| {
                const fresh_name = try std.fmt.allocPrint(c.arena, "{s}!{d}", .{ name, p.fresh_count });
                p.fresh_count += 1;
                return .{ .obj = try c.create(Obj, .{ .base = fresh_name, .fields = &.{}, .token = if (o.token != 0) try c.tokenNamed(fresh_name) else 0 }) };
            },
            .opt => |o| return .{ .opt = try c.create(Opt, .{ .has = try p.fresh(name, .bool), .payload = try c.havoc(name, o.payload) }) },
            .eu => |e| return .{ .eu = try c.create(Eu, .{
                .is_err = try p.fresh(name, .bool),
                .err = try p.fresh(name, .{ .bv = error_bits }),
                .payload = try c.havoc(name, e.payload),
            }) },
        }
    }

    pub fn field(c: *Ctx, o: *const Obj, index: u32, like: ?schema.TypeId) Error!Value {
        for (o.fields) |f| if (f.index == index) return f.value;
        const base = o.base orelse return c.unsupported("field {d} of an aggregate that never set it", .{index});
        const ty = like orelse return c.unsupported("field {d} read without a type", .{index});
        const name = try std.fmt.allocPrint(c.arena, "{s}.{d}", .{ base, index });
        const shown = try c.shownName(o, base, index);
        const made = try c.symbolicShown(name, shown, ty, std.mem.indexOfScalar(u8, base, '!') == null);
        try c.lazy.append(c.arena, .{ .base = base, .index = index, .value = made });
        return made;
    }

    fn shownName(c: *Ctx, o: *const Obj, base: []const u8, index: u32) Allocator.Error![]const u8 {
        if (c.field_names) |h| if (o.ty != .none) if (h.lookup(h.context, c.typeName(o.ty), index)) |field_name|
            return std.fmt.allocPrint(c.arena, "{s}.{s}", .{ base, field_name });
        return std.fmt.allocPrint(c.arena, "{s}.{d}", .{ base, index });
    }

    /// Field `index` of `o`; one that nothing set is a symbolic value of the shape of `like`.
    pub fn fieldShaped(c: *Ctx, o: *const Obj, index: u32, like: Value) Error!Value {
        for (o.fields) |f| if (f.index == index) return f.value;
        const base = o.base orelse return c.unsupported("field {d} of an aggregate that never set it", .{index});
        const made = try c.havocNamed(try std.fmt.allocPrint(c.arena, "{s}.{d}", .{ base, index }), like);
        try c.lazy.append(c.arena, .{ .base = base, .index = index, .value = made });
        return made;
    }

    pub fn withField(c: *Ctx, o: *const Obj, index: u32, v: Value) Allocator.Error!Value {
        const fields = try c.arena.alloc(Field, o.fields.len + @intFromBool(c.find(o, index) == null));
        var n: usize = 0;
        var placed = false;
        for (o.fields) |f| {
            if (!placed and f.index > index) {
                fields[n] = .{ .index = index, .value = v };
                n += 1;
                placed = true;
            }
            if (f.index == index) {
                fields[n] = .{ .index = index, .value = v };
                placed = true;
            } else fields[n] = f;
            n += 1;
        }
        if (!placed) fields[n] = .{ .index = index, .value = v };
        return .{ .obj = try c.create(Obj, .{ .base = o.base, .fields = fields, .ty = o.ty, .token = o.token }) };
    }

    fn find(_: *Ctx, o: *const Obj, index: u32) ?usize {
        for (o.fields, 0..) |f, i| if (f.index == index) return i;
        return null;
    }

    /// `if cond then a else b`, structurally.
    pub fn merge(c: *Ctx, cond: Term, a: Value, b: Value) Error!Value {
        const p = c.pool;
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
            if (a == .none) return b;
            if (b == .none) return a;
            return c.unsupported("a join of different kinds of value ({t} and {t})", .{ std.meta.activeTag(a), std.meta.activeTag(b) });
        }
        switch (a) {
            .none => return .none,
            .scalar => |x| return .{ .scalar = try p.ite(cond, x, b.scalar) },
            .slice => |x| return .{ .slice = .{
                .mem = try p.ite(cond, x.mem, b.slice.mem),
                .off = try p.ite(cond, x.off, b.slice.off),
                .len = try p.ite(cond, x.len, b.slice.len),
            } },
            .array => |x| return .{ .array = .{ .mem = try p.ite(cond, x.mem, b.array.mem), .len = x.len } },
            .elem_ptr => |x| return .{ .elem_ptr = .{ .mem = try p.ite(cond, x.mem, b.elem_ptr.mem), .off = try p.ite(cond, x.off, b.elem_ptr.off) } },
            .place => |x| {
                const y = b.place;
                if (x.cell == y.cell and std.meta.eql(x.path, y.path)) return a;
                if (x.cell == y.cell and x.path.len == y.path.len) {
                    for (x.path, y.path) |s, t| if (!std.meta.eql(s, t)) return c.unsupported("a join of pointers to different places", .{});
                    return a;
                }
                return c.unsupported("a join of pointers to different places", .{});
            },
            .obj => |x| {
                const y = b.obj;
                if (x == y) return a;
                if (x.token != y.token) return c.unsupported("a join of different tokens", .{});
                const same_base = if (x.base) |xb| (if (y.base) |yb| std.mem.eql(u8, xb, yb) else false) else y.base == null;
                if (!same_base) return c.unsupported("a join of structs with different origins", .{});
                var fields: std.ArrayList(Field) = .empty;
                var indexes: std.ArrayList(u32) = .empty;
                for (x.fields) |f| try indexes.append(c.arena, f.index);
                for (y.fields) |f| if (std.mem.indexOfScalar(u32, indexes.items, f.index) == null) try indexes.append(c.arena, f.index);
                std.mem.sort(u32, indexes.items, {}, std.sort.asc(u32));
                for (indexes.items) |i| {
                    const xv = try c.fieldLike(x, i, y);
                    const yv = try c.fieldLike(y, i, x);
                    try fields.append(c.arena, .{ .index = i, .value = try c.merge(cond, xv, yv) });
                }
                return .{ .obj = try c.create(Obj, .{ .base = x.base, .fields = fields.items, .ty = x.ty, .token = x.token }) };
            },
            .opt => |x| return .{ .opt = try c.create(Opt, .{
                .has = try p.ite(cond, x.has, b.opt.has),
                .payload = try c.merge(cond, x.payload, b.opt.payload),
            }) },
            .eu => |x| return .{ .eu = try c.create(Eu, .{
                .is_err = try p.ite(cond, x.is_err, b.eu.is_err),
                .err = try p.ite(cond, x.err, b.eu.err),
                .payload = try c.merge(cond, x.payload, b.eu.payload),
            }) },
        }
    }

    /// Field `i` of `o`, or, when only the other side set it, the base's symbolic field of its shape.
    fn fieldLike(c: *Ctx, o: *const Obj, i: u32, other: *const Obj) Error!Value {
        for (o.fields) |f| if (f.index == i) return f.value;
        const base = o.base orelse return c.unsupported("a join where one struct lacks field {d}", .{i});
        const other_value = for (other.fields) |f| {
            if (f.index == i) break f.value;
        } else return c.unsupported("a join where a struct lacks field {d}", .{i});
        return c.havocNamed(try std.fmt.allocPrint(c.arena, "{s}.{d}", .{ base, i }), other_value);
    }

    /// Like `havoc`, but the variables are the named ones, so repeated reads agree.
    pub fn havocNamed(c: *Ctx, name: []const u8, like: Value) Error!Value {
        const p = c.pool;
        switch (like) {
            .none => return .none,
            .scalar => |t| return .{ .scalar = try c.named(name, p.sortOf(t)) },
            .opt => |o| return .{ .opt = try c.create(Opt, .{
                .has = try c.named(try std.fmt.allocPrint(c.arena, "{s}.has", .{name}), .bool),
                .payload = try c.havocNamed(try std.fmt.allocPrint(c.arena, "{s}.val", .{name}), o.payload),
            }) },
            .obj => |o| return .{ .obj = try c.create(Obj, .{ .base = name, .fields = &.{}, .token = if (o.token != 0) try c.tokenNamed(name) else 0 }) },
            else => return c.unsupported("a join where one struct lacks a field of this kind", .{}),
        }
    }
};
