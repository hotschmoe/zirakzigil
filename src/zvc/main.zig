//! zvc: proves the functions an assurance manifest marks `.verified`, from zig-zv AIR packs.
//!
//!   zvc [options] PATH...        PATH is a `.zvp` pack or an index directory
//!     --src DIR                  where module-relative source paths are found (default `.`)
//!     --module NAME=DIR          a different directory for the sources of one module
//!     --only PATH                only functions whose name has PATH as dotted components (`min` selects `a.min`, not `a.minMul`; the `.verified` functions they rely on are proved too)
//!     --expect FILE              lines `NAME proved|refuted|unproven`; exit 0 iff every verdict matches
//!     --pins FILE                lines `SHA256 PATH`: the sources the packs were exported from; any difference is an error
//!     --total                    a loop without `zv.decreases` leaves its function unproven
//!     --max-trusted N            fail when the proofs assume more than N distinct `.trusted` functions
//!     --max-assume N             fail when the proofs rest on more than N distinct `zv.assume` calls
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
    max_trusted: ?usize = null,
    max_assume: ?usize = null,
    /// Set by the supervisor: this process reports its progress and skips the functions it crashed on.
    supervised: bool = false,
    crashed: []const []const u8 = &.{},
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
    /// Run only because a verified function relies on it.
    callee: bool = false,
    /// The verified callees this verdict relies on that are not proved: the verdict cannot be `proved`.
    blocked_by: []const []const u8 = &.{},
    /// The `.trusted` functions the proof takes on faith: their contracts, and that they do not panic.
    assumes: []const []const u8 = &.{},
    /// The `zv.assume` calls the proof takes as premises, as `path:line`: its own and its callees'.
    premises: []const []const u8 = &.{},
    /// The ceiling that its assumptions exceed: the proof is not accepted.
    capped: ?[]const u8 = null,
};

