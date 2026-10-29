//! What the checker knows about functions it cannot read: the allocator primitives of std, the pool types of zv, and
//! the documented semantics of std's containers that no body shows. A function in the packs is read instead (its
//! summary), and that includes std when the pack was exported with `ZV_AIR_STD`: the methods of std's containers are
//! then derived from their bodies (which buffer a call frees or reallocates, which result points into which storage).
//! `container` is the model for a pack without std bodies and the overlay for what bodies cannot show.
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
    /// Frees the allocation (or the handle) in argument 1.
    free,
    /// Frees the allocation in argument 1 if it succeeds and returns a new one (`realloc`, `remap`).
    realloc,
    /// Frees the allocation in argument 1 when the new length is zero; otherwise leaves it where it is.
    resize,
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
    /// Asks whether a handle is still good (`isLive`): a stale handle is its argument, not a mistake.
    query,
    /// `mem.swap(a, b)`: the two objects trade contents.
    swap,
    /// A method of one of std's containers: its body when the pack has it, `Model` when it has not.
    container,

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
        if (std.mem.eql(u8, m, "remap") or std.mem.eql(u8, m, "rawRemap")) return .realloc;
        if (std.mem.eql(u8, m, "resize") or std.mem.eql(u8, m, "rawResize")) return .resize;
        if (std.mem.eql(u8, m, "rawFree")) return .free;
        if (std.mem.eql(u8, m, "rawAlloc")) return .alloc;
        if (startsAny(m, &.{ "alloc", "alignedAlloc", "create", "dupe" })) return .alloc;
        if (startsAny(m, &.{ "free", "destroy" })) return .free;
        if (std.mem.startsWith(u8, m, "realloc")) return .realloc;
        return .none;
    }
    if (std.mem.eql(u8, name, "mem.swap")) return .swap;
    if (std.mem.startsWith(u8, name, "fmt.allocPrint")) return .alloc;
    if (startsAny(name, &.{ "mem.concat", "mem.join", "mem.replaceOwned" })) return .alloc;

    if (afterPrefix(name, "heap.ArenaAllocator.")) |m| return object(m, "allocator", "deinit", "reset");
    if (afterPrefix(name, "heap.DebugAllocator.")) |m| return object(m, "allocator", "deinit", "");
    if (afterPrefix(name, "heap.FixedBufferAllocator.")) |m| return object(m, "allocator", "", "reset");
    if (afterPrefix(name, "heap.GeneralPurposeAllocator.")) |m| return object(m, "allocator", "deinit", "");

    if (afterPrefix(name, "zv.Pool.")) |m| return pool(m);
    if (afterPrefix(name, "zv.Slots.")) |m| return pool(m);
    if (afterPrefix(name, "slots.Slots.")) |m| return pool(m);

    if (family(name) != null) return .container;
    return .none;
}

/// The argument that holds the new length of a `resize`.
pub fn lenArg(name: []const u8) usize {
    return if (std.mem.endsWith(u8, name, "rawResize")) 3 else 2;
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
    if (std.mem.eql(u8, m, "isLive")) return .query;
    if (std.mem.eql(u8, m, "alloc") or std.mem.eql(u8, m, "insert")) return .handle;
    if (std.mem.eql(u8, m, "free") or std.mem.eql(u8, m, "take")) return .free;
    return .none;
}

pub const Family = enum { list, multi, hash, array_hash, other };

/// The container family a declared name belongs to: `array_list.Aligned.append` is a list.
pub fn family(name: []const u8) ?Family {
    const table = [_]struct { []const u8, Family }{
        .{ "array_list.", .list },
        .{ "multi_array_list.", .multi },
        .{ "hash_map.", .hash },
        .{ "array_hash_map.", .array_hash },
        .{ "priority_queue.", .other },
        .{ "priority_dequeue.", .other },
        .{ "segmented_list.", .other },
        .{ "bit_set.DynamicBitSet", .other },
    };
    for (table) |e| if (std.mem.startsWith(u8, name, e[0])) return e[1];
    return null;
}

/// How an operation changes what is known of the room in a container (see `Cap` in check.zig).
pub const Count = enum {
    /// Leaves the count and the capacity as they are.
    keep,
    /// Anything may have happened: nothing is known afterwards.
    drop,
    /// One more element, and room for it is needed.
    insert1,
    /// One more element into room that is there (`appendAssumeCapacity`).
    insert1_assume,
    /// Some number of elements more, room needed.
    many,
    /// Some number of elements more, into room that is there.
    many_assume,
    /// `ensureTotalCapacity(n)`.
    total,
    /// `ensureUnusedCapacity(n)`.
    unused,
};

/// What an operation does to pointers into the container.
pub const Kill = enum {
    none,
    /// Elements move or go away (`orderedRemove`, `insert`): pointers to them are stale.
    shift,
    /// The storage may be reallocated: every pointer into it is stale.
    grow,
};

/// What a result points into.
pub const Ptr = enum {
    /// Nothing: a value, or a pointer the container does not own.
    none,
    /// The storage of the container (`getPtr`, `addOne`, `slice`, `keyIterator`): stale when the storage moves.
    storage,
    /// The container object itself (`HashMap.iterator` reloads the metadata on every `next`).
    self,
    /// Whatever the first argument holds (`Iterator.next`).
    content,
};

pub const Model = struct {
    effect: Effect = .reads,
    kill: Kill = .none,
    count: Count = .keep,
    ptr: Ptr = .none,
    /// The first argument's allocation becomes the container's (`fromOwnedSlice`).
    adopts: bool = false,
    /// False for a method nobody wrote down: assumed to invalidate, and counted.
    modelled: bool = true,
};

