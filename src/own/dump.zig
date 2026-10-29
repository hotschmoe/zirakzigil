//! `zv-own --dump`: a pack's functions as compact text, for people writing or debugging cases.

const std = @import("std");
const Io = std.Io;
const zv_air = @import("zv_air");
const schema = zv_air.schema;
const View = @import("view.zig").View;

pub fn func(out: *Io.Writer, pack: *const schema.Pack, f: schema.Func) Io.Writer.Error!void {
    const v: View = .{ .pack = pack };
    try out.print("fn {s} ({d} params) -> {s}\n", .{ pack.str(f.fqn), f.params.len, v.typeName(f.ret) });
    try insts(out, v, pack.instsOf(f.insts), 1);
}

fn insts(out: *Io.Writer, v: View, list: []const schema.Inst, depth: usize) Io.Writer.Error!void {
    for (list) |*inst| {
        try out.splatByteAll(' ', depth * 2);
        try out.print("%{d} = {t}", .{ inst.id, inst.tag });
        for (v.ops(inst)) |o| switch (o.kind) {
            .none => try out.writeAll(" _"),
            .inst => try out.print(" %{d}", .{o.value}),
            .constant => {
                const c = v.constant(o);
                switch (c.kind) {
                    .int => try out.print(" {d}", .{@as(i64, @bitCast(c.a))}),
                    .bool => try out.print(" {}", .{c.a != 0}),
                    .func => try out.print(" fn:{s}", .{v.pack.calleeName(@enumFromInt(c.a))}),
                    .enum_literal, .enum_tag, .@"error", .text => try out.print(" {s}", .{v.pack.str(@enumFromInt(c.a))}),
                    else => try out.print(" <{t}>", .{c.kind}),
                }
            },
        };
        for (v.pack.attrsOf(inst.*)) |a| switch (a.key.kind()) {
            .int, .inst => try out.print(" {t}={d}", .{ a.key, a.value }),
            .str => try out.print(" {t}={s}", .{ a.key, v.pack.str(@enumFromInt(a.value)) }),
            .callee => try out.print(" {t}={s}", .{ a.key, v.pack.calleeName(@enumFromInt(a.value)) }),
            .flag => try out.print(" {t}", .{a.key}),
        };
        if (inst.ty != .none) try out.print(" : {s}", .{v.typeName(inst.ty)});
        if (inst.loc != .none) {
            const l = v.pack.t.locs[@backingInt(inst.loc)];
            try out.print("  @{d}:{d}", .{ l.line, l.col });
        }
        try out.writeByte('\n');
        for (v.bodies(inst)) |b| {
            try out.splatByteAll(' ', depth * 2 + 1);
            try out.print("[{t}", .{b.label});
            for (v.pack.t.operands[b.items.off..][0..b.items.len]) |o| try out.print(" {d}", .{o.value});
            try out.writeAll("]\n");
            try insts(out, v, v.insts(b), depth + 1);
        }
    }
}
