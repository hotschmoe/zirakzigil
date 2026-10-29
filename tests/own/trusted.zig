//! A function exempt from the check by the code owners: named in the manifest, counted, and capped by the gate's
//! `max_trusted`. Its callers still see what its body does.

const std = @import("std");
const zv = @import("zv");

pub const ownership = .{ .leakyOnPurpose = .trusted };

comptime {
    zv.requireOwnership(@This());
}

/// Hands the allocation to a C library that frees it: the checker cannot follow, the owners vouch for it.
pub fn leakyOnPurpose(gpa: std.mem.Allocator) !void {
    const buf = try gpa.alloc(u8, 4);
    gpa.free(buf);
    gpa.free(buf);
}

pub fn fine(gpa: std.mem.Allocator) !void {
    const buf = try gpa.alloc(u8, 4);
    gpa.free(buf);
}
