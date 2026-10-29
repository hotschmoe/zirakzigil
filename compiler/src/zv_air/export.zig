//! Collects the functions one compilation analyzes and turns them into its pack (src/air/schema.zig).
//! The compiler calls `exportFunc` once a function's AIR is final; `take` runs when the update ends.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Air = @import("../Air.zig");
const Compilation = @import("../Compilation.zig");
const InternPool = @import("../InternPool.zig");
const Zcu = @import("../Zcu.zig");
const adapter = @import("adapter.zig");
const cache = @import("cache.zig");
const json = @import("json.zig");
const schema = @import("schema.zig");
const builder = @import("builder.zig");
const Builder = builder.Builder;

/// One analyzed function as a single-function pack, with the sort key of the merge.
const Part = struct {
    bytes: []align(8) u8,
    fqn: []const u8,
    id: u64,

    fn lessThan(_: void, a: Part, b: Part) bool {
        return switch (std.mem.order(u8, a.fqn, b.fqn)) {
            .lt => true,
            .gt => false,
            .eq => a.id < b.id,
        };
    }
};

/// Parts by compilation: the compiler builds runtime libraries in sub-compilations of the same
/// process, while the main one is still analyzing.
var parts: std.AutoArrayHashMapUnmanaged(*const Compilation, std.ArrayList(Part)) = .empty;
var mutex: Io.Mutex = .init;

pub fn exportFunc(pt: Zcu.PerThread, func_index: InternPool.Index, air: *const Air) Allocator.Error!void {
    const zcu = pt.zcu;
    const comp = zcu.comp;
    const o = cache.options(comp) orelse return;
    cache.requireNonIncremental(comp);
    if ((!o.include_std and adapter.isToolchain(zcu, func_index)) or adapter.isBuildScript(zcu)) return;

    var arena_state: std.heap.ArenaAllocator = .init(comp.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b: Builder = .init(arena);
    adapter.build(&b, arena, zcu, func_index, air) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooLarge => std.process.fatal("zv_air: a function is too large for schema {d}", .{schema.version}),
    };
    const view = b.view(Builder.no_meta) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooLarge => std.process.fatal("zv_air: a function is too large for schema {d}", .{schema.version}),
    };
    const bytes = try schema.serialize(comp.gpa, view);
    errdefer comp.gpa.free(bytes);
    const parsed = schema.Pack.parse(bytes) catch unreachable;

    const io = comp.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const gop = try parts.getOrPut(comp.gpa, comp);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(comp.gpa, .{
        .bytes = bytes,
        .fqn = parsed.str(parsed.t.funcs[0].fqn),
        .id = schema.contentHash(bytes),
    });
}

pub const Output = struct {
    /// The pack, or the JSON text.
    bytes: []u8,
    functions: u32,
};

/// Merges everything `comp` exported during this update, in (fqn, id) order, into memory from `out`, and empties the
/// collector. The result is a function of the set of functions alone.
pub fn take(comp: *Compilation, o: cache.Options, out: Allocator) builder.Error!Output {
    const io = comp.io;
    var list: std.ArrayList(Part) = list: {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        break :list if (parts.fetchSwapRemove(comp)) |kv| kv.value else .empty;
    };
    defer {
        for (list.items) |part| comp.gpa.free(part.bytes);
        list.deinit(comp.gpa);
    }
    std.mem.sortUnstable(Part, list.items, {}, Part.lessThan);

    var arena_state: std.heap.ArenaAllocator = .init(comp.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = &comp.root_mod.resolved_target.result;
    var big: Builder = .init(arena);
    const meta: schema.Meta = .{
        .zig_version = try big.str(builtin.zig_version_string),
        .target = try big.str(try target.zigTriple(arena)),
        .root = try big.str(comp.root_name),
        .optimize = switch (comp.config.root_optimize_mode) {
            .debug => .debug,
            .safe => .safe,
            .fast => .fast,
            .small => .small,
        },
    };
    var previous: ?Part = null;
    for (list.items) |part| {
        defer previous = part;
        if (previous) |prev| if (prev.id == part.id and std.mem.eql(u8, prev.fqn, part.fqn)) continue;
        try big.appendFunction(schema.Pack.parse(part.bytes) catch unreachable, part.id);
    }
    const pack = try big.view(meta);

    const bytes: []u8 = if (o.json) bytes: {
        var aw: Io.Writer.Allocating = .init(out);
        json.write(&aw.writer, pack, .{}) catch return error.OutOfMemory;
        break :bytes try aw.toOwnedSlice();
    } else try schema.serialize(out, pack);
    return .{ .bytes = bytes, .functions = @intCast(pack.t.funcs.len) };
}
