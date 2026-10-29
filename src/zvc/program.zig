//! All the packs of a run as one program: functions by name, each run symbolically at most once, and the
//! summaries a caller uses in place of a callee's body. Everything lives as long as the process.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zv_air = @import("zv_air");
const schema = zv_air.schema;
const term = @import("term.zig");
const vc = @import("vc.zig");
const source = @import("source.zig");
const sources = @import("sources.zig");

pub const Ref = struct { pack: *const schema.Pack, func: schema.Func };

pub const Run = struct {
    ref: Ref,
    name: []const u8,
    vc: vc.Vc,
    state: enum { running, done } = .running,
    summary: ?vc.Summary = null,
};

pub const Program = struct {
    gpa: Allocator,
    arena: Allocator,
    pool: term.Pool,
    sources: *sources.Sources,
    funcs: std.StringHashMapUnmanaged(Ref) = .empty,
    runs: std.StringHashMapUnmanaged(*Run) = .empty,
    /// Names that two different functions have: a call resolves by name, so it cannot tell which one it means.
    ambiguous: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(gpa: Allocator, arena: Allocator, srcs: *sources.Sources, packs: []const *const schema.Pack) Allocator.Error!Program {
        var p: Program = .{ .gpa = gpa, .arena = arena, .pool = .init(gpa), .sources = srcs };
        for (packs) |pack| for (pack.t.funcs) |f| {
            const gop = try p.funcs.getOrPut(arena, pack.str(f.fqn));
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .pack = pack, .func = f };
            } else if (gop.value_ptr.func.id != f.id) try p.ambiguous.put(arena, gop.key_ptr.*, {});
        };
        return p;
    }

    pub fn deinit(p: *Program) void {
        p.pool.deinit();
    }

    /// The function run symbolically. Runs are cached: asking again, or asking as a callee, does not redo it.
    pub fn run(p: *Program, ref: Ref) Allocator.Error!*Run {
        const fqn = ref.pack.str(ref.func.fqn);
        const key = try std.fmt.allocPrint(p.arena, "{s}#{x}", .{ fqn, ref.func.id });
        const gop = try p.runs.getOrPut(p.arena, key);
        if (gop.found_existing) return gop.value_ptr.*;
        const name = try source.declaredName(p.arena, fqn);
        const r = try p.arena.create(Run);
        gop.value_ptr.* = r;
        const last = if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| name[i + 1 ..] else name;
        var names: []const []const u8 = &.{};
        if (try p.sources.forFile(ref.pack, ref.func.file)) |loaded| {
            names = (try loaded.src.paramNames(p.arena, last, ref.func.line)) orelse &.{};
        }
        r.* = .{
            .ref = ref,
            .name = name,
            .vc = try vc.Vc.init(p.gpa, p.arena, &p.pool, ref.pack, ref.func, .{
                .param_names = names,
                .prefix = try std.fmt.allocPrint(p.arena, "{s}:", .{key}),
                .hooks = .{ .context = p, .summaryFn = summaryHook },
                .field_names = .{ .context = p, .lookup = fieldNameHook },
            }),
        };
        try r.vc.run();
        r.state = .done;
        return r;
    }

    fn fieldNameHook(context: *anyopaque, type_name: []const u8, index: u32) ?[]const u8 {
        const p: *Program = @ptrCast(@alignCast(context));
        var it = p.sources.files.valueIterator();
        while (it.next()) |entry| {
            const loaded = entry.* orelse continue;
            if (loaded.src.fieldName(type_name, index)) |name| return name;
        }
        return null;
    }

    fn summaryHook(context: *anyopaque, caller: *vc.Vc, callee: []const u8) vc.Error!*const vc.Summary {
        const p: *Program = @ptrCast(@alignCast(context));
        const ref = p.funcs.get(callee) orelse return caller.ctx.unsupported("call to {s}, which is not in the packs", .{callee});
        if (p.ambiguous.contains(callee)) return caller.ctx.unsupported("call to {s}, which names two different functions in the packs", .{callee});
        const level = (try p.sources.levelOf(ref.pack, ref.func)) orelse
            return caller.ctx.unsupported("call to {s}, which no assurance manifest lists", .{callee});
        switch (level) {
            .verified, .trusted => {},
            else => return caller.ctx.unsupported("call to {s}, which is .{t}: only .verified and .trusted functions have contracts to rely on", .{ callee, level }),
        }
        const fqn = ref.pack.str(ref.func.fqn);
        const key = try std.fmt.allocPrint(p.arena, "{s}#{x}", .{ fqn, ref.func.id });
        if (p.runs.get(key)) |existing| if (existing.state == .running)
            return caller.ctx.unsupported("recursive call to {s}", .{callee});
        const r = try p.run(ref);
        if (r.vc.unsupported) |u| return caller.ctx.unsupported("call to {s}, which is outside the supported fragment: {s}", .{ callee, u.reason });
        if (r.summary == null) r.summary = r.vc.summarize(r.name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => return caller.ctx.unsupported("call to {s}: {s}", .{ callee, r.vc.ctx.reason }),
        };
        r.summary.?.callee = callee;
        r.summary.?.trusted = level == .trusted;
        return &r.summary.?;
    }
};
