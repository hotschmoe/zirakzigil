//! zvc: proves the functions an assurance manifest marks `.verified`, from zig-zv AIR packs.
//!
//!   zvc [options] PATH...        PATH is a `.zvp` pack or an index directory
//!     --src DIR                  where module-relative source paths are found (default `.`)
//!     --module NAME=DIR          a different directory for the sources of one module
//!     --only TEXT                only functions whose name contains TEXT
//!     --expect FILE              lines `NAME proved|refuted|unproven`; exit 0 iff every verdict matches
//!     --pins FILE                lines `SHA256 PATH`: the sources the packs were exported from; any difference is an error
//!     --total                    a loop without `zv.decreases` leaves its function unproven
//!     --z3 PATH                  the solver (default: $ZV_Z3, else `z3` on PATH)
//!     --timeout MS               per obligation (default 10000)
//!     --obligations              list every obligation of each function, proved or not
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
const sources = @import("sources.zig");
const vc = @import("vc.zig");
const check = @import("check.zig");
const program = @import("program.zig");

const Verdict = enum { proved, refuted, unproven };

const Options = struct {
    paths: []const []const u8 = &.{},
    dirs: sources.Dirs = .{},
    only: ?[]const u8 = null,
    expect: ?[]const u8 = null,
    z3: ?[]const u8 = null,
    timeout_ms: u32 = 10_000,
    smt: bool = false,
    list: bool = false,
    survey: bool = false,
    total: bool = false,
    obligations: bool = false,
    pins: ?[]const u8 = null,
};

const Result = struct {
    name: []const u8,
    verdict: Verdict,
    obligations: usize,
    failures: []const check.Failure,
    unsupported: ?vc.Unsupported,
    /// Loops without a measure, when termination is required and these are why the function is unproven.
    unbounded: []const schema.LocId,
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

    if (opts.pins) |path| try checkPins(io, arena, path);
    var loaded: std.ArrayList(zv_air.reader.Loaded) = .empty;
    defer for (loaded.items) |l| l.deinit(gpa);
    for (opts.paths) |path| try loadPath(gpa, io, arena, path, &loaded);
    if (loaded.items.len == 0) fatal("no packs found", .{});
    var packs: std.ArrayList(*const schema.Pack) = .empty;
    for (loaded.items) |*l| try packs.append(arena, &l.pack);

    var srcs: sources.Sources = .{ .io = io, .arena = arena, .dirs = opts.dirs };
    var prog = try program.Program.init(gpa, arena, &srcs, packs.items);
    defer prog.deinit();

    var results: std.ArrayList(Result) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (packs.items) |pack| {
        for (pack.t.funcs) |f| {
            const level = (try srcs.levelOf(pack, f)) orelse continue;
            const fqn = pack.str(f.fqn);
            const name = try source.declaredName(arena, fqn);
            if (opts.only) |only| if (std.mem.indexOf(u8, name, only) == null) continue;
            if (opts.survey) {
                try survey(out, pack, f, name, level);
                continue;
            }
            if (level != .verified) continue;
            const key = try std.fmt.allocPrint(arena, "{s}#{x}", .{ fqn, f.id });
            if ((try seen.getOrPut(arena, key)).found_existing) continue;
            if (opts.list) {
                try out.print("{s}\n", .{fqn});
                continue;
            }
            if (pack.meta.optimize == .fast or pack.meta.optimize == .small)
                fatal("{s}: the pack was exported in {t}, where contracts compile out; export in Debug or ReleaseSafe", .{ fqn, pack.meta.optimize });
            const result = try verifyOne(gpa, io, arena, &prog, .{ .pack = pack, .func = f }, z3, opts, if (opts.smt) out else null);
            try results.append(arena, result);
            try report(out, &srcs, result);
            if (opts.obligations) {
                const r = try prog.run(.{ .pack = pack, .func = f });
                for (r.vc.obligations.items) |ob| {
                    try printWhere(out, &srcs, pack, ob.loc);
                    try out.print(": {s}\n", .{ob.text});
                }
            }
            try out.flush();
        }
    }
    if (opts.list or opts.survey) return out.flush();

    // A function the manifest calls .verified that the packs do not contain was never looked at.
    var files = srcs.files.valueIterator();
    while (files.next()) |entry| {
        const l = entry.* orelse continue;
        var levels = l.levels.iterator();
        while (levels.next()) |e| {
            if (e.value_ptr.* != .verified) continue;
            if (opts.only) |only| if (std.mem.indexOf(u8, e.key_ptr.*, only) == null) continue;
            if (seenName(&prog, e.key_ptr.*)) continue;
            const result: Result = .{
                .name = e.key_ptr.*,
                .verdict = .unproven,
                .obligations = 0,
                .failures = &.{},
                .unsupported = .{ .reason = "the manifest says .verified but no such function is in the packs: export again, or the function is generic and never instantiated", .loc = .none },
                .unbounded = &.{},
                .pack = packs.items[0],
                .ms = 0,
            };
            try results.append(arena, result);
            try report(out, &srcs, result);
        }
    }

    var counts: [3]usize = @splat(0);
    for (results.items) |r| counts[@backingInt(r.verdict)] += 1;
    try out.print("\nzvc: {d} proved, {d} refuted, {d} unproven\n", .{ counts[0], counts[1], counts[2] });
    var ok = counts[1] == 0 and counts[2] == 0;
    if (opts.expect) |path| ok = try compareExpected(io, arena, out, path, results.items);
    try out.flush();
    if (!ok) std.process.exit(1);
}

