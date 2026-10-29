//! Loads packs and index directories. A pack is read whole and then used in place.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const schema = @import("schema.zig");

pub const Loaded = struct {
    bytes: []align(8) u8,
    pack: schema.Pack,

    pub fn deinit(l: Loaded, gpa: Allocator) void {
        gpa.free(l.bytes);
    }
};

pub const LoadError = Io.Dir.ReadFileAllocError || schema.Pack.Error;

pub fn loadPack(gpa: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8) LoadError!Loaded {
    const bytes = try dir.readFileAllocOptions(io, sub_path, gpa, .unlimited, .@"8", null);
    errdefer gpa.free(bytes);
    return .{ .bytes = bytes, .pack = try .parse(bytes) };
}

/// The packs that an index directory names: every pack of the current build, nothing older.
pub const Set = struct {
    loaded: []Loaded,

    pub const Error = LoadError || Io.Dir.Iterator.Error || Io.Dir.OpenError || error{ BadEntry, StaleEntry };

    /// Reads every `*.zvi` entry of `dir`, loads its pack and checks it against the entry (size and
    /// hash). An entry that does not match, or whose file is gone, is an error: it is never skipped.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir) Error!Set {
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| gpa.free(name);
            names.deinit(gpa);
        }
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, schema.index_ext)) continue;
            try names.append(gpa, try gpa.dupe(u8, entry.name));
        }
        std.mem.sortUnstable([]u8, names.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        var loaded: std.ArrayList(Loaded) = .empty;
        errdefer {
            for (loaded.items) |l| l.deinit(gpa);
            loaded.deinit(gpa);
        }
        for (names.items) |name| {
            const line = try dir.readFileAlloc(io, name, gpa, .limited(64 * 1024));
            defer gpa.free(line);
            const entry = schema.Entry.parse(line) catch return error.BadEntry;
            const l = if (std.fs.path.isAbsolute(entry.path))
                try loadPack(gpa, io, .cwd(), entry.path)
            else
                try loadPack(gpa, io, dir, entry.path);
            errdefer l.deinit(gpa);
            if (l.bytes.len != entry.size or schema.contentHash(l.bytes) != entry.hash) return error.StaleEntry;
            try loaded.append(gpa, l);
        }
        return .{ .loaded = try loaded.toOwnedSlice(gpa) };
    }

    pub fn deinit(s: Set, gpa: Allocator) void {
        for (s.loaded) |l| l.deinit(gpa);
        gpa.free(s.loaded);
    }
};
