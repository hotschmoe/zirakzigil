//! A loop that pops an entry and frees its key in a `defer` (zls DiagnosticsCollection.publishDiagnostics): the entry
//! of the next iteration is not the one that was freed.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Uri = struct {
    value: []const u8,
    pub fn deinit(self: Uri, gpa: Allocator) void {
        gpa.free(self.value);
    }
    pub const Context = struct {
        pub fn hash(_: Context, k: Uri) u32 {
            return @truncate(std.hash.Wyhash.hash(0, k.value));
        }
        pub fn eql(_: Context, a: Uri, b: Uri, _: usize) bool {
            return std.mem.eql(u8, a.value, b.value);
        }
    };
};

const Files = std.array_hash_map.Custom(Uri, void, Uri.Context, true);

fn use(uri: Uri) !void {
    std.mem.doNotOptimizeAway(uri.value.len);
}

pub fn drain(gpa: Allocator, files: *Files) !void {
    while (true) {
        const entry = files.pop() orelse break;
        defer entry.key.deinit(gpa);
        try use(entry.key);
    }
}

pub fn drainStack(gpa: Allocator, names: *std.ArrayList([]u8)) void {
    while (names.pop()) |name| {
        defer gpa.free(name);
        std.mem.doNotOptimizeAway(name.len);
    }
}
