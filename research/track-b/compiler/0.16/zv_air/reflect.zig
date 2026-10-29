//! Raw AIR dump by reflection: tags, `Air.Inst.Data` fields, payload structs and the `unwrap*`
//! helpers of Air.zig are walked with @typeInfo, so there is no per-tag code. What the dump
//! cannot know (which Data field a tag uses) comes from shapes.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;

const Air = @import("../Air.zig");
const InternPool = @import("../InternPool.zig");
const Type = @import("../Type.zig");
const Value = @import("../Value.zig");
const Zcu = @import("../Zcu.zig");
const shapes = @import("shapes.zig");

pub const raw_version = 1;

const Error = Stringify.Error || Allocator.Error;

pub fn writeFunction(
    arena: Allocator,
    w: *std.Io.Writer,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    air: *const Air,
    zig_version: []const u8,
) Error!void {
    const zcu = pt.zcu;
    const ip = &zcu.intern_pool;
    const func = zcu.funcInfo(func_index);
    var c: Ctx = .{ .arena = arena, .pt = pt, .air = air };
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "raw", raw_version);
    try field(&s, "zig_version", zig_version);
    try field(&s, "generic_instance", func.generic_owner != .none);
    try s.objectField("fn");
    try c.func(&s, func_index);
    try s.objectField("ret");
    try c.typ(&s, .fromInterned(ip.funcTypeReturnType(func.ty)));
    try s.objectField("main");
    try c.body(&s, air.getMainBody());
    try s.endObject();
}

fn field(s: *Stringify, name: []const u8, value: anytype) Error!void {
    try s.objectField(name);
    try s.write(value);
}

fn idx(index: anytype) u32 {
    return @intFromEnum(index);
}

fn keepsPayload(p: shapes.Payload) bool {
    return switch (p) {
        .extra, .elements => false,
        else => true,
    };
}

