//! A pack seen the way the ownership checker reads it: typed accessors over the tables, no state.

const std = @import("std");
const zv_air = @import("zv_air");
const schema = zv_air.schema;

pub const View = struct {
    pack: *const schema.Pack,

    pub fn ops(v: View, inst: *const schema.Inst) []const schema.Operand {
        return v.pack.operandsOf(inst.*);
    }

    pub fn attr(v: View, inst: *const schema.Inst, key: schema.AttrKey) ?u32 {
        for (v.pack.attrsOf(inst.*)) |a| if (a.key == key) return a.value;
        return null;
    }

    pub fn attrStr(v: View, inst: *const schema.Inst, key: schema.AttrKey) ?[]const u8 {
        const x = v.attr(inst, key) orelse return null;
        return switch (key.kind()) {
            .str => v.pack.str(@enumFromInt(x)),
            .callee => v.pack.calleeName(@enumFromInt(x)),
            else => null,
        };
    }

    pub fn ty(v: View, id: schema.TypeId) ?schema.TypeRec {
        if (id == .none) return null;
        return v.pack.t.types[@backingInt(id)];
    }

    pub fn typeName(v: View, id: schema.TypeId) []const u8 {
        return if (id == .none) "?" else v.pack.typeName(id);
    }

    pub fn bodies(v: View, inst: *const schema.Inst) []const schema.Body {
        return v.pack.bodiesOf(inst.*);
    }

    pub fn insts(v: View, body: schema.Body) []const schema.Inst {
        return v.pack.instsOf(body.insts);
    }

    pub fn constant(v: View, o: schema.Operand) schema.ConstRec {
        return v.pack.t.consts[o.value];
    }

};
