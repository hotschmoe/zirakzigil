//! Writes one JSON file per analyzed function (schema v1, see docs/phase1.md).
//! The compiler calls `exportFunc` once the function's AIR is final.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;

const Air = @import("../Air.zig");
const InternPool = @import("../InternPool.zig");
const Zcu = @import("../Zcu.zig");
const adapter = @import("adapter.zig");
const cache = @import("cache.zig");

pub const schema_version = 1;

pub fn exportFunc(pt: Zcu.PerThread, func_index: InternPool.Index, air: *const Air) Allocator.Error!void {
    const zcu = pt.zcu;
    const comp = zcu.comp;
    const o = cache.options(comp) orelse return;
    if ((!o.include_std and adapter.isToolchain(zcu, func_index)) or adapter.isBuildScript(zcu)) return;

    var arena_state: std.heap.ArenaAllocator = .init(comp.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const function = try adapter.view(arena, zcu, func_index, air);
    var aw: std.Io.Writer.Allocating = .init(arena);
    writeFunction(&aw.writer, function) catch return error.OutOfMemory;

    const io = comp.io;
    const target = cache.target(comp, o);
    target.dir.createDirPath(io, target.sub_path) catch |err|
        std.process.fatal("zv_air: {s}: {t}", .{ target.sub_path, err });
    const sub_path = try std.fs.path.join(arena, &.{ target.sub_path, try fileName(arena, function.fqn, aw.written()) });
    target.dir.writeFile(io, .{ .sub_path = sub_path, .data = aw.written() }) catch |err|
        std.process.fatal("zv_air: {s}: {t}", .{ sub_path, err });
}

/// The name embeds a hash of the content, so generic instances that share a
/// name stay apart and re-exports of identical content overwrite each other.
fn fileName(arena: Allocator, fqn: []const u8, content: []const u8) Allocator.Error![]const u8 {
    const stem = try arena.dupe(u8, fqn[0..@min(fqn.len, 80)]);
    for (stem) |*byte| switch (byte.*) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '-' => {},
        else => byte.* = '_',
    };
    return std.fmt.allocPrint(arena, "{s}.{x:0>16}.json", .{ stem, std.hash.Wyhash.hash(0, content) });
}

pub fn writeFunction(w: *std.Io.Writer, f: adapter.Function) std.Io.Writer.Error!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "schema", schema_version);
    try field(&s, "zig_version", builtin.zig_version_string);
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

fn field(s: *Stringify, name: []const u8, value: anytype) Stringify.Error!void {
    try s.objectField(name);
    try s.write(value);
}

fn writeInsts(s: *Stringify, insts: []const adapter.Inst) Stringify.Error!void {
    try s.beginArray();
    for (insts) |inst| try writeInst(s, inst);
    try s.endArray();
}

fn writeOperands(s: *Stringify, operands: []const adapter.Operand) Stringify.Error!void {
    try s.beginArray();
    for (operands) |operand| switch (operand) {
        .none => try s.write(null),
        .inst => |id| try s.write(.{ .inst = id }),
        .constant => |c| try s.write(.{ .ty = c.ty, .val = c.val }),
    };
    try s.endArray();
}

fn writeInst(s: *Stringify, inst: adapter.Inst) Stringify.Error!void {
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
        for (inst.bodies) |body| {
            try s.beginObject();
            try field(s, "label", body.label);
            if (body.items.len != 0) {
                try s.objectField("items");
                try writeOperands(s, body.items);
            }
            if (body.ranges.len != 0) {
                try s.objectField("ranges");
                try s.beginArray();
                for (body.ranges) |range| try writeOperands(s, &range);
                try s.endArray();
            }
            try s.objectField("insts");
            try writeInsts(s, body.insts);
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
}
