//! Where the export lives. With `ZV_AIR_OUT` set, a compile that goes through the cache writes its
//! JSON into its own cache artifact (`o/<digest>/zv_air`) and copies it to `ZV_AIR_OUT` on every
//! update, hit or miss. With it unset, nothing here does anything, not even to the cache key.

const std = @import("std");
const Io = std.Io;
const Cache = std.Build.Cache;

const Compilation = @import("../Compilation.zig");

const sub_dir = "zv_air";

pub const Options = struct {
    out_dir: []const u8,
    include_std: bool,
};

pub fn options(comp: *const Compilation) ?Options {
    const out_dir = comp.environ_map.get("ZV_AIR_OUT") orelse return null;
    return .{ .out_dir = out_dir, .include_std = comp.environ_map.get("ZV_AIR_STD") != null };
}

/// An exporting compile must not hit an entry made without the export, or with other settings.
/// The output directory stays out of the key: a hit restores into whichever directory is asked for.
pub fn hashCache(comp: *const Compilation, hash: *Cache.HashHelper) void {
    const o = options(comp) orelse return;
    hash.addBytes("zv_air");
    hash.add(o.include_std);
}

pub const Target = struct { dir: Io.Dir, sub_path: []const u8 };

/// Where `exportFunc` writes during an update. Incremental mode has no per-update artifact, and a
/// function it does not re-analyze is not exported again, so the export would be partial: unsupported.
pub fn target(comp: *Compilation, o: Options) Target {
    return switch (comp.cache_use) {
        .none => .{ .dir = .cwd(), .sub_path = o.out_dir },
        .whole => |whole| .{ .dir = whole.tmp_artifact_directory.?.handle, .sub_path = sub_dir },
        .incremental => std.process.fatal("zv_air: ZV_AIR_OUT cannot be combined with -fincremental", .{}),
    };
}

/// Copies the update's export out of the cache artifact. Called when `Compilation.update` returns.
pub fn restore(comp: *Compilation) void {
    const o = options(comp) orelse return;
    if (comp.cache_use != .whole) return;
    const digest = comp.digest orelse return;
    if (comp.anyErrors()) return;
    const io = comp.io;

    var buffer: [Cache.hex_digest_len + 3 + sub_dir.len]u8 = undefined;
    const from = std.fmt.bufPrint(&buffer, "o{c}{s}{c}{s}", .{ std.fs.path.sep, &Cache.binToHex(digest), std.fs.path.sep, sub_dir }) catch unreachable;
    var src = comp.dirs.local_cache.handle.openDir(io, from, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| std.process.fatal("zv_air: {s}: {t}", .{ from, e }),
    };
    defer src.close(io);
    const cwd: Io.Dir = .cwd();
    cwd.createDirPath(io, o.out_dir) catch |err| std.process.fatal("zv_air: {s}: {t}", .{ o.out_dir, err });
    var out = cwd.openDir(io, o.out_dir, .{}) catch |err| std.process.fatal("zv_air: {s}: {t}", .{ o.out_dir, err });
    defer out.close(io);

    var it = src.iterate();
    while (it.next(io) catch |err| std.process.fatal("zv_air: {s}: {t}", .{ from, err })) |entry| {
        // The name embeds a hash of the content, so an existing file is already the right one.
        if (out.statFile(io, entry.name, .{})) |_| continue else |_| {}
        src.copyFile(entry.name, out, entry.name, io, .{}) catch |err|
            std.process.fatal("zv_air: {s}/{s}: {t}", .{ o.out_dir, entry.name, err });
    }
}
