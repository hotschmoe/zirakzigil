//! Where the export lives. With `ZV_AIR_OUT` set, a compile that goes through the cache stores its
//! pack in its own cache entry (`o/<digest>/zv_air.zvp`, with a one-line `zv_air.zvi` written after it)
//! and, on every update, hit or miss, writes an index entry for it to `ZV_AIR_OUT`. The index entry's
//! name comes from the compile's identity, so an update replaces the compile's previous entry and the
//! directory always names the current packs. With it unset, nothing here does anything, not even to
//! the cache key.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Cache = std.Build.Cache;

const Compilation = @import("../Compilation.zig");
const Module = @import("../Module.zig");
const exporter = @import("export.zig");
const schema = @import("schema.zig");

pub const Options = struct {
    out_dir: []const u8,
    include_std: bool,
    json: bool,
};

fn flag(comp: *const Compilation, name: []const u8) bool {
    const value = comp.environ_map.get(name) orelse return false;
    return value.len != 0 and !std.mem.eql(u8, value, "0");
}

pub fn options(comp: *const Compilation) ?Options {
    const out_dir = comp.environ_map.get("ZV_AIR_OUT") orelse return null;
    return .{ .out_dir = out_dir, .include_std = flag(comp, "ZV_AIR_STD"), .json = flag(comp, "ZV_AIR_JSON") };
}

/// An exporting compile must not hit an entry made without the export, or with other settings.
/// The index directory stays out of the key: a hit writes its entry to whichever directory is asked for.
pub fn hashCache(comp: *const Compilation, hash: *Cache.HashHelper) void {
    const o = options(comp) orelse return;
    hash.addBytes("zv_air2");
    hash.add(o.include_std);
    hash.add(o.json);
}

/// Incremental mode analyzes only what changed, so its export would be partial: unsupported.
pub fn requireNonIncremental(comp: *const Compilation) void {
    if (comp.cache_use == .incremental) std.process.fatal("zv_air: ZV_AIR_OUT cannot be combined with -fincremental", .{});
}

