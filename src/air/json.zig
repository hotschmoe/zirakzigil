//! The JSON form of a pack: readable debug and agent output, generated from the same tables as the
//! binary form. Ids stay ids (index into `files`, `types`, `callees`); constants are inlined.

const std = @import("std");
const Stringify = std.json.Stringify;
const schema = @import("schema.zig");

const Pack = schema.Pack;

pub const Options = struct {
    pretty: bool = false,
    /// Only functions whose name contains this.
    filter: ?[]const u8 = null,
};

pub fn write(w: *std.Io.Writer, p: Pack, options: Options) Stringify.Error!void {
    var s: Stringify = .{ .writer = w, .options = .{ .whitespace = if (options.pretty) .indent_1 else .minified } };
    try s.beginObject();
    try field(&s, "schema", schema.version);
    try field(&s, "zig_version", p.str(p.meta.zig_version));
    try field(&s, "target", p.str(p.meta.target));
    try field(&s, "optimize", @tagName(p.meta.optimize));
    try field(&s, "root", p.str(p.meta.root));

    try s.objectField("files");
    try s.beginArray();
    for (p.t.files) |f| try s.write(.{ .module = p.str(f.module), .path = p.str(f.path) });
    try s.endArray();

    try s.objectField("types");
    try s.beginArray();
    for (p.t.types) |ty| try writeType(&s, p, ty);
    try s.endArray();

    try s.objectField("callees");
    try s.beginArray();
    for (p.t.callees) |name| try s.write(p.str(name));
    try s.endArray();

    try s.objectField("functions");
    try s.beginArray();
    for (p.t.funcs) |f| {
        if (options.filter) |needle| if (std.mem.indexOf(u8, p.str(f.fqn), needle) == null) continue;
        try writeFunc(&s, p, f);
    }
    try s.endArray();
    try s.endObject();
}

fn field(s: *Stringify, name: []const u8, value: anytype) Stringify.Error!void {
    try s.objectField(name);
    try s.write(value);
}

fn writeType(s: *Stringify, p: Pack, ty: schema.TypeRec) Stringify.Error!void {
    try s.beginObject();
    try field(s, "name", p.str(ty.name));
    try field(s, "kind", @tagName(ty.kind));
    if (ty.child != .none) try field(s, "child", @backingInt(ty.child));
    switch (ty.kind) {
        .int => {
            try field(s, "bits", ty.bits);
            try field(s, "signed", ty.flags.signed);
        },
        .float => try field(s, "bits", ty.bits),
        .array, .vector => try field(s, "len", ty.len),
        .pointer => {
            try field(s, "size", @tagName(ty.flags.size));
            if (ty.flags.is_const) try field(s, "const", true);
            if (ty.flags.is_volatile) try field(s, "volatile", true);
            if (ty.flags.allow_zero) try field(s, "allowzero", true);
        },
        else => {},
    }
    try s.endObject();
}

fn writeFunc(s: *Stringify, p: Pack, f: schema.Func) Stringify.Error!void {
    try s.beginObject();
    try field(s, "fqn", p.str(f.fqn));
    try s.objectField("id");
    try s.print("\"{x:0>16}\"", .{f.id});
    try field(s, "file", @backingInt(f.file));
    try field(s, "line", f.line);
    try field(s, "generic_instance", f.flags.generic_instance);
    try s.objectField("params");
    try s.beginArray();
    for (p.paramsOf(f)) |param| try s.write(.{ .ty = @backingInt(param.ty), .zir_index = param.zir_index });
    try s.endArray();
    try field(s, "ret", @backingInt(f.ret));
    try field(s, "unsupported", f.unsupported);
    try s.objectField("callees");
    try s.beginArray();
    for (p.calleeRefsOf(f)) |ref| try s.write(.{ .callee = ref.callee, .inlined = ref.inlined });
    try s.endArray();
    try s.objectField("insts");
    try writeInsts(s, p, p.instsOf(f.insts));
    try s.endObject();
}

