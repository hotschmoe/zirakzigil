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

pub const Step = union(enum) {
    field: u32,
    slice_len,
    slice_ptr,
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
    reason: []const u8 = "",

    pub fn unsupported(c: *Ctx, comptime fmt: []const u8, args: anytype) error{Unsupported} {
        c.reason = std.fmt.allocPrint(c.arena, fmt, args) catch "out of memory";
        return error.Unsupported;
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

    pub fn create(c: *Ctx, comptime T: type, v: T) Allocator.Error!*const T {
        const p = try c.arena.create(T);
        p.* = v;
        return p;
    }

    /// An unconstrained value of type `id`. `record` adds the scalars to the counterexample inputs.
    pub fn symbolic(c: *Ctx, name: []const u8, id: schema.TypeId, record: bool) Error!Value {
        const t = c.typeRec(id);
        switch (t.kind) {
            .bool => {
                const v = try c.pool.variable(name, .bool);
                if (record) try c.inputs.append(c.arena, .{ .name = name, .kind = .{ .bool = v } });
                return .{ .scalar = v };
            },
            .int => {
                const info = c.intInfo(id) orelse return c.unsupported("integer type {s}", .{c.typeName(id)});
                const v = try c.pool.variable(name, .{ .bv = info.bits });
                if (record) try c.inputs.append(c.arena, .{ .name = name, .kind = .{ .int = .{ .term = v, .signed = info.signed } } });
                return .{ .scalar = v };
            },
            .pointer => {
                if (t.flags.size != .slice) return c.unsupported("pointer type {s}", .{c.typeName(id)});
                const elem = c.intInfo(t.child) orelse return c.unsupported("slice of {s}", .{c.typeName(t.child)});
                const len = try c.pool.variable(try std.fmt.allocPrint(c.arena, "{s}.len", .{name}), .{ .bv = 64 });
                const mem = try c.pool.variable(try std.fmt.allocPrint(c.arena, "{s}.mem", .{name}), .{ .array = .{ .idx = 64, .elem = elem.bits } });
                if (record) try c.inputs.append(c.arena, .{ .name = name, .kind = .{ .slice = .{ .len = len, .mem = mem, .signed = elem.signed, .bits = elem.bits } } });
                return .{ .slice = .{ .mem = mem, .off = try c.pool.bv(64, 0), .len = len } };
            },
            .array => {
                const elem = c.intInfo(t.child) orelse return c.unsupported("array of {s}", .{c.typeName(t.child)});
                const mem = try c.pool.variable(try std.fmt.allocPrint(c.arena, "{s}.mem", .{name}), .{ .array = .{ .idx = 64, .elem = elem.bits } });
                if (record) try c.inputs.append(c.arena, .{ .name = name, .kind = .{ .array = .{ .mem = mem, .len = t.len, .signed = elem.signed } } });
                return .{ .array = .{ .mem = mem, .len = t.len } };
            },
            .optional => {
                const has = try c.pool.variable(try std.fmt.allocPrint(c.arena, "{s}.has", .{name}), .bool);
                if (record) try c.inputs.append(c.arena, .{ .name = try std.fmt.allocPrint(c.arena, "{s}.has", .{name}), .kind = .{ .bool = has } });
                const payload = try c.symbolic(try std.fmt.allocPrint(c.arena, "{s}.val", .{name}), t.child, record);
                return .{ .opt = try c.create(Opt, .{ .has = has, .payload = payload }) };
            },
            .error_union => {
                const is_err = try c.pool.variable(try std.fmt.allocPrint(c.arena, "{s}.is_err", .{name}), .bool);
                if (record) try c.inputs.append(c.arena, .{ .name = try std.fmt.allocPrint(c.arena, "{s}.is_err", .{name}), .kind = .{ .bool = is_err } });
                const err = try c.pool.variable(try std.fmt.allocPrint(c.arena, "{s}.err", .{name}), .{ .bv = error_bits });
                const payload: Value = if (c.typeRec(t.child).kind == .void) .none else try c.symbolic(try std.fmt.allocPrint(c.arena, "{s}.val", .{name}), t.child, record);
                return .{ .eu = try c.create(Eu, .{ .is_err = is_err, .err = err, .payload = payload }) };
            },
            .@"struct" => return .{ .obj = try c.create(Obj, .{ .base = name, .fields = &.{} }) },
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
            .obj => {
                const fresh_name = try std.fmt.allocPrint(c.arena, "{s}!{d}", .{ name, p.fresh_count });
                p.fresh_count += 1;
                return .{ .obj = try c.create(Obj, .{ .base = fresh_name, .fields = &.{} }) };
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
        return c.symbolic(name, ty, o.base != null and std.mem.indexOfScalar(u8, base, '!') == null);
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
        return .{ .obj = try c.create(Obj, .{ .base = o.base, .fields = fields }) };
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
                return .{ .obj = try c.create(Obj, .{ .base = x.base, .fields = fields.items }) };
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
    fn havocNamed(c: *Ctx, name: []const u8, like: Value) Error!Value {
        const p = c.pool;
        switch (like) {
            .none => return .none,
            .scalar => |t| return .{ .scalar = try p.variable(name, p.sortOf(t)) },
            .opt => |o| return .{ .opt = try c.create(Opt, .{
                .has = try p.variable(try std.fmt.allocPrint(c.arena, "{s}.has", .{name}), .bool),
                .payload = try c.havocNamed(try std.fmt.allocPrint(c.arena, "{s}.val", .{name}), o.payload),
            }) },
            .obj => return .{ .obj = try c.create(Obj, .{ .base = name, .fields = &.{} }) },
            else => return c.unsupported("a join where one struct lacks a field of this kind", .{}),
        }
    }
};