fn seenName(prog: *program.Program, name: []const u8) bool {
    var it = prog.funcs.iterator();
    while (it.next()) |e| {
        const declared = source.declaredName(prog.arena, e.key_ptr.*) catch return false;
        if (std.mem.eql(u8, declared, name)) return true;
    }
    return false;
}

/// Each line is `SHA256  PATH`, as `sha256sum` writes it. A source that changed since the packs were
/// exported means the verdicts would be about another program.
fn checkPins(io: Io, arena: Allocator, path: []const u8) !void {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| fatal("{s}: {t}", .{ path, err });
    var lines = std.mem.splitScalar(u8, text, '\n');
    var stale = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const want = it.next() orelse continue;
        const file = std.mem.trimStart(u8, it.rest(), " \t*");
        const bytes = Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(64 << 20)) catch |err| fatal("{s}: {t}", .{ file, err });
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        // Line ends are not content: a checkout that converts them must not look like an edit.
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var lines_of_file = std.mem.splitScalar(u8, bytes, '\n');
        var first = true;
        while (lines_of_file.next()) |l| {
            if (!first) hasher.update("\n");
            first = false;
            hasher.update(std.mem.trimEnd(u8, l, "\r"));
        }
        hasher.final(&digest);
        const got = std.fmt.bytesToHex(digest, .lower);
        if (!std.ascii.eqlIgnoreCase(&got, want)) {
            std.debug.print("zvc: {s} changed since the packs were exported\n", .{file});
            stale = true;
        }
    }
    if (stale) fatal("export the packs again (see {s})", .{path});
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
        } else if (std.mem.eql(u8, a, "--total")) {
            o.total = true;
        } else if (std.mem.eql(u8, a, "--obligations")) {
            o.obligations = true;
        } else {
            i += 1;
            if (i >= args.len) return null;
            const v: []const u8 = args[i];
            if (std.mem.eql(u8, a, "--src")) {
                o.dirs.default = v;
            } else if (std.mem.eql(u8, a, "--only")) {
                o.only = v;
            } else if (std.mem.eql(u8, a, "--expect")) {
                o.expect = v;
            } else if (std.mem.eql(u8, a, "--pins")) {
                o.pins = v;
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
    o.dirs.by_module = modules.items;
    return o;
}

fn usage() noreturn {
    std.debug.print("usage: zvc [--src DIR] [--module NAME=DIR] [--only TEXT] [--expect FILE] [--total] [--z3 PATH] [--timeout MS] [--smt] [--list] [--survey] PACK|INDEX_DIR...\n", .{});
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

fn verifyOne(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    prog: *program.Program,
    ref: program.Ref,
    z3: []const u8,
    opts: Options,
    trace: ?*Io.Writer,
) !Result {
    const start = Io.Clock.awake.now(io);
    const r = try prog.run(ref);
    var result: Result = .{
        .name = r.name,
        .verdict = .proved,
        .obligations = 0,
        .failures = &.{},
        .unsupported = r.vc.unsupported,
        .unbounded = &.{},
        .pack = ref.pack,
        .ms = 0,
    };
    const outcome = check.discharge(gpa, io, arena, &r.vc, .{ .z3 = z3, .timeout_ms = opts.timeout_ms, .trace = trace }) catch |err| switch (err) {
        error.FileNotFound => fatal("cannot run the solver `{s}`; install Z3 and set ZV_Z3 or pass --z3", .{z3}),
        else => |e| return e,
    };
    result.obligations = outcome.obligations;
    result.failures = outcome.failures;
    var refuted = false;
    for (outcome.failures) |fl| refuted = refuted or fl.ce != null;
    result.unbounded = r.vc.unbounded_loops.items;
    const unproven = outcome.failures.len != 0 or r.vc.unsupported != null or (opts.total and result.unbounded.len != 0);
    result.verdict = if (refuted) .refuted else if (unproven) .unproven else .proved;
    result.ms = @intCast(@divTrunc(start.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_ms));
    return result;
}

fn report(out: *Io.Writer, srcs: *sources.Sources, r: Result) !void {
    const label = switch (r.verdict) {
        .proved => "proved   ",
        .refuted => "REFUTED  ",
        .unproven => "UNPROVEN ",
    };
    try out.print("{s}{s}: {d} obligations, {d} ms\n", .{ label, r.name, r.obligations, r.ms });
    for (r.failures) |fl| {
        try printWhere(out, srcs, r.pack, fl.ob.loc);
        if (fl.ce) |ce| {
            try out.print(": {s}\n", .{fl.ob.text});
            try printExcerpt(out, srcs, r.pack, fl.ob.loc);
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
        try printWhere(out, srcs, r.pack, u.loc);
        try out.print(": outside the supported fragment: {s}\n", .{u.reason});
    }
    for (r.unbounded) |loc| {
        try printWhere(out, srcs, r.pack, loc);
        try out.writeAll(": this loop states no zv.decreases, so only partial correctness is shown\n");
    }
}

fn printWhere(out: *Io.Writer, srcs: *sources.Sources, pack: *const schema.Pack, loc: schema.LocId) !void {
    if (srcs.where(pack, loc)) |w| try out.print("    {s}:{d}:{d}", .{ w.path, w.line, w.col }) else try out.writeAll("    (no position)");
}

fn printExcerpt(out: *Io.Writer, srcs: *sources.Sources, pack: *const schema.Pack, loc: schema.LocId) !void {
    const w = srcs.where(pack, loc) orelse return;
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
    var counts: struct { requires: u32 = 0, ensures: u32 = 0, invariant: u32 = 0, decreases: u32 = 0, assume: u32 = 0, checked: u32 = 0, insts: u32 = 0 } = .{};
    surveyInsts(pack, pack.instsOf(f.insts), &counts);
    try out.print("{s:<32} {t:<9} {d} params, {d} requires, {d} ensures, {d} invariant, {d} decreases, {d} assume, {d} checked ops, {d} instructions, {d} undecoded\n", .{
        name, level, f.params.len, counts.requires, counts.ensures, counts.invariant, counts.decreases, counts.assume, counts.checked, counts.insts, f.unsupported,
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
            if (std.mem.eql(u8, callee, "zv.decreases")) counts.decreases += 1;
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
