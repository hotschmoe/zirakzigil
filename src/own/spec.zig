//! What the checker knows about functions it cannot read: the allocator and container API of std, and the
//! pool types of zv. A function in the packs is read instead (its summary); the table is for the rest.
//! Names are the declared names of the pack (`mem.Allocator.alloc`, type arguments and `__func` removed).
//! A project adds its own types with the `ownership` manifest (see `Effect.fromTag`).

const std = @import("std");

pub const Effect = enum {
    /// Nothing special: the result, if it points anywhere, points into what the arguments do.
    none,
    /// The result is a new allocation from the `mem.Allocator` in argument 0.
    alloc,
    /// The result is a new handle: it stands for a slot of the pool in argument 0 and dies when freed.
    handle,
    /// Frees the allocation (or the handle) in the last pointer-like argument.
    free,
    /// Frees the allocation in argument 1 and returns a new one.
    realloc,
    /// The result is an `mem.Allocator` backed by the object in argument 0.
    allocator_of,
    /// The object in argument 0 is gone, with everything it handed out.
    ends,
    /// The object in argument 0 gives back everything it handed out but stays usable.
    resets,
    /// A container operation that can move or drop what the container holds: pointers into it are stale.
    invalidates,
    /// The buffer leaves the container (`toOwnedSlice`): the result is a new allocation, the container is empty.
    releases,
    /// A container operation that only reads.
    reads,

    /// The kinds an `ownership` manifest may give a method.
    pub fn fromTag(name: []const u8) ?Effect {
        const map = std.StaticStringMap(Effect).initComptime(.{
            .{ "invalidates", .invalidates },
            .{ "ends", .ends },
            .{ "resets", .resets },
            .{ "reads", .reads },
            .{ "releases", .releases },
            .{ "handle", .handle },
            .{ "free", .free },
        });
        return map.get(name);
    }
};

/// The declared name without the arguments of generic types and without instance suffixes.
pub fn stripped(buf: []u8, fqn: []const u8) []const u8 {
    var n: usize = 0;
    var depth: usize = 0;
    for (fqn) |c| {
        if (c == '(') depth += 1;
        if (depth == 0 and n < buf.len) {
            buf[n] = c;
            n += 1;
        }
        if (c == ')' and depth > 0) depth -= 1;
    }
    var name = buf[0..n];
    for ([_][]const u8{ "__func", "__anon" }) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) name = name[0 .. name.len - suffix.len];
    }
    return name;
}

pub fn lookup(name: []const u8) Effect {
    if (afterPrefix(name, "mem.Allocator.")) |m| {
        if (startsAny(m, &.{ "alloc", "alignedAlloc", "create", "dupe" })) return .alloc;
        if (startsAny(m, &.{ "free", "destroy" })) return .free;
        if (std.mem.startsWith(u8, m, "realloc")) return .realloc;
        return .none;
    }
    if (std.mem.startsWith(u8, name, "fmt.allocPrint")) return .alloc;
    if (startsAny(name, &.{ "mem.concat", "mem.join", "mem.replaceOwned" })) return .alloc;

    if (afterPrefix(name, "heap.ArenaAllocator.")) |m| return object(m, "allocator", "deinit", "reset");
    if (afterPrefix(name, "heap.DebugAllocator.")) |m| return object(m, "allocator", "deinit", "");
    if (afterPrefix(name, "heap.FixedBufferAllocator.")) |m| return object(m, "allocator", "", "reset");
    if (afterPrefix(name, "heap.GeneralPurposeAllocator.")) |m| return object(m, "allocator", "deinit", "");

    if (afterPrefix(name, "zv.Pool.")) |m| return pool(m);
    if (afterPrefix(name, "zv.Slots.")) |m| return pool(m);
    if (afterPrefix(name, "slots.Slots.")) |m| return pool(m);

    const containers = [_][]const u8{
        "array_list.Aligned.",  "array_list.Managed.", "array_hash_map.", "hash_map.",
        "multi_array_list.",    "priority_queue.",     "segmented_list.", "bit_set.DynamicBitSet",
    };
    for (containers) |prefix| if (std.mem.startsWith(u8, name, prefix)) {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .none;
        return container(name[dot + 1 ..]);
    };
    return .none;
}

fn afterPrefix(name: []const u8, prefix: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, name, prefix)) name[prefix.len..] else null;
}

fn startsAny(name: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

fn object(m: []const u8, allocator_name: []const u8, end_name: []const u8, reset_name: []const u8) Effect {
    if (std.mem.eql(u8, m, allocator_name)) return .allocator_of;
    if (end_name.len != 0 and std.mem.eql(u8, m, end_name)) return .ends;
    if (reset_name.len != 0 and std.mem.eql(u8, m, reset_name)) return .resets;
    return .none;
}

/// `zv.Pool` and `zv.Slots`: a handle is a copyable name for a slot; freeing it ends every pointer taken through it.
fn pool(m: []const u8) Effect {
    if (std.mem.eql(u8, m, "alloc")) return .handle;
    if (std.mem.eql(u8, m, "free")) return .free;
    return .none;
}

/// The methods of std's containers: what reads is listed, everything else may reallocate, move or drop.
fn container(method: []const u8) Effect {
    if (std.mem.eql(u8, method, "deinit")) return .ends;
    if (std.mem.startsWith(u8, method, "toOwned")) return .releases;
    // Room was made beforehand: what is there does not move.
    if (std.mem.endsWith(u8, method, "AssumeCapacity") and startsAny(method, &.{ "append", "put", "add" })) return .reads;
    const reads = [_][]const u8{
        "get",     "contains", "count",    "iterator", "keyIterator", "valueIterator", "slice",   "at",
        "last",    "first",    "is",       "capacity", "clone",       "items",         "format",  "hash",
        "eql",     "peek",     "unmanaged", "allocatedSlice", "unusedCapacitySlice", "getLast", "isSet", "findFirst",
    };
    if (startsAny(method, &reads)) return .reads;
    return .invalidates;
}