fn writeInsts(s: *Stringify, p: Pack, insts: []const schema.Inst) Stringify.Error!void {
    try s.beginArray();
    for (insts) |inst| try writeInst(s, p, inst);
    try s.endArray();
}

fn writeOperand(s: *Stringify, p: Pack, op: schema.Operand) Stringify.Error!void {
    switch (op.kind) {
        .none => try s.write(null),
        .inst => try s.write(.{ .inst = op.value }),
        .constant => try writeConst(s, p, p.t.consts[op.value]),
    }
}

fn writeOperands(s: *Stringify, p: Pack, ops: []const schema.Operand) Stringify.Error!void {
    try s.beginArray();
    for (ops) |op| try writeOperand(s, p, op);
    try s.endArray();
}

fn writeConst(s: *Stringify, p: Pack, c: schema.ConstRec) Stringify.Error!void {
    try s.beginObject();
    try field(s, "ty", @backingInt(c.ty));
    try field(s, "kind", @tagName(c.kind));
    switch (c.kind) {
        .undef, .void, .null => {},
        .bool => try field(s, "val", c.a != 0),
        .int => {
            const ty = p.t.types[@backingInt(c.ty)];
            const signed = ty.flags.signed or ty.kind == .comptime_int;
            if (signed) try field(s, "val", @as(i64, @bitCast(c.a))) else try field(s, "val", c.a);
        },
        .float => {
            try s.objectField("val");
            try s.print("\"0x{x:0>16}\"", .{c.a});
        },
        .enum_literal, .enum_tag, .@"error", .text => try field(s, "val", p.str(@fromBackingInt(@intCast(c.a)))),
        .func => try field(s, "val", p.calleeName(@fromBackingInt(@intCast(c.a)))),
        .type => try field(s, "val", c.a),
    }
    try s.endObject();
}

fn writeInst(s: *Stringify, p: Pack, inst: schema.Inst) Stringify.Error!void {
    try s.beginObject();
    try field(s, "id", inst.id);
    try field(s, "tag", @tagName(inst.tag));
    if (inst.ty == .none) {
        try field(s, "unsupported", true);
        return s.endObject();
    }
    try field(s, "ty", @backingInt(inst.ty));
    if (inst.ops_len != 0) {
        try s.objectField("operands");
        try writeOperands(s, p, p.operandsOf(inst));
    }
    if (inst.attrs_len != 0) {
        try s.objectField("attrs");
        try s.beginObject();
        for (p.attrsOf(inst)) |attr| {
            try s.objectField(@tagName(attr.key));
            switch (attr.key.kind()) {
                .int, .inst => try s.write(attr.value),
                .str => try s.write(p.str(@fromBackingInt(@intCast(attr.value)))),
                .flag => try s.write(attr.value != 0),
                .callee => try s.write(p.calleeName(@fromBackingInt(@intCast(attr.value)))),
            }
        }
        try s.endObject();
    }
    if (inst.loc != .none) {
        const loc = p.t.locs[@backingInt(inst.loc)];
        try field(s, "loc", .{ @backingInt(loc.file), loc.line, loc.col });
    }
    if (inst.bodies_len != 0) {
        try s.objectField("bodies");
        try s.beginArray();
        for (p.bodiesOf(inst)) |body| {
            try s.beginObject();
            try field(s, "label", @tagName(body.label));
            if (body.items.len != 0) {
                try s.objectField("items");
                try writeOperands(s, p, p.t.operands[body.items.off..][0..body.items.len]);
            }
            if (body.ranges.len != 0) {
                try s.objectField("ranges");
                try s.beginArray();
                const pairs = p.t.operands[body.ranges.off..][0 .. body.ranges.len * 2];
                var i: usize = 0;
                while (i < pairs.len) : (i += 2) try writeOperands(s, p, pairs[i..][0..2]);
                try s.endArray();
            }
            try s.objectField("insts");
            try writeInsts(s, p, p.instsOf(body.insts));
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
}
