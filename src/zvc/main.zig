//! zvc: proves the functions an assurance manifest marks `.verified`, from zig-zv AIR packs.
//!
//!   zvc [options] PATH...        PATH is a `.zvp` pack or an index directory
//!     --src DIR                  where module-relative source paths are found (default `.`)
//!     --module NAME=DIR          a different directory for the sources of one module
//!     --only TEXT                only functions whose name contains TEXT
//!     --expect FILE              lines `NAME proved|refuted|unproven`; exit 0 iff every verdict matches
//!     --z3 PATH                  the solver (default: $ZV_Z3, else `z3` on PATH)
//!     --timeout MS               per obligation (default 10000)
//!     --smt                      print the SMT-LIB2 sent to the solver
//!     --list                     list the functions the manifests mark `.verified` and stop
//!     --survey                   for every classified function: level, contracts and checked operations in its AIR
//! Exit status: 0 when everything is proved (or matches --expect), 1 otherwise, 2 for bad usage.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zv_air = @import("zv_air");
const schema = zv_air.schema;
const source = @import("source.zig");
const vc = @import("vc.zig");
const check = @import("check.zig");
const term = @import("term.zig");

const Verdict = enum { proved, refuted, unproven };

const Options = struct {
    paths: []const []const u8 = &.{},
    src: []const u8 = ".",
    modules: []const [2][]const u8 = &.{},
    only: ?[]const u8 = null,
    expect: ?[]const u8 = null,
    z3: ?[]const u8 = null,
    timeout_ms: u32 = 10_000,
    smt: bool = false,
    list: bool = false,
    survey: bool = false,
};

const Result = struct {
    name: []const u8,
    verdict: Verdict,
    obligations: usize,
    failures: []const check.Failure,
    unsupported: ?vc.Unsupported,
    pack: *const schema.Pack,
    ms: u64,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;
    const opts = parseArgs(arena, try init.minimal.args.toSlice(arena)) orelse return usage();
    const z3 = opts.z3 orelse init.environ_map.get("ZV_Z3") orelse "z3";

    var loaded: std.ArrayList(zv_air.reader.Loaded) = .empty;
    defer for (loaded.items) |l| l.deinit(gpa);
    for (opts.paths) |path| try loadPath(gpa, io, arena, path, &loaded);
    if (loaded.items.len == 0) fatal("no packs found", .{});

    var sources: Sources = .{ .gpa = gpa, .io = io, .arena = arena, .opts = opts };
    var results: std.ArrayList(Result) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var trace_buffer: [4096]u8 = undefined;
    for (loaded.items) |*l| {
        const pack = &l.pack;
        for (pack.t.funcs) |f| {
            const src = (try sources.forFile(pack, f.file)) orelse continue;
            const fqn = pack.str(f.fqn);
            const name = try source.declaredName(arena, fqn);
            if (opts.only) |only| if (std.mem.indexOf(u8, name, only) == null) continue;
            if (opts.survey) {
                if (src.levels.get(name)) |level| try survey(out, pack, f, name, level);
                continue;
            }
            if (!try sources.isVerified(src, name)) continue;
            const key = try std.fmt.allocPrint(arena, "{s}#{x}", .{ fqn, f.id });
            if ((try seen.getOrPut(arena, key)).found_existing) continue;
            if (opts.list) {
                try out.print("{s}\n", .{fqn});
                continue;
            }
            if (pack.meta.optimize == .fast or pack.meta.optimize == .small)
                fatal("{s}: the pack was exported in {t}, where contracts compile out; export in Debug or ReleaseSafe", .{ fqn, pack.meta.optimize });
            var trace_writer = out;
            _ = &trace_writer;
            _ = &trace_buffer;
            const result = try verifyOne(gpa, io, arena, pack, f, src, name, z3, opts, if (opts.smt) out else null);
            try results.append(arena, result);
            try report(out, &sources, result);
            try out.flush();
        }
    }
    if (opts.list or opts.survey) return out.flush();

    var counts: [3]usize = @splat(0);
    for (results.items) |r| counts[@backingInt(r.verdict)] += 1;
    try out.print("\nzvc: {d} proved, {d} refuted, {d} unproven\n", .{ counts[0], counts[1], counts[2] });
    var ok = counts[1] == 0 and counts[2] == 0;
    if (opts.expect) |path| ok = try compareExpected(io, arena, out, path, results.items);
    try out.flush();
    if (!ok) std.process.exit(1);
}

