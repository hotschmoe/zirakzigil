const std = @import("std");
const Info = struct { name: []const u8, n: u32 };

pub const A = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(u32, ?Info) = .empty,

    // result is arena memory handed out by a method that also grows the cache map
    pub fn describe(a: *A, key: u32) !?Info {
        const gop = try a.map.getOrPut(a.gpa, key);
        if (gop.found_existing) return gop.value_ptr.*;
        const info: Info = .{ .name = try a.arena.dupe(u8, "name"), .n = key };
        gop.value_ptr.* = info;
        return info;
    }

    pub fn twice(a: *A) !usize {
        const x = (try a.describe(1)).?;
        const y = (try a.describe(2)).?; // grows the map; x.name lives in the arena
        return x.name.len + y.n;
    }
    pub fn once(a: *A) !usize {
        const x = (try a.describe(1)).?;
        return x.name.len;
    }
};

pub fn caller(a: *A) !usize {
    var local: A = .{ .gpa = a.gpa, .arena = a.arena };
    defer local.map.deinit(local.gpa);
    const x = (try local.describe(1)).?;
    return x.name.len;
}