/// A verified function as the driver sees it: the others its proof rests on, by index.
const Entry = struct {
    result: Result,
    ref: ?program.Ref,
    deps: []const usize = &.{},
    trusted: []const []const u8 = &.{},
    settled: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;
    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(arena, args) orelse return usage();
    if (!opts.supervised and !opts.list and !opts.survey and !opts.smt) return supervise(io, arena, args);
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
    prog.track = opts.supervised;
    prog.crashed = opts.crashed;

    var entries: std.ArrayList(Entry) = .empty;
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    for (packs.items) |pack| {
        for (pack.t.funcs) |f| {
            const level = (try srcs.levelOf(pack, f)) orelse continue;
            const fqn = pack.str(f.fqn);
            const name = try source.declaredName(arena, fqn);
            if (opts.only) |only| if (!zv_air.names.selects(name, only)) continue;
            if (opts.survey) {
                try survey(out, pack, f, name, level);
                continue;
            }
            if (level != .verified) continue;
            const key = try std.fmt.allocPrint(arena, "{s}#{x}", .{ fqn, f.id });
            const gop = try index.getOrPut(arena, key);
            if (gop.found_existing) continue;
            if (opts.list) {
                try out.print("{s}\n", .{fqn});
                continue;
            }
            gop.value_ptr.* = entries.items.len;
            try entries.append(arena, try verifyEntry(gpa, io, arena, &prog, .{ .pack = pack, .func = f }, z3, opts, if (opts.smt) out else null));
        }
    }
    if (opts.list or opts.survey) return out.flush();

    // A proof that relies on a callee's contract holds only if the callee is proved too, whatever --only selected.
    var at: usize = 0;
    while (at < entries.items.len) : (at += 1) {
        const ref = entries.items[at].ref orelse continue;
        var deps: std.ArrayList(usize) = .empty;
        var trusted: std.ArrayList([]const u8) = .empty;
        for ((try prog.run(ref)).vc.relied.items) |summary| {
            if (summary.trusted) {
                try addUnique(arena, &trusted, try source.declaredName(arena, summary.callee));
                continue;
            }
            const callee = prog.funcs.get(summary.callee).?;
            const key = try std.fmt.allocPrint(arena, "{s}#{x}", .{ callee.pack.str(callee.func.fqn), callee.func.id });
            const gop = try index.getOrPut(arena, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = entries.items.len;
                var entry = try verifyEntry(gpa, io, arena, &prog, callee, z3, opts, if (opts.smt) out else null);
                entry.result.callee = true;
                try entries.append(arena, entry);
            }
            try deps.append(arena, gop.value_ptr.*);
        }
        entries.items[at].deps = deps.items;
        entries.items[at].trusted = trusted.items;
    }

    // A function the manifest calls .verified that the packs do not contain was never looked at.
    var files = srcs.files.valueIterator();
    while (files.next()) |entry| {
        const l = entry.* orelse continue;
        var levels = l.levels.iterator();
        while (levels.next()) |e| {
            if (e.value_ptr.* != .verified) continue;
            if (opts.only) |only| if (!zv_air.names.selects(e.key_ptr.*, only)) continue;
            if (seenName(&prog, e.key_ptr.*)) continue;
            try entries.append(arena, .{ .ref = null, .result = .{
                .name = e.key_ptr.*,
                .verdict = .unproven,
                .obligations = 0,
                .failures = &.{},
                .unsupported = .{ .reason = "the manifest says .verified but no such function is in the packs: export again, or the function is generic and never instantiated", .loc = .none },
                .unbounded = &.{},
                .pack = packs.items[0],
                .ms = 0,
            } });
        }
    }

    var results: std.ArrayList(Result) = .empty;
    var assumed: std.ArrayList([]const u8) = .empty;
    var premises: std.ArrayList([]const u8) = .empty;
    var counts: [3]usize = @splat(0);
    for (0..entries.items.len) |i| try settle(arena, entries.items, i);
    for (entries.items) |e| {
        for (e.result.assumes) |name| try addUnique(arena, &assumed, name);
        for (e.result.premises) |site| try addUnique(arena, &premises, site);
    }
    const over_trusted = if (opts.max_trusted) |limit| assumed.items.len > limit else false;
    const over_assume = if (opts.max_assume) |limit| premises.items.len > limit else false;
    for (entries.items) |*e| {
        const r = &e.result;
        if (r.verdict != .proved) continue;
        if (over_trusted and r.assumes.len != 0) r.capped = "--max-trusted";
        if (over_assume and r.premises.len != 0) r.capped = "--max-assume";
        if (r.capped != null) r.verdict = .unproven;
    }
    for (entries.items) |e| {
        counts[@backingInt(e.result.verdict)] += 1;
        try results.append(arena, e.result);
        try report(out, &srcs, e.result);
        if (opts.obligations) if (e.ref) |ref| for ((try prog.run(ref)).vc.obligations.items) |ob| {
            try printWhere(out, &srcs, ref.pack, ob.loc);
            try out.print(": {s}\n", .{ob.text});
        };
        try out.flush();
    }
    try out.print("\nzvc: {d} proved, {d} refuted, {d} unproven\n", .{ counts[0], counts[1], counts[2] });
    var ok = counts[1] == 0 and counts[2] == 0;
    if (opts.expect) |path| ok = try compareExpected(io, arena, out, path, results.items);
    if (assumed.items.len != 0) {
        try out.print("zvc: {d} trusted assumption(s), not machine-checked:", .{assumed.items.len});
        for (assumed.items, 0..) |name, i| try out.print("{s} {s}", .{ if (i == 0) "" else ",", name });
        try out.writeByte('\n');
    }
    if (premises.items.len != 0) {
        try out.print("zvc: {d} zv.assume premise(s), not proved:", .{premises.items.len});
        for (premises.items, 0..) |site, i| try out.print("{s} {s}", .{ if (i == 0) "" else ",", site });
        try out.writeByte('\n');
    }
    if (over_assume) {
        try out.print("zvc: more zv.assume premises than the {d} allowed\n", .{opts.max_assume.?});
        ok = false;
    }
    if (over_trusted) {
        try out.print("zvc: more trusted assumptions than the {d} allowed\n", .{opts.max_trusted.?});
        ok = false;
    }
    try out.flush();
    if (!ok) std.process.exit(1);
}