/// Writes the update's pack into its cache entry (or, without a cache, into the index directory)
/// and the compile's entry into the index directory. Called when `Compilation.update` returns.
pub fn restore(comp: *Compilation) void {
    const o = options(comp) orelse return;
    var arena_state: std.heap.ArenaAllocator = .init(comp.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fresh = !comp.last_update_was_cache_hit;
    const output = if (fresh) exporter.take(comp, o, arena) catch |err| fail("collect", err) else null;
    if (comp.anyErrors()) return;
    requireNonIncremental(comp);
    const io = comp.io;
    const cwd: Io.Dir = .cwd();
    cwd.createDirPath(io, o.out_dir) catch |err| fail(o.out_dir, err);
    var index = cwd.openDir(io, o.out_dir, .{}) catch |err| fail(o.out_dir, err);
    defer index.close(io);

    const stem = std.fmt.allocPrint(arena, "{x:0>16}", .{stepKey(comp, arena) catch |err| fail("identity", err)}) catch |err| fail("name", err);
    const entry_name = std.fmt.allocPrint(arena, "{s}{s}", .{ stem, schema.index_ext }) catch |err| fail("name", err);
    const ext = if (o.json) schema.json_ext else schema.pack_ext;
    const format: schema.Entry.Format = if (o.json) .json else .pack;

    var entry: schema.Entry = undefined;
    switch (comp.cache_use) {
        .incremental => unreachable,
        .none => {
            const name = std.fmt.allocPrint(arena, "{s}{s}", .{ stem, ext }) catch |err| fail("name", err);
            const out = output.?;
            writeAtomic(io, index, name, out.bytes);
            entry = .{ .format = format, .size = out.bytes.len, .hash = schema.contentHash(out.bytes), .functions = out.functions, .path = name };
        },
        .whole => {
            const digest = comp.digest orelse return;
            const local = comp.dirs.local_cache.handle;
            const dir = std.fmt.allocPrint(arena, "o{c}{s}{c}", .{ std.fs.path.sep, &Cache.binToHex(digest), std.fs.path.sep }) catch |err| fail("name", err);
            const stored_name = if (o.json) "zv_air" ++ schema.json_ext else "zv_air" ++ schema.pack_ext;
            const stored_pack = std.fmt.allocPrint(arena, "{s}{s}", .{ dir, stored_name }) catch |err| fail("name", err);
            const stored_entry = std.fmt.allocPrint(arena, "{s}zv_air{s}", .{ dir, schema.index_ext }) catch |err| fail("name", err);
            if (output) |out| {
                writeAtomic(io, local, stored_pack, out.bytes);
                entry = .{ .format = format, .size = out.bytes.len, .hash = schema.contentHash(out.bytes), .functions = out.functions, .path = stored_name };
                writeAtomic(io, local, stored_entry, entryText(arena, entry));
            } else {
                entry = readStored(io, local, stored_entry, arena);
            }
            if (entry.functions != 0) {
                const real = local.realPathFileAlloc(io, stored_pack, arena) catch |err| fail(stored_pack, err);
                entry.path = real;
            }
        },
    }
    if (entry.functions == 0) {
        index.deleteFile(io, entry_name) catch {};
        return;
    }
    writeAtomic(io, index, entry_name, entryText(arena, entry));
}

/// The entry a miss stored beside its pack. It is written after the pack, so finding it means the
/// pack is complete; a hit that races the miss that made the entry waits for it.
fn readStored(io: Io, dir: Io.Dir, sub_path: []const u8, arena: Allocator) schema.Entry {
    var waited: u32 = 0;
    while (true) : (waited += 1) {
        if (dir.readFileAlloc(io, sub_path, arena, .limited(4096))) |line| {
            const entry = schema.Entry.parse(line) catch std.process.fatal("zv_air: {s}: malformed", .{sub_path});
            return entry;
        } else |err| switch (err) {
            error.FileNotFound => if (waited >= 100) std.process.fatal(
                "zv_air: {s} is missing: the cache entry has no export; delete the entry or the cache directory",
                .{sub_path},
            ),
            else => fail(sub_path, err),
        }
        io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
}

fn writeAtomic(io: Io, dir: Io.Dir, sub_path: []const u8, data: []const u8) void {
    var random: [8]u8 = undefined;
    io.random(&random);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&buffer, "{s}.tmp{x}", .{ sub_path, random }) catch fail(sub_path, error.NameTooLong);
    dir.writeFile(io, .{ .sub_path = tmp, .data = data }) catch |err| fail(sub_path, err);
    dir.rename(tmp, dir, sub_path, io) catch |err| fail(sub_path, err);
}

fn fail(what: []const u8, err: anyerror) noreturn {
    std.process.fatal("zv_air: {s}: {t}", .{ what, err });
}

/// What names a compile across runs and across updates: its name, kind, target, optimize mode and
/// module graph (names and source paths). Two compiles with the same key are the same compile, so
/// they overwrite each other's entry harmlessly.
fn stepKey(comp: *const Compilation, arena: Allocator) Allocator.Error!u64 {
    var h: std.hash.Wyhash = .init(0);
    h.update(comp.root_name);
    const target = &comp.root_mod.resolved_target.result;
    std.hash.autoHash(&h, .{ comp.config.output_mode, comp.config.is_test, comp.config.root_optimize_mode, target.cpu.arch, target.os.tag, target.abi });
    var seen: std.AutoHashMapUnmanaged(*const Module, void) = .empty;
    try hashModule(&h, arena, &seen, comp.root_mod);
    return h.final();
}

fn hashModule(h: *std.hash.Wyhash, arena: Allocator, seen: *std.AutoHashMapUnmanaged(*const Module, void), mod: *const Module) Allocator.Error!void {
    if ((try seen.getOrPut(arena, mod)).found_existing) return;
    h.update(mod.fully_qualified_name);
    h.update(@tagName(mod.root.root));
    h.update(mod.root.sub_path);
    h.update(mod.root_src_path);
    for (mod.deps.keys(), mod.deps.values()) |name, dep| {
        h.update(name);
        try hashModule(h, arena, seen, dep);
    }
}

fn entryText(arena: Allocator, entry: schema.Entry) []const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    entry.write(&aw.writer) catch |err| fail("entry", err);
    return aw.written();
}