fn parseArgs(arena: Allocator, args: []const [:0]const u8) ?Options {
    var o: Options = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    var modules: std.ArrayList([2][]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (!std.mem.startsWith(u8, a, "--")) {
            paths.append(arena, a) catch return null;
            continue;
        }
        if (std.mem.eql(u8, a, "--smt")) {
            o.smt = true;
        } else if (std.mem.eql(u8, a, "--list")) {
            o.list = true;
        } else if (std.mem.eql(u8, a, "--survey")) {
            o.survey = true;
        } else {
            i += 1;
            if (i >= args.len) return null;
            const v: []const u8 = args[i];
            if (std.mem.eql(u8, a, "--src")) {
                o.src = v;
            } else if (std.mem.eql(u8, a, "--only")) {
                o.only = v;
            } else if (std.mem.eql(u8, a, "--expect")) {
                o.expect = v;
            } else if (std.mem.eql(u8, a, "--z3")) {
                o.z3 = v;
            } else if (std.mem.eql(u8, a, "--timeout")) {
                o.timeout_ms = std.fmt.parseInt(u32, v, 10) catch return null;
            } else if (std.mem.eql(u8, a, "--module")) {
                const eq = std.mem.indexOfScalar(u8, v, '=') orelse return null;
                modules.append(arena, .{ v[0..eq], v[eq + 1 ..] }) catch return null;
            } else return null;
        }
    }
    if (paths.items.len == 0) return null;
    o.paths = paths.items;
    o.modules = modules.items;
    return o;
}

