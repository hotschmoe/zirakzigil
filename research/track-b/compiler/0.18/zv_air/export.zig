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
const reflect = @import("reflect.zig");
const Compilation = @import("../Compilation.zig");

const log = std.log.scoped(.zv_air);

pub const schema_version = 1;

pub const Options = struct {
    /// Directory receiving one schema v1 file per function instance; null disables it.
    out_dir: ?[]const u8 = null,
    /// Directory for the raw reflection dump (reflect.zig); null disables it.
    raw_dir: ?[]const u8 = null,
    /// Directory for the text of the compiler's own AIR printer; null disables it.
    text_dir: ?[]const u8 = null,
    include_std: bool = false,

    /// ZV_AIR_OUT, ZV_AIR_RAW, ZV_AIR_TEXT and ZV_AIR_STD let the export reach compiler runs spawned by `zig build`.
    pub fn fromEnviron(environ_map: anytype) Options {
        return .{
            .out_dir = environ_map.get("ZV_AIR_OUT"),
            .raw_dir = environ_map.get("ZV_AIR_RAW"),
            .text_dir = environ_map.get("ZV_AIR_TEXT"),
            .include_std = environ_map.get("ZV_AIR_STD") != null,
        };
    }

    /// Anything that changes the export must change the cache key, or a cache hit would skip it.
    pub fn hash(options: Options, hasher: anytype) void {
        hasher.addOptionalBytes(options.out_dir);
        hasher.addOptionalBytes(options.raw_dir);
        hasher.addOptionalBytes(options.text_dir);
        hasher.add(options.include_std);
    }
};

pub fn exportFunc(pt: Zcu.PerThread, func_index: InternPool.Index, air: *const Air) Allocator.Error!void {
    const zcu = pt.zcu;
    const comp = zcu.comp;
    const options = comp.zv_air_options;
    if (options.out_dir == null and options.raw_dir == null and options.text_dir == null) return;
    if (!options.include_std and adapter.isToolchain(zcu, func_index)) return;

    var arena_state: std.heap.ArenaAllocator = .init(comp.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);

    if (options.out_dir) |dir| {
        const function = try adapter.view(arena, zcu, func_index, air);
        writeFunction(&aw.writer, function) catch return error.OutOfMemory;
        try emit(comp, arena, dir, function.fqn, "json", aw.written());
    }
    if (options.raw_dir) |dir| {
        aw.clearRetainingCapacity();
        reflect.writeFunction(arena, &aw.writer, zcu, func_index, air, builtin.zig_version_string) catch return error.OutOfMemory;
        try emit(comp, arena, dir, zcu.intern_pool.getNav(zcu.funcInfo(func_index).owner_nav).fqn.toSlice(&zcu.intern_pool), "json", aw.written());
    }
    if (options.text_dir) |dir| {
        aw.clearRetainingCapacity();
        air.write(&aw.writer, zcu, null) catch return error.OutOfMemory;
        try emit(comp, arena, dir, zcu.intern_pool.getNav(zcu.funcInfo(func_index).owner_nav).fqn.toSlice(&zcu.intern_pool), "txt", aw.written());
    }
}

fn emit(comp: *Compilation, arena: Allocator, out_dir: []const u8, fqn: []const u8, ext: []const u8, content: []const u8) Allocator.Error!void {
    const name = try fileName(arena, fqn, ext, content);
    const io = comp.io;
    const dir = std.Io.Dir.cwd();
    dir.createDirPath(io, out_dir) catch |err| return log.err("{s}: {t}", .{ out_dir, err });
    const sub_path = try std.fs.path.join(arena, &.{ out_dir, name });
    dir.writeFile(io, .{ .sub_path = sub_path, .data = content }) catch |err|
        log.err("{s}: {t}", .{ sub_path, err });
}

/// The name embeds a hash of the content, so generic instances that share a
/// name stay apart and re-exports of identical content overwrite each other.
fn fileName(arena: Allocator, fqn: []const u8, ext: []const u8, content: []const u8) Allocator.Error![]const u8 {
    const stem = try arena.dupe(u8, fqn[0..@min(fqn.len, 80)]);
    for (stem) |*byte| switch (byte.*) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '-' => {},
        else => byte.* = '_',
    };
    return std.fmt.allocPrint(arena, "{s}.{x:0>16}.{s}", .{ stem, std.hash.Wyhash.hash(0, content), ext });
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
