//! The source files behind a set of packs, found by their module-relative paths, with their manifests.
//! Everything allocated here lives as long as the process.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zv_air = @import("zv_air");
const schema = zv_air.schema;
pub const source = @import("source.zig");

pub const Dirs = struct {
    /// Where module-relative paths resolve unless a module has a directory of its own.
    default: []const u8 = ".",
    by_module: []const [2][]const u8 = &.{},
};

pub const Loaded = struct {
    src: source.Source,
    dir: []const u8,
    rel: []const u8,
    levels: std.StringHashMapUnmanaged(source.Level) = .empty,
};

pub const Position = struct { path: []const u8, line: u32, col: u32, src: ?*Loaded };

pub const Sources = struct {
    io: Io,
    arena: Allocator,
    dirs: Dirs,
    files: std.StringHashMapUnmanaged(?*Loaded) = .empty,

    pub fn forFile(s: *Sources, pack: *const schema.Pack, id: schema.FileId) Allocator.Error!?*Loaded {
        const rec = pack.t.files[@backingInt(id)];
        const module = pack.str(rec.module);
        const rel = pack.str(rec.path);
        const key = try std.fmt.allocPrint(s.arena, "{s}:{s}", .{ module, rel });
        const gop = try s.files.getOrPut(s.arena, key);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = null;
        const dir = for (s.dirs.by_module) |m| {
            if (std.mem.eql(u8, m[0], module)) break m[1];
        } else s.dirs.default;
        const full = try std.fs.path.join(s.arena, &.{ dir, rel });
        const text = Io.Dir.cwd().readFileAllocOptions(s.io, full, s.arena, .limited(64 << 20), .@"1", 0) catch return null;
        const src = source.Source.parse(s.arena, rel, text) catch return null;
        const loaded = try s.arena.create(Loaded);
        loaded.* = .{ .src = src, .dir = dir, .rel = rel };
        for (try loaded.src.entries(s.arena)) |e| try loaded.levels.put(s.arena, e.name, e.level);
        gop.value_ptr.* = loaded;
        return loaded;
    }

    /// The manifest level of the function the pack calls `fqn`, if its source is at hand and lists it.
    pub fn levelOf(s: *Sources, pack: *const schema.Pack, f: schema.Func) Allocator.Error!?source.Level {
        const loaded = (try s.forFile(pack, f.file)) orelse return null;
        return loaded.levels.get(try source.declaredName(s.arena, pack.str(f.fqn)));
    }

    pub fn where(s: *Sources, pack: *const schema.Pack, loc: schema.LocId) ?Position {
        if (loc == .none) return null;
        const rec = pack.t.locs[@backingInt(loc)];
        const file = pack.t.files[@backingInt(rec.file)];
        const loaded = s.forFile(pack, rec.file) catch null;
        const joined = if (loaded) |l| std.fs.path.join(s.arena, &.{ l.dir, l.rel }) catch pack.str(file.path) else pack.str(file.path);
        const path = s.arena.dupe(u8, joined) catch return null;
        std.mem.replaceScalar(u8, path, '\\', '/');
        return .{ .path = path, .line = rec.line, .col = rec.col, .src = loaded };
    }
};