/// Runs the verification in a child process. A crash of the verifier in one function (a bug in zvc, not a
/// verdict) is reported, that function is UNPROVEN, and the others get their verdicts from a second run.
fn supervise(io: Io, arena: Allocator, args: []const [:0]const u8) !void {
    const exe = try std.process.executablePathAlloc(io, arena);
    var crashed: std.ArrayList([]const u8) = .empty;
    while (true) {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ exe, "--supervised" });
        for (crashed.items) |key| try argv.appendSlice(arena, &.{ "--crashed", key });
        for (args[1..]) |a| try argv.append(arena, a);
        var child = try std.process.spawn(io, .{ .argv = argv.items, .stderr = .pipe });
        var buffer: [4096]u8 = undefined;
        var reader = child.stderr.?.readerStreaming(io, &buffer);
        const log = reader.interface.allocRemaining(arena, .unlimited) catch |err| fatal("cannot read the verifier's output: {t}", .{err});
        const term = try child.wait(io);

        var open: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, log, '\n');
        while (lines.next()) |line| {
            const rest = std.mem.trimStart(u8, line, "\r");
            if (!std.mem.startsWith(u8, rest, program.Program.progress_prefix)) {
                if (line.len != 0 or lines.peek() != null) std.debug.print("{s}\n", .{line});
                continue;
            }
            var it = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, rest[program.Program.progress_prefix.len..], "\r"), ' ');
            const step = it.next() orelse continue;
            const key = it.rest();
            if (std.mem.eql(u8, step, "begin")) {
                try open.append(arena, key);
            } else if (open.items.len != 0) _ = open.pop();
        }
        const code = switch (term) {
            .exited => |c| if (c <= 2) c else null,
            else => null,
        };
        if (code) |c| if (c == 0) return else std.process.exit(c);
        const key = if (open.items.len != 0) open.items[open.items.len - 1] else fatal("the verifier crashed outside any function", .{});
        for (crashed.items) |k| if (std.mem.eql(u8, k, key)) fatal("the verifier crashed again on {s}", .{key});
        std.debug.print("zvc: the verifier crashed on {s} (a bug in zvc); the function is reported UNPROVEN\n", .{key});
        try crashed.append(arena, key);
    }
}

fn addUnique(arena: Allocator, list: *std.ArrayList([]const u8), name: []const u8) Allocator.Error!void {
    for (list.items) |x| if (std.mem.eql(u8, x, name)) return;
    try list.append(arena, name);
}

/// Fixes the verdict of a function once the functions it relies on are fixed: a proof that rests on a contract
/// nobody proved is no proof, and it takes on faith whatever its callees take on faith.
fn settle(arena: Allocator, entries: []Entry, i: usize) Allocator.Error!void {
    const e = &entries[i];
    if (e.settled) return;
    e.settled = true;
    var blocked: std.ArrayList([]const u8) = .empty;
    var assumes: std.ArrayList([]const u8) = .empty;
    var premises: std.ArrayList([]const u8) = .empty;
    for (e.trusted) |name| try addUnique(arena, &assumes, name);
    for (e.result.premises) |site| try addUnique(arena, &premises, site);
    for (e.deps) |d| {
        try settle(arena, entries, d);
        const callee = entries[d].result;
        if (callee.verdict != .proved) try addUnique(arena, &blocked, callee.name);
        for (callee.assumes) |name| try addUnique(arena, &assumes, name);
        for (callee.premises) |site| try addUnique(arena, &premises, site);
    }
    e.result.assumes = assumes.items;
    e.result.premises = premises.items;
    e.result.blocked_by = blocked.items;
    if (blocked.items.len != 0 and e.result.verdict == .proved) e.result.verdict = .unproven;
}

