const std = @import("std");
const Handle = struct { name: []const u8 };
const Binding = struct { handle: *Handle, n: u32 };

pub const S = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(u32, ?Binding) = .empty,
    list: std.ArrayList(*Handle) = .empty,
    bind: std.ArrayList(Binding) = .empty,

    // 1: element pointer loaded from a list, list grows, element used (the pointee is not in the list storage)
    pub fn t1(s: *S, h: *Handle) !usize {
        try s.list.append(s.gpa, h);
        const first = s.list.items[0];
        try s.list.append(s.gpa, h);
        return first.name.len;
    }
    // 2: struct copy with a pointer field out of a list, list grows, pointer field used
    pub fn t2(s: *S, h: *Handle) !usize {
        try s.bind.append(s.gpa, .{ .handle = h, .n = 1 });
        const b = s.bind.items[0];
        try s.bind.append(s.gpa, .{ .handle = h, .n = 2 });
        return b.handle.name.len;
    }
    // 3: same through value_ptr.* of a map
    pub fn t3(s: *S, h: *Handle) !usize {
        const gop = try s.map.getOrPut(s.gpa, 1);
        if (!gop.found_existing) gop.value_ptr.* = .{ .handle = h, .n = 1 };
        const b = gop.value_ptr.*.?;
        try s.map.put(s.gpa, 2, null);
        return b.handle.name.len;
    }
    fn get(s: *S, key: u32, h: *Handle) !?Binding {
        const gop = try s.map.getOrPut(s.gpa, key);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = .{ .handle = h, .n = key };
        return gop.value_ptr.*;
    }
    // 4: callee returns copy loaded from the map and also grows the map; caller uses result after another growing call
    pub fn t4(s: *S, h: *Handle) !usize {
        const a = (try s.get(1, h)).?;
        _ = try s.get(2, h);
        return a.handle.name.len;
    }
    // 5: use of the call's own result
    pub fn t5(s: *S, h: *Handle) !usize {
        const a = (try s.get(1, h)).?;
        return a.handle.name.len;
    }
};
