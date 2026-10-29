//! A project type with its own invalidation rule: the one line of the `ownership` manifest is all the checker
//! needs to know (tests/own/registry.expect). `Plain` is the same type without it: the checker cannot see that
//! `remove` makes pointers stale, and says clean.

const zv = @import("zv");

pub const Registry = struct {
    slots: [8]u32 = @splat(0),
    used: [8]bool = @splat(false),

    pub const ownership = .{ .remove = .invalidates };
    comptime {
        zv.requireOwnership(Registry);
    }

    pub fn add(self: *Registry, value: u32) ?usize {
        for (&self.used, 0..) |*u, i| if (!u.*) {
            u.* = true;
            self.slots[i] = value;
            return i;
        };
        return null;
    }

    pub fn get(self: *Registry, i: usize) *u32 {
        return &self.slots[i];
    }

    pub fn remove(self: *Registry, i: usize) void {
        self.used[i] = false;
    }
};

pub const Plain = struct {
    slots: [8]u32 = @splat(0),
    used: [8]bool = @splat(false),

    pub fn get(self: *Plain, i: usize) *u32 {
        return &self.slots[i];
    }

    pub fn remove(self: *Plain, i: usize) void {
        self.used[i] = false;
    }
};

pub fn okRegistryUse(r: *Registry) u32 {
    const i = r.add(7) orelse return 0;
    const v = r.get(i).*;
    r.remove(i);
    return v;
}

pub fn badRegistryStale(r: *Registry) u32 {
    const i = r.add(7) orelse return 0;
    const p = r.get(i);
    r.remove(i);
    return p.*;
}

pub fn okRegistryOtherSlot(r: *Registry) u32 {
    const i = r.add(7) orelse return 0;
    const j = r.add(8) orelse return 0;
    const v = r.get(j).*;
    r.remove(i);
    return v;
}

pub fn gapPlainStale(r: *Plain) u32 {
    const p = r.get(0);
    r.remove(0);
    return p.*;
}