fn verifyEntry(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    prog: *program.Program,
    ref: program.Ref,
    z3: []const u8,
    opts: Options,
    trace: ?*Io.Writer,
) !Entry {
    if (ref.pack.meta.optimize == .fast or ref.pack.meta.optimize == .small)
        fatal("{s}: the pack was exported in {t}, where contracts compile out; export in Debug or ReleaseSafe", .{ ref.pack.str(ref.func.fqn), ref.pack.meta.optimize });
    return .{ .ref = ref, .result = try verifyOne(gpa, io, arena, prog, ref, z3, opts, trace) };
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
    var crashed: std.ArrayList([]const u8) = .empty;
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
        } else if (std.mem.eql(u8, a, "--supervised")) {
            o.supervised = true;
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
            } else if (std.mem.eql(u8, a, "--max-trusted")) {
                o.max_trusted = std.fmt.parseInt(usize, v, 10) catch return null;
            } else if (std.mem.eql(u8, a, "--max-assume")) {
                o.max_assume = std.fmt.parseInt(usize, v, 10) catch return null;
            } else if (std.mem.eql(u8, a, "--timeout")) {
                o.timeout_ms = std.fmt.parseInt(u32, v, 10) catch return null;
            } else if (std.mem.eql(u8, a, "--crashed")) {
                crashed.append(arena, v) catch return null;
            } else if (std.mem.eql(u8, a, "--module")) {
                const eq = std.mem.indexOfScalar(u8, v, '=') orelse return null;
                modules.append(arena, .{ v[0..eq], v[eq + 1 ..] }) catch return null;
            } else return null;
        }
    }
    if (paths.items.len == 0) return null;
    o.paths = paths.items;
    o.dirs.by_module = modules.items;
    o.crashed = crashed.items;
    return o;
}

fn usage() noreturn {
    std.debug.print("usage: zvc [--src DIR] [--module NAME=DIR] [--only PATH] [--expect FILE] [--total] [--max-trusted N] [--max-assume N] [--z3 PATH] [--timeout MS] [--smt] [--list] [--survey] PACK|INDEX_DIR...\n", .{});
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
    const key = try prog.keyOf(ref);
    prog.mark("begin", key);
    defer prog.mark("end", key);
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
    var premises: std.ArrayList([]const u8) = .empty;
    for (outcome.failures) |fl| refuted = refuted or (fl.ce != null and fl.ob.kind != .unchecked);
    result.unbounded = r.vc.unbounded_loops.items;
    for (r.vc.assumed.items) |loc| {
        const site = if (prog.sources.where(ref.pack, loc)) |w| try std.fmt.allocPrint(arena, "{s}:{d}", .{ w.path, w.line }) else "(no position)";
        try addUnique(arena, &premises, site);
    }
    result.premises = premises.items;
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
    try out.print("{s}{s}{s}: {d} obligations, {d} ms", .{ label, r.name, if (r.callee) " (relied on)" else "", r.obligations, r.ms });
    if (r.assumes.len != 0) {
        try out.writeAll(", assuming trusted:");
        for (r.assumes, 0..) |name, i| try out.print("{s} {s}", .{ if (i == 0) "" else ",", name });
    }
    if (r.premises.len != 0) {
        try out.writeAll(", assuming zv.assume at");
        for (r.premises, 0..) |site, i| try out.print("{s} {s}", .{ if (i == 0) "" else ",", site });
    }
    try out.writeByte('\n');
    for (r.blocked_by) |name| try out.print("    relies on {s}, which is not proved\n", .{name});
    if (r.capped) |flag| try out.print("    its assumptions exceed {s}\n", .{flag});
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

fn expects(text: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        if (std.mem.eql(u8, it.next().?, name)) return true;
    }
    return false;
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
        if (!expects(text, r.name)) {
            try out.print("{s} is {t} but has no expectation\n", .{ r.name, r.verdict });
            ok = false;
        }
    }
    if (ok) try out.writeAll("zvc: every verdict matches its expectation\n");
    return ok;
}