const Ctx = struct {
    arena: Allocator,
    pt: Zcu.PerThread,
    air: *const Air,

    fn typ(c: *Ctx, s: *Stringify, ty: Type) Error!void {
        const zcu = c.pt.zcu;
        try s.beginObject();
        try field(s, "i", idx(ty.toIntern()));
        try field(s, "name", try std.fmt.allocPrint(c.arena, "{f}", .{ty.fmt(c.pt)}));
        try field(s, "kind", @tagName(ty.zigTypeTag(zcu)));
        try s.endObject();
    }

    fn func(c: *Ctx, s: *Stringify, func_index: InternPool.Index) Error!void {
        const zcu = c.pt.zcu;
        const ip = &zcu.intern_pool;
        const info = zcu.funcInfo(func_index);
        const file = zcu.fileByIndex(zcu.navFileScopeIndex(info.owner_nav));
        try s.beginObject();
        try field(s, "fqn", ip.getNav(info.owner_nav).fqn.toSlice(ip));
        try field(s, "module", if (file.mod) |mod| mod.fully_qualified_name else "");
        try field(s, "path", file.sub_file_path);
        try field(s, "line0", zcu.navSrcLine(info.owner_nav));
        try s.endObject();
    }

    fn interned(c: *Ctx, s: *Stringify, index: InternPool.Index) Error!void {
        const zcu = c.pt.zcu;
        const ip = &zcu.intern_pool;
        const ty: Type = .fromInterned(ip.typeOf(index));
        try s.beginObject();
        try s.objectField("ty");
        try c.typ(s, ty);
        try field(s, "val", try std.fmt.allocPrint(c.arena, "{f}", .{Value.fromInterned(index).fmtValue(c.pt)}));
        switch (ip.indexToKey(index)) {
            .func => {
                try s.objectField("fn");
                try c.func(s, index);
            },
            .@"extern" => |e| try field(s, "extern", ip.getNav(e.owner_nav).fqn.toSlice(ip)),
            else => {},
        }
        try s.endObject();
    }

    fn ref(c: *Ctx, s: *Stringify, r: Air.Inst.Ref) Error!void {
        if (r == .none) return s.write(null);
        if (r.toIndex()) |index| {
            try s.beginObject();
            try field(s, "inst", idx(index));
            return s.endObject();
        }
        try c.interned(s, r.toInterned().?);
    }

    fn body(c: *Ctx, s: *Stringify, indices: []const Air.Inst.Index) Error!void {
        try s.beginArray();
        for (indices) |index| try c.inst(s, index);
        try s.endArray();
    }

    fn switchBr(c: *Ctx, s: *Stringify, sw: anytype) Error!void {
        try s.beginObject();
        try s.objectField("operand");
        try c.ref(s, sw.operand);
        try s.objectField("cases");
        try s.beginArray();
        var it = sw.iterateCases();
        while (it.next()) |case| {
            try s.beginObject();
            try s.objectField("items");
            try c.value(s, case.items);
            try s.objectField("ranges");
            try c.value(s, case.ranges);
            try s.objectField("body");
            try c.body(s, case.body);
            try s.endObject();
        }
        try s.endArray();
        try s.objectField("else_body");
        try c.body(s, it.elseBody());
        try s.endObject();
    }

    /// Writes any value reachable from Data, payload structs and unwrap helpers.
    fn value(c: *Ctx, s: *Stringify, v: anytype) Error!void {
        const T = @TypeOf(v);
        switch (T) {
            Air.Inst.Ref => return c.ref(s, v),
            Air.Inst.Index => {
                try s.beginObject();
                try field(s, "inst", idx(v));
                return s.endObject();
            },
            Type => return c.typ(s, v),
            InternPool.Index => return c.interned(s, v),
            InternPool.Nav.Index => {
                const ip = &c.pt.zcu.intern_pool;
                return s.write(ip.getNav(v).fqn.toSlice(ip));
            },
            Air.NullTerminatedString => return s.write(v.toSlice(c.air.*)),
            else => {},
        }
        if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "iterateCases")) return c.switchBr(s, v);
        switch (@typeInfo(T)) {
            .void => try s.write(null),
            .bool, .int, .comptime_int => try s.write(v),
            .@"enum" => if (std.enums.tagName(T, v)) |name| try s.write(name) else try s.write(@intFromEnum(v)),
            .optional => if (v) |x| try c.value(s, x) else try s.write(null),
            .pointer => |p| switch (p.size) {
                .slice => if (p.child == u8) try s.write(v) else if (p.child == Air.Inst.Index) try c.body(s, v) else {
                    try s.beginArray();
                    for (v) |x| try c.value(s, x);
                    try s.endArray();
                },
                else => @compileError("raw dump: unhandled pointer field " ++ @typeName(T)),
            },
            .array => {
                try s.beginArray();
                for (v) |x| try c.value(s, x);
                try s.endArray();
            },
            .@"struct" => |info| {
                try s.beginObject();
                inline for (info.fields) |f| {
                    if (comptime std.mem.eql(u8, f.name, "_")) continue;
                    if (comptime @typeInfo(f.type) == .pointer and @typeInfo(f.type).pointer.size == .one) continue;
                    try s.objectField(f.name);
                    try c.value(s, @field(v, f.name));
                }
                inline for (@typeInfo(T).@"struct".decls) |d| {
                    if (comptime derivedMethod(T, d.name)) {
                        try s.objectField(d.name);
                        try c.value(s, @field(T, d.name)(v));
                    }
                }
                try s.endObject();
            },
            else => @compileError("raw dump: unhandled field type " ++ @typeName(T)),
        }
    }

    fn inst(c: *Ctx, s: *Stringify, index: Air.Inst.Index) Error!void {
        const air = c.air;
        const i = idx(index);
        const tag = air.instructions.items(.tag)[i];
        const data = air.instructions.items(.data)[i];
        const shape = shapes.of(tag);
        try s.beginObject();
        try field(s, "id", i);
        try field(s, "tag", @tagName(tag));
        try s.objectField("ty");
        try c.typ(s, air.typeOfIndex(index, &c.pt.zcu.intern_pool));
        if (shape.field.len == 0) {
            try field(s, "shape", null);
            const bytes = std.mem.asBytes(&data);
            try field(s, "raw", std.mem.bytesAsSlice(u32, bytes[0..8]));
            return s.endObject();
        }
        try field(s, "shape", shape.field);
        inline for (@typeInfo(Air.Inst.Data).@"union".fields) |f| {
            if (std.mem.eql(u8, f.name, shape.field)) {
                const d = @field(data, f.name);
                try s.objectField("data");
                try c.dataValue(s, d, keepsPayload(shape.payload));
                if (comptime payloadField(f.type)) switch (shape.payload) {
                    .none => {},
                    .string => {
                        const name: Air.NullTerminatedString = @enumFromInt(d.payload);
                        try field(s, "payload_str", name.toSlice(air.*));
                    },
                    .extra => |name| {
                        try s.objectField("payload");
                        try c.payload(s, name, index, d.payload);
                    },
                    .elements => if (comptime @hasField(f.type, "ty")) {
                        const len: usize = @intCast(d.ty.toType().arrayLen(c.pt.zcu));
                        const refs: []const Air.Inst.Ref = @ptrCast(air.extra.items[d.payload..][0..len]);
                        try s.objectField("payload");
                        try c.value(s, refs);
                    },
                };
            }
        }
        try s.endObject();
    }

    fn dataValue(c: *Ctx, s: *Stringify, d: anytype, keep_payload: bool) Error!void {
        const T = @TypeOf(d);
        if (comptime !payloadField(T)) return c.value(s, d);
        if (keep_payload) return c.value(s, d);
        try s.beginObject();
        inline for (@typeInfo(T).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "payload")) continue;
            try s.objectField(f.name);
            try c.value(s, @field(d, f.name));
        }
        try s.endObject();
    }

    fn payload(c: *Ctx, s: *Stringify, name: []const u8, index: Air.Inst.Index, extra_index: u32) Error!void {
        const air = c.air;
        try s.beginObject();
        try field(s, "type", name);
        try s.objectField("value");
        inline for (@typeInfo(Air).@"struct".decls) |d| {
            const decl = @field(Air, d.name);
            if (comptime @TypeOf(decl) == type and @typeInfo(decl) == .@"struct" and extraCompatible(decl)) {
                if (comptime !hasHelper(d.name)) if (std.mem.eql(u8, name, d.name)) {
                    try c.value(s, air.extraData(decl, extra_index).data);
                    return s.endObject();
                };
            }
        }
        inline for (@typeInfo(Air).@"struct".decls) |d| {
            const decl = @field(Air, d.name);
            if (comptime @typeInfo(@TypeOf(decl)) == .@"fn" and std.mem.startsWith(u8, d.name, "unwrap")) {
                const f = @typeInfo(@TypeOf(decl)).@"fn";
                if (comptime f.params.len == 2) {
                    if (comptime helperPayload(@typeName(f.return_type.?))) |p| {
                        if (std.mem.eql(u8, name, p)) {
                            try c.value(s, decl(air, index));
                            return s.endObject();
                        }
                    }
                }
            }
        }
        try s.write(null);
        try field(s, "unresolved", true);
        try s.endObject();
    }
};