fn usage() noreturn {
    std.debug.print("usage: zvc [--src DIR] [--module NAME=DIR] [--only TEXT] [--expect FILE] [--z3 PATH] [--timeout MS] [--smt] [--list] PACK|INDEX_DIR...\n", .{});
    std.process.exit(2);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zvc: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn loadPath(gpa: Allocator, io: Io, arena: Allocator, path: []const u8, out: *std.ArrayList(zv_air.reader.Loaded)) !void {
    if (std.mem.endsWith(u8, path, schema.pack_ext)) {
        const l = zv_air.loadPack(gpa, io, .cwd(), path) catch |err| fatal("{s}: {t}", .{ path, err });
        l.pack.validate() catch fatal("{s}: invalid pack", .{path});
        try out.append(arena, l);
        return;
    }
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| fatal("{s}: {t}", .{ path, err });
    defer dir.close(io);
    const set = zv_air.Set.open(gpa, io, dir) catch |err| fatal("{s}: {t}", .{ path, err });
    defer gpa.free(set.loaded);
    for (set.loaded) |l| {
        l.pack.validate() catch fatal("{s}: invalid pack", .{path});
        try out.append(arena, l);
    }
}

/// Sources by module-relative path, with their manifests.
const Sources = struct {
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    opts: Options,
    files: std.StringHashMapUnmanaged(?*Loaded) = .empty,

    const Loaded = struct {
        src: source.Source,
        dir: []const u8,
        rel: []const u8,
        levels: std.StringHashMapUnmanaged(source.Level) = .empty,
    };

    fn forFile(s: *Sources, pack: *const schema.Pack, id: schema.FileId) !?*Loaded {
        const rec = pack.t.files[@backingInt(id)];
        const module = pack.str(rec.module);
        const rel = pack.str(rec.path);
        const key = try std.fmt.allocPrint(s.arena, "{s}:{s}", .{ module, rel });
        const gop = try s.files.getOrPut(s.arena, key);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = null;
        const dir = for (s.opts.modules) |m| {
            if (std.mem.eql(u8, m[0], module)) break m[1];
        } else s.opts.src;
        const full = try std.fs.path.join(s.arena, &.{ dir, rel });
        const text = Io.Dir.cwd().readFileAllocOptions(s.io, full, s.arena, .limited(64 << 20), .@"1", 0) catch return null;
        const src = source.Source.parse(s.arena, rel, text) catch return null;
        const loaded = try s.arena.create(Loaded);
        loaded.* = .{ .src = src, .dir = dir, .rel = rel };
        for (try loaded.src.entries(s.arena)) |e| try loaded.levels.put(s.arena, e.name, e.level);
        gop.value_ptr.* = loaded;
        return loaded;
    }

    fn isVerified(_: *Sources, l: *Loaded, name: []const u8) !bool {
        return (l.levels.get(name) orelse return false) == .verified;
    }

    fn where(s: *Sources, pack: *const schema.Pack, loc: schema.LocId) ?struct { path: []const u8, line: u32, col: u32, src: ?*Loaded } {
        if (loc == .none) return null;
        const rec = pack.t.locs[@backingInt(loc)];
        const file = pack.t.files[@backingInt(rec.file)];
        const loaded = s.forFile(pack, rec.file) catch null;
        const joined = if (loaded) |l| std.fs.path.join(s.arena, &.{ l.dir, l.rel }) catch pack.str(file.path) else pack.str(file.path);
        const path = s.arena.dupe(u8, joined) catch return null;
        std.mem.replaceScalar(u8, path, '\\', '/');
        return .{ .path = path, .line = rec.line, .col = rec.col, .src = loaded };
    }
};

fn verifyOne(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    pack: *const schema.Pack,
    f: schema.Func,
    src: *Sources.Loaded,
    name: []const u8,
    z3: []const u8,
    opts: Options,
    trace: ?*Io.Writer,
) !Result {
    const start = Io.Clock.awake.now(io);
    var pool = term.Pool.init(gpa);
    defer pool.deinit();
    const names = try src.src.paramNames(arena, if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| name[i + 1 ..] else name, f.line) orelse &.{};
    var v = try vc.Vc.init(gpa, arena, &pool, pack, f, names);
    try v.run();
    var result: Result = .{
        .name = name,
        .verdict = .proved,
        .obligations = 0,
        .failures = &.{},
        .unsupported = v.unsupported,
        .pack = pack,
        .ms = 0,
    };
    const outcome = check.discharge(gpa, io, arena, &v, .{ .z3 = z3, .timeout_ms = opts.timeout_ms, .trace = trace }) catch |err| switch (err) {
        error.FileNotFound => fatal("cannot run the solver `{s}`; install Z3 and set ZV_Z3 or pass --z3", .{z3}),
        else => |e| return e,
    };
    result.obligations = outcome.obligations;
    result.failures = outcome.failures;
    var refuted = false;
    for (outcome.failures) |fl| refuted = refuted or fl.ce != null;
    result.verdict = if (refuted) .refuted else if (outcome.failures.len != 0 or v.unsupported != null) .unproven else .proved;
    result.ms = @intCast(@divTrunc(start.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_ms));
    return result;
}

fn report(out: *Io.Writer, sources: *Sources, r: Result) !void {
    const label = switch (r.verdict) {
        .proved => "proved   ",
        .refuted => "REFUTED  ",
        .unproven => "UNPROVEN ",
    };
    try out.print("{s}{s}: {d} obligations, {d} ms\n", .{ label, r.name, r.obligations, r.ms });
    for (r.failures) |fl| {
        try printWhere(out, sources, r.pack, fl.ob.loc);
        if (fl.ce) |ce| {
            try out.print(": {s}\n", .{fl.ob.text});
            try printExcerpt(out, sources, r.pack, fl.ob.loc);
            if (fl.ob.approx) try out.writeAll("      note: the path abstracts a loop by its invariant; if this is not a real execution, strengthen the invariant\n");
            if (ce.inputs.len != 0) {
                try out.writeAll("      inputs:");
                for (ce.inputs) |l| try out.print(" {s} = {s};", .{ l.name, l.text });
                try out.writeByte('\n');
            }
            if (ce.locals.len != 0) {
                try out.writeAll("      locals:");
                for (ce.locals) |l| try out.print(" {s} = {s};", .{ l.name, l.text });
                try out.writeByte('\n');
            }
        } else {
            try out.print(": {s} (the solver gave up)\n", .{fl.ob.text});
        }
    }
    if (r.unsupported) |u| {
        try printWhere(out, sources, r.pack, u.loc);
        try out.print(": outside the supported fragment: {s}\n", .{u.reason});
    }
}

fn printWhere(out: *Io.Writer, sources: *Sources, pack: *const schema.Pack, loc: schema.LocId) !void {
    if (sources.where(pack, loc)) |w| try out.print("    {s}:{d}:{d}", .{ w.path, w.line, w.col }) else try out.writeAll("    (no position)");
}

fn printExcerpt(out: *Io.Writer, sources: *Sources, pack: *const schema.Pack, loc: schema.LocId) !void {
    const w = sources.where(pack, loc) orelse return;
    const l = w.src orelse return;
    const text = l.src.lineText(w.line) orelse return;
    try out.print("      {d: >5} | {s}\n", .{ w.line, text });
    try out.print("      {s} | ", .{"     "});
    for (0..w.col -| 1) |i| try out.writeByte(if (i < text.len and text[i] == '\t') '\t' else ' ');
    try out.writeAll("^\n");
}

/// What the AIR says about a classified function: the contracts it carries and the operations that
/// Zig checks at run time in safe builds.
fn survey(out: *Io.Writer, pack: *const schema.Pack, f: schema.Func, name: []const u8, level: source.Level) !void {
    var counts: struct { requires: u32 = 0, ensures: u32 = 0, invariant: u32 = 0, assume: u32 = 0, checked: u32 = 0, insts: u32 = 0 } = .{};
    surveyInsts(pack, pack.instsOf(f.insts), &counts);
    try out.print("{s:<32} {t:<9} {d} params, {d} requires, {d} ensures, {d} invariant, {d} assume, {d} checked ops, {d} instructions, {d} undecoded\n", .{
        name, level, f.params.len, counts.requires, counts.ensures, counts.invariant, counts.assume, counts.checked, counts.insts, f.unsupported,
    });
}

fn surveyInsts(pack: *const schema.Pack, insts: []const schema.Inst, counts: anytype) void {
    for (insts) |inst| {
        counts.insts += 1;
        const tag = @tagName(inst.tag);
        if (std.mem.endsWith(u8, tag, "_safe")) counts.checked += 1;
        if (inst.tag == .dbg_inline_block) for (pack.attrsOf(inst)) |a| {
            if (a.key != .callee) continue;
            const callee = pack.calleeName(@fromBackingInt(@intCast(a.value)));
            if (std.mem.eql(u8, callee, "zv.requires")) counts.requires += 1;
            if (std.mem.eql(u8, callee, "zv.ensures")) counts.ensures += 1;
            if (std.mem.eql(u8, callee, "zv.invariant")) counts.invariant += 1;
            if (std.mem.eql(u8, callee, "zv.assume")) counts.assume += 1;
        };
        for (pack.bodiesOf(inst)) |b| surveyInsts(pack, pack.instsOf(b.insts), counts);
    }
}

fn compareExpected(io: Io, arena: Allocator, out: *Io.Writer, path: []const u8, results: []const Result) !bool {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| fatal("{s}: {t}", .{ path, err });
    var ok = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next().?;
        const want = std.meta.stringToEnum(Verdict, it.next() orelse "") orelse fatal("{s}: bad line `{s}`", .{ path, line });
        const got = for (results) |r| {
            if (std.mem.eql(u8, r.name, name)) break r.verdict;
        } else {
            try out.print("expected {s} {t}, but it was not verified at all\n", .{ name, want });
            ok = false;
            continue;
        };
        if (got != want) {
            try out.print("expected {s} {t}, got {t}\n", .{ name, want, got });
            ok = false;
        }
    }
    for (results) |r| {
        if (std.mem.indexOf(u8, text, r.name) == null) {
            try out.print("{s} is {t} but has no expectation\n", .{ r.name, r.verdict });
            ok = false;
        }
    }
    if (ok) try out.writeAll("zvc: every verdict matches its expectation\n");
    return ok;
}
