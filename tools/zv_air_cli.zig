//! zv-air: reads zig-zv AIR packs (schema v2, docs/phase1.md).
//!   zv-air list PATH                 one line per function: name, id, the compilation's root name
//!   zv-air stats PATH                counts and sizes of a pack, or of the whole set of an index directory
//!   zv-air dump PACK [--fn NAME] [--pretty]   the pack as JSON (NAME: only functions containing it)
//!   zv-air verify PATH               load and validate every reference
//! PATH is a `.zvp` file or an index directory.

const std = @import("std");
const Io = std.Io;
const zv_air = @import("zv_air");
const schema = zv_air.schema;

const Command = enum { list, stats, dump, verify };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;
    if (args.len < 3) return usage();
    const command = std.meta.stringToEnum(Command, args[1]) orelse return usage();

    var filter: ?[]const u8 = null;
    var pretty = false;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--pretty")) {
            pretty = true;
        } else if (std.mem.eql(u8, args[i], "--fn") and i + 1 < args.len) {
            i += 1;
            filter = args[i];
        } else return usage();
    }

    const start = Io.Clock.awake.now(io);
    var set = try open(gpa, io, args[2]);
    defer set.deinit(gpa);
    const loaded = start.untilNow(io, .awake);
    switch (command) {
        .list => for (set.loaded) |l| for (l.pack.t.funcs) |f| {
            try out.print("{s}\t{x:0>16}\t{s}\n", .{ l.pack.str(f.fqn), f.id, l.pack.str(l.pack.meta.root) });
        },
        .verify => {
            for (set.loaded) |l| l.pack.validate() catch return fail("{s}: invalid pack", .{l.pack.str(l.pack.meta.root)});
            try out.print("ok {d} packs\n", .{set.loaded.len});
        },
        .dump => {
            if (set.loaded.len != 1) return fail("dump takes one pack, {d} found", .{set.loaded.len});
            try zv_air.json.write(out, set.loaded[0].pack, .{ .pretty = pretty, .filter = filter });
        },
        .stats => try stats(out, set, loaded),
    }
    try out.flush();
}

/// A `.zvp` file is a set of one; a directory is the set its index names.
fn open(gpa: std.mem.Allocator, io: Io, path: []const u8) !zv_air.Set {
    if (std.mem.endsWith(u8, path, schema.pack_ext)) {
        const loaded = try gpa.alloc(zv_air.reader.Loaded, 1);
        errdefer gpa.free(loaded);
        loaded[0] = try zv_air.loadPack(gpa, io, .cwd(), path);
        return .{ .loaded = loaded };
    }
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    return .open(gpa, io, dir);
}

fn stats(out: *Io.Writer, set: zv_air.Set, loaded: Io.Duration) !void {
    var sizes: [@typeInfo(schema.Tables).@"struct".field_names.len]usize = @splat(0);
    for (set.loaded) |l| inline for (@typeInfo(schema.Tables).@"struct".field_names, &sizes) |name, *size| {
        size.* += @sizeOf(@typeInfo(@FieldType(schema.Tables, name)).pointer.child) * @field(l.pack.t, name).len;
    };
    var bytes: usize = 0;
    var generic: usize = 0;
    var unsupported: usize = 0;
    var tags: [@typeInfo(schema.Tag).@"enum".field_names.len]bool = @splat(false);
    var counts: struct { funcs: usize = 0, insts: usize = 0, types: usize = 0, consts: usize = 0, strings: usize = 0, locs: usize = 0, callees: usize = 0 } = .{};
    for (set.loaded) |l| {
        const t = l.pack.t;
        bytes += l.bytes.len;
        counts.funcs += t.funcs.len;
        counts.insts += t.insts.len;
        counts.types += t.types.len;
        counts.consts += t.consts.len;
        counts.strings += t.str_index.len;
        counts.locs += t.locs.len;
        counts.callees += t.callees.len;
        for (t.funcs) |f| {
            generic += @intFromBool(f.flags.generic_instance);
            unsupported += f.unsupported;
        }
        for (t.insts) |inst| tags[@backingInt(inst.tag)] = true;
    }
    try out.writeAll("table bytes");
    inline for (@typeInfo(schema.Tables).@"struct".field_names, sizes) |name, size| try out.print("  {s} {d}", .{ name, size });
    try out.writeByte(10);
    var distinct: usize = 0;
    for (tags) |seen| distinct += @intFromBool(seen);
    try out.print(
        "packs {d}  bytes {d}  functions {d}  generic instances {d}  instructions {d}  distinct tags {d}  unsupported {d}\n" ++
            "types {d}  consts {d}  strings {d}  locs {d}  callees {d}  load {d} us\n",
        .{
            set.loaded.len, bytes,         counts.funcs,   generic,     counts.insts,   distinct,                                unsupported,
            counts.types,   counts.consts, counts.strings, counts.locs, counts.callees, @divTrunc(loaded.toNanoseconds(), 1000),
        },
    );
}

fn usage() !void {
    std.log.err("usage: zv-air list|stats|verify|dump PATH [--fn NAME] [--pretty]", .{});
    std.process.exit(2);
}

fn fail(comptime fmt: []const u8, args: anytype) !void {
    std.log.err(fmt, args);
    std.process.exit(1);
}
