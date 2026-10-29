//! Builds packs. The compiler makes one single-function pack per analyzed function (every table in
//! first-use order, which makes its bytes a function of the function alone) and merges them, sorted,
//! into the pack of the compilation. Both steps go through this type.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const schema = @import("schema.zig");

const StrId = schema.StrId;
const FileId = schema.FileId;
const TypeId = schema.TypeId;
const ConstId = schema.ConstId;
const CalleeId = schema.CalleeId;
const LocId = schema.LocId;
const Range = schema.Range;

pub const Error = Allocator.Error || error{TooLarge};

pub const BodySpec = struct {
    label: schema.BodyLabel,
    items: []const schema.Operand = &.{},
    ranges: []const [2]schema.Operand = &.{},
    insts: Range,
};

pub const InstSpec = struct {
    id: u32,
    tag: schema.Tag,
    ty: TypeId,
    loc: LocId = .none,
    ops: []const schema.Operand = &.{},
    attrs: []const schema.Attr = &.{},
    bodies: []const BodySpec = &.{},
};

pub const FuncSpec = struct {
    fqn: StrId,
    file: FileId,
    line: u32,
    ret: TypeId,
    generic_instance: bool,
    params: []const schema.Param,
    callees: []const schema.CalleeRef,
    insts: Range,
    unsupported: u32,
};

fn Set(comptime T: type) type {
    return std.AutoArrayHashMapUnmanaged(T, void);
}

