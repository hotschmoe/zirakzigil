const std = @import("std");
// known-folders.open shape: defer free(path); return try openDir(path)
pub fn open(io: std.Io, gpa: std.mem.Allocator, name: []const u8) !std.Io.Dir {
    const path = try gpa.dupe(u8, name);
    defer gpa.free(path);
    return try std.Io.Dir.cwd().openDir(io, path, .{});
}
pub fn lenOf(gpa: std.mem.Allocator, name: []const u8) !usize {
    const path = try gpa.dupe(u8, name);
    defer gpa.free(path);
    return std.mem.indexOfScalar(u8, path, '/') orelse path.len;
}