/// The documented semantics of a container method, by name. Exact for the methods listed and loud for the rest.
pub fn container(name: []const u8) Model {
    const fam = family(name) orelse return .{ .modelled = false, .kill = .grow, .count = .drop };
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .{ .modelled = false, .kill = .grow, .count = .drop };
    const method = name[dot + 1 ..];
    const head = name[0..dot];
    const prefix_len = switch (fam) {
        .list => "array_list.".len,
        .multi => "multi_array_list.".len,
        .hash => "hash_map.".len,
        .array_hash => "array_hash_map.".len,
        .other => 0,
    };
    // A helper type of the container (an iterator, a slice view, the index header).
    const nested = fam != .other and head.len > prefix_len and std.mem.count(u8, head[prefix_len..], ".") >= 1;
    if (nested) {
        if (std.mem.eql(u8, method, "deinit")) return .{ .effect = .ends };
        return .{ .ptr = .content };
    }
    if (std.mem.eql(u8, method, "deinit")) return .{ .effect = .ends };
    if (std.mem.startsWith(u8, method, "toOwnedSliceAssert")) return .{ .ptr = .storage, .count = .drop };
    if (std.mem.startsWith(u8, method, "toOwned")) return .{ .effect = .releases, .count = .drop };
    if (std.mem.startsWith(u8, method, "fromOwnedSlice")) return .{ .adopts = true, .count = .drop };
    // The storage moves to the result and the container is empty; pointers into it stay good.
    if (startsAny(method, &.{ "moveToUnmanaged", "toManaged", "move", "promote" })) return .{ .ptr = .storage, .count = .drop };

    const many_names = [_][]const u8{ "addMany", "appendSlice", "appendNTimes", "appendUnalignedSlice", "appendMany", "insertSlice", "replaceRange", "putAll", "addAll", "resize", "insertMany", "print" };
    const many = startsAny(method, &many_names);
    // `Bounded` variants fail instead of growing, like the ones that assume room.
    if (std.mem.indexOf(u8, method, "AssumeCapacity") != null or std.mem.indexOf(u8, method, "Bounded") != null) {
        const ptr: Ptr = if (startsAny(method, &.{ "addOne", "addMany", "getOrPut" })) .storage else .none;
        const shift = startsAny(method, &.{ "insert", "replaceRange" });
        return .{ .kill = if (shift) .shift else .none, .count = if (many) .many_assume else .insert1_assume, .ptr = ptr };
    }
    if (startsAny(method, &.{"ensureTotalCapacity"})) return .{ .kill = .grow, .count = .total };
    if (startsAny(method, &.{"ensureUnusedCapacity"})) return .{ .kill = .grow, .count = .unused };
    if (startsAny(method, &.{ "setCapacity", "shrinkAndFree", "clearAndFree", "shrinkToLen", "rehash", "reIndex" })) return .{ .kill = .grow, .count = .drop };
    if (startsAny(method, &.{ "addOne", "addMany", "getOrPut" })) return .{ .kill = .grow, .count = if (many) .many else .insert1, .ptr = .storage };
    if (many) return .{ .kill = .grow, .count = .many };
    if (startsAny(method, &.{ "append", "put", "fetchPut", "insert", "add", "push", "enqueue", "addUnmanaged" })) return .{ .kill = .grow, .count = .insert1 };

    // Memory stays where it is: an element that moves or goes away is the only thing stale.
    // The length becomes the capacity.
    if (std.mem.eql(u8, method, "expandToCapacity")) return .{ .count = .many_assume };
    if (startsAny(method, &.{ "pop", "shrinkRetainingCapacity", "lockPointers", "unlockPointers", "assertPointerLock", "setKey", "set" })) return .{};
    // A hash map is open addressing: taking an entry out moves no other entry.
    if (fam == .hash and startsAny(method, &.{ "remove", "fetchRemove" })) return .{};
    if (startsAny(method, &.{ "orderedRemove", "swapRemove", "fetchSwapRemove", "fetchOrderedRemove", "removeByIndex", "remove", "fetchRemove", "clearRetainingCapacity", "sort", "swap", "reverse", "replaceRange" }))
        return .{ .kill = .shift };

    // Reads: what points into the storage, and what only looks.
    if (startsAny(method, &.{ "getPtr", "getKeyPtr", "getEntry", "keyIterator", "valueIterator", "slice", "items", "keys", "values", "allocatedSlice", "unusedCapacitySlice", "getLastPtr", "lastPtr", "unusedCapacity" }))
        return .{ .ptr = .storage };
    if (std.mem.eql(u8, method, "iterator")) return .{ .ptr = if (fam == .hash) .self else .storage };
    const reads = [_][]const u8{
        "get",          "contains", "count",     "capacity", "clone", "format", "hash",     "eql",       "isEmpty",   "first",           "last",
        "peek",         "isSet",    "findFirst", "findLast", "at",    "len",    "index",    "unmanaged", "toManaged", "moveToUnmanaged", "is",
        "initCapacity", "init",     "empty",     "bitSet",   "unset", "set",    "setValue", "toggle",
    };
    if (startsAny(method, &reads)) return .{};
    return .{ .modelled = false, .kill = .grow, .count = .drop };
}

/// Whether a container method takes elements out (a registry entry put in for the duration of a call is gone after it).
pub fn removes(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    if (family(name) == null) return false;
    return startsAny(name[dot + 1 ..], &.{ "remove", "fetchRemove", "fetchSwapRemove", "fetchOrderedRemove", "orderedRemove", "swapRemove", "pop", "clear", "shrink", "delete", "deinit" });
}