pub const Builder = struct {
    gpa: Allocator,
    strings: std.StringArrayHashMapUnmanaged(void) = .empty,
    files: Set(schema.FileRec) = .empty,
    types: Set(schema.TypeRec) = .empty,
    consts: Set(schema.ConstRec) = .empty,
    callees: Set(StrId) = .empty,
    locs: Set(schema.LocRec) = .empty,
    params: std.ArrayList(schema.Param) = .empty,
    callee_refs: std.ArrayList(schema.CalleeRef) = .empty,
    funcs: std.ArrayList(schema.Func) = .empty,
    insts: std.ArrayList(schema.Inst) = .empty,
    operands: std.ArrayList(schema.Operand) = .empty,
    attrs: std.ArrayList(schema.Attr) = .empty,
    bodies: std.ArrayList(schema.Body) = .empty,
    fields: Set(schema.FieldRec) = .empty,

    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *Builder) void {
        for (b.strings.keys()) |key| b.gpa.free(key);
        inline for (@typeInfo(Builder).@"struct".field_names) |name| {
            if (comptime !std.mem.eql(u8, name, "gpa")) @field(b, name).deinit(b.gpa);
        }
    }

    pub fn str(b: *Builder, bytes: []const u8) Error!StrId {
        const gop = try b.strings.getOrPut(b.gpa, bytes);
        if (!gop.found_existing) {
            gop.key_ptr.* = b.gpa.dupe(u8, bytes) catch |err| {
                b.strings.orderedRemoveAt(gop.index);
                return err;
            };
        }
        return @fromBackingInt(@intCast(gop.index));
    }

    fn intern(b: *Builder, comptime field: []const u8, rec: anytype) Error!u32 {
        const gop = try @field(b, field).getOrPut(b.gpa, rec);
        return @intCast(gop.index);
    }

    pub fn file(b: *Builder, module: []const u8, path: []const u8) Error!FileId {
        return @fromBackingInt(@intCast(try b.intern("files", schema.FileRec{ .module = try b.str(module), .path = try b.str(path) })));
    }

    /// Children are interned before their parents: a type's `child` is always a smaller id.
    pub fn typeRec(b: *Builder, rec: schema.TypeRec) Error!TypeId {
        return @fromBackingInt(@intCast(try b.intern("types", rec)));
    }

    /// Records a field of `owner`. Fields may name types that are not interned yet: only `view` orders them.
    pub fn addField(b: *Builder, rec: schema.FieldRec) Error!void {
        _ = try b.intern("fields", rec);
    }

    pub fn constant(b: *Builder, rec: schema.ConstRec) Error!ConstId {
        return @fromBackingInt(@intCast(try b.intern("consts", rec)));
    }

    pub fn callee(b: *Builder, fqn: []const u8) Error!CalleeId {
        return @fromBackingInt(@intCast(try b.intern("callees", try b.str(fqn))));
    }

    pub fn loc(b: *Builder, file_id: FileId, line: u32, col: u32) Error!LocId {
        return @fromBackingInt(@intCast(try b.intern("locs", schema.LocRec{ .file = file_id, .line = line, .col = col })));
    }

    /// Claims `n` consecutive instruction records, to be filled by `set`. A body's records are reserved
    /// before any of its nested bodies', which keeps them contiguous.
    pub fn reserve(b: *Builder, n: usize) Error!Range {
        const off = b.insts.items.len;
        if (off + n > std.math.maxInt(u32)) return error.TooLarge;
        try b.insts.appendNTimes(b.gpa, std.mem.zeroes(schema.Inst), n);
        return .{ .off = @intCast(off), .len = @intCast(n) };
    }

    pub fn set(b: *Builder, slot: u32, spec: InstSpec) Error!void {
        if (spec.bodies.len > std.math.maxInt(u16) or spec.attrs.len > std.math.maxInt(u8)) return error.TooLarge;
        const ops = b.operands.items.len;
        const attrs = b.attrs.items.len;
        const bodies = b.bodies.items.len;
        try b.operands.appendSlice(b.gpa, spec.ops);
        try b.attrs.appendSlice(b.gpa, spec.attrs);
        try b.bodies.ensureUnusedCapacity(b.gpa, spec.bodies.len);
        for (spec.bodies) |body| {
            const items = b.operands.items.len;
            try b.operands.appendSlice(b.gpa, body.items);
            const ranges = b.operands.items.len;
            for (body.ranges) |pair| try b.operands.appendSlice(b.gpa, &pair);
            b.bodies.appendAssumeCapacity(.{
                .label = body.label,
                .items = .{ .off = @intCast(items), .len = @intCast(body.items.len) },
                .ranges = .{ .off = @intCast(ranges), .len = @intCast(body.ranges.len) },
                .insts = body.insts,
            });
        }
        if (b.operands.items.len > std.math.maxInt(u30)) return error.TooLarge;
        b.insts.items[slot] = .{
            .id = spec.id,
            .ty = spec.ty,
            .loc = spec.loc,
            .ops = @intCast(ops),
            .ops_len = @intCast(spec.ops.len),
            .attrs = @intCast(attrs),
            .bodies = @intCast(bodies),
            .bodies_len = @intCast(spec.bodies.len),
            .attrs_len = @intCast(spec.attrs.len),
            .tag = spec.tag,
        };
    }

    pub fn addFunc(b: *Builder, spec: FuncSpec) Error!void {
        const params = b.params.items.len;
        try b.params.appendSlice(b.gpa, spec.params);
        const callees = b.callee_refs.items.len;
        for (spec.callees) |ref| {
            const seen = for (b.callee_refs.items[callees..]) |other| {
                if (@as(u32, @bitCast(other)) == @as(u32, @bitCast(ref))) break true;
            } else false;
            if (!seen) try b.callee_refs.append(b.gpa, ref);
        }
        try b.funcs.append(b.gpa, .{
            .id = 0,
            .fqn = spec.fqn,
            .file = spec.file,
            .line = spec.line,
            .ret = spec.ret,
            .params = .{ .off = @intCast(params), .len = @intCast(spec.params.len) },
            .callees = .{ .off = @intCast(callees), .len = @intCast(b.callee_refs.items.len - callees) },
            .insts = spec.insts,
            .unsupported = spec.unsupported,
            .flags = .{ .generic_instance = spec.generic_instance },
        });
    }

    /// The pack as it stands, viewing the builder's memory. `blob` and `index` are filled in here.
    pub fn view(b: *Builder, meta: schema.Meta) Error!schema.Pack {
        var total: usize = 0;
        for (b.strings.keys()) |key| total += key.len;
        if (total > std.math.maxInt(u32)) return error.TooLarge;
        const blob = try b.gpa.alloc(u8, total);
        const index = try b.gpa.alloc(schema.StrEntry, b.strings.count());
        var off: u32 = 0;
        for (b.strings.keys(), index) |key, *entry| {
            @memcpy(blob[off..][0..key.len], key);
            entry.* = .{ .off = off, .len = @intCast(key.len) };
            off += @intCast(key.len);
        }
        return .{ .meta = meta, .t = .{
            .strings = blob,
            .str_index = index,
            .files = b.files.keys(),
            .types = b.types.keys(),
            .consts = b.consts.keys(),
            .callees = b.callees.keys(),
            .locs = b.locs.keys(),
            .params = b.params.items,
            .callee_refs = b.callee_refs.items,
            .funcs = b.funcs.items,
            .insts = b.insts.items,
            .operands = b.operands.items,
            .attrs = b.attrs.items,
            .bodies = b.bodies.items,
            .fields = try b.sortedFields(),
        } };
    }

    /// The fields by (owner, index). Two records for one position that disagree mean the pack cannot tell two
    /// types apart (same printed name): the owner then keeps only a `conflict` record.
    fn sortedFields(b: *Builder) Error![]const schema.FieldRec {
        const out = try b.gpa.dupe(schema.FieldRec, b.fields.keys());
        std.mem.sortUnstable(schema.FieldRec, out, {}, struct {
            fn lessThan(_: void, x: schema.FieldRec, y: schema.FieldRec) bool {
                if (x.owner != y.owner) return @backingInt(x.owner) < @backingInt(y.owner);
                if (x.index != y.index) return x.index < y.index;
                if (x.name != y.name) return @backingInt(x.name) < @backingInt(y.name);
                return @backingInt(x.ty) < @backingInt(y.ty);
            }
        }.lessThan);
        var len: usize = 0;
        var i: usize = 0;
        while (i < out.len) {
            var end = i;
            while (end < out.len and out[end].owner == out[i].owner) end += 1;
            var clash = false;
            for (out[i + 1 .. end], i + 1..) |rec, k| clash = clash or rec.index == out[k - 1].index;
            if (clash) {
                out[len] = .{ .owner = out[i].owner, .index = schema.FieldRec.conflict, .name = out[i].name, .ty = .none };
                len += 1;
            } else for (out[i..end]) |rec| {
                out[len] = rec;
                len += 1;
            }
            i = end;
        }
        return out[0..len];
    }

    pub const no_meta: schema.Meta = .{ .zig_version = @fromBackingInt(@intCast(0)), .target = @fromBackingInt(@intCast(0)), .root = @fromBackingInt(@intCast(0)), .optimize = .debug };

    /// Copies the single function of `p` into `b`, re-mapping every id.
    pub fn appendFunction(b: *Builder, p: schema.Pack, id: u64) Error!void {
        assert(p.t.funcs.len == 1);
        var scratch: std.heap.ArenaAllocator = .init(b.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const t = p.t;

        const strs = try arena.alloc(StrId, t.str_index.len);
        for (strs, 0..) |*slot, i| slot.* = try b.str(p.str(@fromBackingInt(@intCast(i))));
        const files = try arena.alloc(FileId, t.files.len);
        for (files, t.files) |*slot, rec| slot.* = @fromBackingInt(@intCast(try b.intern("files", schema.FileRec{
            .module = strs[@backingInt(rec.module)],
            .path = strs[@backingInt(rec.path)],
        })));
        const types = try arena.alloc(TypeId, t.types.len);
        for (types, t.types) |*slot, rec| {
            var copy = rec;
            copy.name = strs[@backingInt(rec.name)];
            if (rec.child != .none) copy.child = types[@backingInt(rec.child)];
            slot.* = try b.typeRec(copy);
        }
        for (t.fields) |rec| try b.addField(.{
            .owner = types[@backingInt(rec.owner)],
            .index = rec.index,
            .name = strs[@backingInt(rec.name)],
            .ty = if (rec.ty == .none) .none else types[@backingInt(rec.ty)],
        });
        const callees = try arena.alloc(CalleeId, t.callees.len);
        for (callees, t.callees) |*slot, name| slot.* = @fromBackingInt(@intCast(try b.intern("callees", strs[@backingInt(name)])));
        const consts = try arena.alloc(ConstId, t.consts.len);
        for (consts, t.consts) |*slot, rec| {
            var copy = rec;
            if (rec.ty != .none) copy.ty = types[@backingInt(rec.ty)];
            copy.a = switch (rec.kind) {
                .enum_literal, .enum_tag, .@"error", .text => @backingInt(strs[@intCast(rec.a)]),
                .func => @backingInt(callees[@intCast(rec.a)]),
                .type => @backingInt(types[@intCast(rec.a)]),
                else => rec.a,
            };
            slot.* = try b.constant(copy);
        }
        const locs = try arena.alloc(LocId, t.locs.len);
        for (locs, t.locs) |*slot, rec| slot.* = @fromBackingInt(@intCast(try b.intern("locs", schema.LocRec{
            .file = files[@backingInt(rec.file)],
            .line = rec.line,
            .col = rec.col,
        })));

        const base_ops: u32 = @intCast(b.operands.items.len);
        const base_attrs: u32 = @intCast(b.attrs.items.len);
        const base_bodies: u32 = @intCast(b.bodies.items.len);
        const base_insts: u32 = @intCast(b.insts.items.len);
        const base_params: u32 = @intCast(b.params.items.len);
        const base_refs: u32 = @intCast(b.callee_refs.items.len);

        try b.operands.ensureUnusedCapacity(b.gpa, t.operands.len);
        for (t.operands) |op| b.operands.appendAssumeCapacity(switch (op.kind) {
            .constant => .constant(consts[op.value]),
            else => op,
        });
        try b.attrs.ensureUnusedCapacity(b.gpa, t.attrs.len);
        for (t.attrs) |attr| {
            var copy = attr;
            copy.value = switch (attr.key.kind()) {
                .str => @backingInt(strs[attr.value]),
                .callee => @backingInt(callees[attr.value]),
                .int, .flag, .inst => attr.value,
            };
            b.attrs.appendAssumeCapacity(copy);
        }
        try b.bodies.ensureUnusedCapacity(b.gpa, t.bodies.len);
        for (t.bodies) |body| b.bodies.appendAssumeCapacity(.{
            .label = body.label,
            .items = .{ .off = body.items.off + base_ops, .len = body.items.len },
            .ranges = .{ .off = body.ranges.off + base_ops, .len = body.ranges.len },
            .insts = .{ .off = body.insts.off + base_insts, .len = body.insts.len },
        });
        try b.insts.ensureUnusedCapacity(b.gpa, t.insts.len);
        for (t.insts) |inst| {
            var copy = inst;
            if (inst.ty != .none) copy.ty = types[@backingInt(inst.ty)];
            if (inst.loc != .none) copy.loc = locs[@backingInt(inst.loc)];
            copy.ops += base_ops;
            copy.attrs += base_attrs;
            copy.bodies += base_bodies;
            b.insts.appendAssumeCapacity(copy);
        }
        try b.params.ensureUnusedCapacity(b.gpa, t.params.len);
        for (t.params) |param| b.params.appendAssumeCapacity(.{ .ty = types[@backingInt(param.ty)], .zir_index = param.zir_index });
        try b.callee_refs.ensureUnusedCapacity(b.gpa, t.callee_refs.len);
        for (t.callee_refs) |ref| b.callee_refs.appendAssumeCapacity(.{ .inlined = ref.inlined, .callee = @intCast(@backingInt(callees[ref.callee])) });
        const f = t.funcs[0];
        try b.funcs.append(b.gpa, .{
            .id = id,
            .fqn = strs[@backingInt(f.fqn)],
            .file = files[@backingInt(f.file)],
            .line = f.line,
            .ret = types[@backingInt(f.ret)],
            .params = .{ .off = f.params.off + base_params, .len = f.params.len },
            .callees = .{ .off = f.callees.off + base_refs, .len = f.callees.len },
            .insts = .{ .off = f.insts.off + base_insts, .len = f.insts.len },
            .unsupported = f.unsupported,
            .flags = f.flags,
        });
    }
};
