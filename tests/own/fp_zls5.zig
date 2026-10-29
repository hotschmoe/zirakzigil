const std = @import("std");

pub const S = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(u32) = .empty,
    count: u32 = 0,

    // returns the receiver itself and grows a field
    pub fn add(s: *S, v: u32) !*S {
        try s.list.append(s.gpa, v);
        return s;
    }
    pub fn chain(s: *S) !u32 {
        const t = try s.add(1);
        return t.count; // t is s: not stale
    }
    // returns a struct that holds the receiver pointer and grows a field
    const View = struct { owner: *S, n: usize };
    pub fn view(s: *S) !View {
        try s.list.append(s.gpa, 1);
        return .{ .owner = s, .n = s.list.items.len };
    }
    pub fn useView(s: *S) !u32 {
        const v = try s.view();
        return v.owner.count + @as(u32, @intCast(v.n));
    }
};