/// A zero-argument method of a payload struct that returns an enum (successOrder, op, compareOperator, ...).
fn derivedMethod(comptime T: type, comptime name: []const u8) bool {
    const decl = @field(T, name);
    if (@typeInfo(@TypeOf(decl)) != .@"fn") return false;
    const f = @typeInfo(@TypeOf(decl)).@"fn";
    if (f.params.len != 1 or f.params[0].type != T) return false;
    const R = f.return_type orelse return false;
    return @typeInfo(R) == .@"enum";
}

fn payloadField(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "payload");
}

fn extraCompatible(comptime T: type) bool {
    if (@typeInfo(T).@"struct".fields.len == 0) return false;
    for (@typeInfo(T).@"struct".fields) |f| switch (f.type) {
        u32, i32, InternPool.Index, Air.Inst.Ref, Air.CondBr.BranchHints, Air.Asm.Flags => {},
        else => return false,
    };
    return true;
}

/// The payload name an `Unwrapped*` return type stands for ("UnwrappedSwitch" serves "SwitchBr").
fn helperPayload(comptime type_name: []const u8) ?[]const u8 {
    const prefix = "Unwrapped";
    const dot = std.mem.lastIndexOfScalar(u8, type_name, '.') orelse return null;
    const short = type_name[dot + 1 ..];
    if (!std.mem.startsWith(u8, short, prefix)) return null;
    const p = short[prefix.len..];
    return if (std.mem.eql(u8, p, "Switch")) "SwitchBr" else p;
}

fn hasHelper(comptime name: []const u8) bool {
    @setEvalBranchQuota(1_000_000);
    inline for (@typeInfo(Air).@"struct".decls) |d| {
        const decl = @field(Air, d.name);
        if (@typeInfo(@TypeOf(decl)) == .@"fn" and std.mem.startsWith(u8, d.name, "unwrap")) {
            const f = @typeInfo(@TypeOf(decl)).@"fn";
            if (f.params.len == 2) if (helperPayload(@typeName(f.return_type.?))) |p| {
                if (std.mem.eql(u8, p, name)) return true;
            };
        }
    }
    return false;
}
