const std = @import("std");

const Handle = struct { name: []const u8 };
const Binding = struct { handle: *Handle, n: u32 };

// FP-A: recursion through the cache (like Analyser.resolveBindingOfNode -> ...Uncached -> resolveBindingOfNode)
pub const Cache = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(u32, ?Binding) = .empty,

    pub fn resolve(c: *Cache, key: u32, h: *Handle) error{OutOfMemory}!?Binding {
        const gop = try c.map.getOrPut(c.gpa, key);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = null;
        const binding = try c.uncached(key, h);
        if (binding != null) c.map.getPtr(key).?.* = binding;
        return binding;
    }

    fn uncached(c: *Cache, key: u32, h: *Handle) error{OutOfMemory}!?Binding {
        if (key == 0) return .{ .handle = h, .n = 0 };
        const inner = (try c.resolve(key - 1, h)) orelse return null;
        return .{ .handle = inner.handle, .n = inner.n + 1 };
    }

    pub fn resolveTwice(c: *Cache, h: *Handle) !usize {
        const a = (try c.resolve(1, h)) orelse return 0;
        const b = (try c.resolve(2, h)) orelse return 0;
        return a.handle.name.len + b.n;
    }
};
