//! Function names as the tools show and select them.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The name a function is declared under: no generic arguments, no instance suffix.
pub fn declaredName(arena: Allocator, fqn: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    for (fqn) |c| {
        if (c == '(') depth += 1;
        if (depth == 0) try out.append(arena, c);
        if (c == ')' and depth > 0) depth -= 1;
    }
    var name: []const u8 = out.items;
    for ([_][]const u8{ "__func", "__anon" }) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) name = name[0 .. name.len - suffix.len];
    }
    return name;
}

/// Whether `path` selects `name`: it is the name or consecutive dotted components of it, so `min` selects
/// `a.min` and `a.min.inner` but not `a.minMul`.
pub fn selects(name: []const u8, path: []const u8) bool {
    if (path.len == 0) return false;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, name, from, path)) |at| : (from = at + 1) {
        const start = at == 0 or name[at - 1] == '.';
        const end = at + path.len == name.len or name[at + path.len] == '.';
        if (start and end) return true;
    }
    return false;
}

/// `selects` for a name that may carry generic arguments.
pub fn selectsFqn(fqn: []const u8, path: []const u8) bool {
    var buf: [2048]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const name = declaredName(fba.allocator(), fqn) catch fqn;
    return selects(name, path);
}
