//! A differential oracle for zv-own. It generates small allocator-heavy programs (gen.zig), decides by running
//! them whether they contain a memory error (harness.zig), exports them with the patched compiler and asks zv-own
//! for a verdict and for what it counted as undecided, and classifies every program:
//!
//!   true finding   the program faults and zv-own reports findings
//!   silent miss    the program faults, zv-own says `clean`, and the function's footer counts nothing
//!   counted miss   the program faults, zv-own says `clean`, but the footer counts something it did not decide
//!   false positive the program does not fault and zv-own reports findings
//!   true clean     the program does not fault and zv-own says `clean`
//!   unproven       zv-own answers UNPROVEN (neither accepted nor refuted)
//!
//! oracle run [--seed N] [--count N] [--batch N] [--out DIR] [--repo DIR] [--zig EXE] [--own EXE] [--minimize N]
//!            [--modes plain,std] [--min-evals N]
//! The patched compiler comes from ZIG_ZV (tools/zvc_export.sh). Same seed and count, same programs, same report.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const gen = @import("gen.zig");
const report = @import("report.zig");

const prelude = @embedFile("prelude.zig");
const harness_source = @embedFile("harness.zig");

const Truth = report.Truth;
const Verdict = report.Verdict;
const Class = report.Class;
const Counted = report.Counted;
const Result = report.Result;
const Own = report.Own;
const Mode = report.Mode;

const Config = struct {
    seed: u64 = 1,
    count: u32 = 1000,
    batch: u32 = 100,
    out: []const u8 = "oracle-out",
    repo: []const u8 = ".",
    zig: []const u8 = "zig",
    own: ?[]const u8 = null,
    minimize: u32 = 12,
    min_evals: u32 = 400,
    verbose: bool = false,
    modes: [2]bool = .{ true, true },
};

const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    cfg: Config,
    own: []const u8,
    exe_suffix: []const u8 = builtin.target.exeFileExt(),
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("oracle: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2 or !std.mem.eql(u8, args[1], "run")) fatal("usage: oracle run [--seed N] [--count N] [--batch N] [--out DIR] [--repo DIR] [--zig EXE] [--own EXE] [--minimize N] [--modes plain,std]", .{});
    var cfg: Config = .{};
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (std.mem.eql(u8, flag, "--verbose")) {
            cfg.verbose = true;
            continue;
        }
        if (i + 1 >= args.len) fatal("{s} needs a value", .{flag});
        i += 1;
        const value = args[i];
        if (std.mem.eql(u8, flag, "--seed")) {
            cfg.seed = try std.fmt.parseInt(u64, value, 0);
        } else if (std.mem.eql(u8, flag, "--count")) {
            cfg.count = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--batch")) {
            cfg.batch = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--out")) {
            cfg.out = value;
        } else if (std.mem.eql(u8, flag, "--repo")) {
            cfg.repo = value;
        } else if (std.mem.eql(u8, flag, "--zig")) {
            cfg.zig = value;
        } else if (std.mem.eql(u8, flag, "--own")) {
            cfg.own = value;
        } else if (std.mem.eql(u8, flag, "--minimize")) {
            cfg.minimize = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--min-evals")) {
            cfg.min_evals = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--modes")) {
            cfg.modes = .{ std.mem.find(u8, value, "plain") != null, std.mem.find(u8, value, "std") != null };
        } else fatal("unknown flag {s}", .{flag});
    }
    const own = cfg.own orelse try std.fmt.allocPrint(arena, "{s}/zig-out/bin/zv-own{s}", .{ cfg.repo, builtin.target.exeFileExt() });
    var ctx: Ctx = .{ .gpa = init.gpa, .arena = arena, .io = init.io, .env = init.environ_map, .cfg = cfg, .own = own };
    try Io.Dir.cwd().createDirPath(ctx.io, cfg.out);

    var results: std.ArrayList(*Result) = .empty;
    var first: u32 = 0;
    while (first < cfg.count) : (first += cfg.batch) {
        const n = @min(cfg.batch, cfg.count - first);
        try runBatch(&ctx, first, n, &results);
        std.debug.print("oracle: {d}/{d} programs\n", .{ first + n, cfg.count });
    }

    const minimized = try minimizeAll(&ctx, results.items);

    var out_dir = try Io.Dir.cwd().createDirPathOpen(ctx.io, cfg.out, .{});
    defer out_dir.close(ctx.io);
    try writeFile(&ctx, out_dir, "results.jsonl", report.JsonlData{ .results = results.items }, report.writeJsonl);
    try writeFile(&ctx, out_dir, "report.json", report.ReportData{ .results = results.items, .min = minimized, .cfg = reportConfig(cfg) }, report.writeJson);
    try writeFile(&ctx, out_dir, "report.md", report.ReportData{ .results = results.items, .min = minimized, .cfg = reportConfig(cfg) }, report.writeMarkdown);
    std.debug.print("oracle: report in {s}/report.md\n", .{cfg.out});
}

fn reportConfig(cfg: Config) report.Config {
    return .{ .seed = cfg.seed, .count = cfg.count, .modes = cfg.modes };
}

fn writeFile(ctx: *Ctx, dir: Io.Dir, name: []const u8, data: anytype, comptime write: anytype) !void {
    var aw: Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    try write(&aw.writer, data);
    try dir.writeFile(ctx.io, .{ .sub_path = name, .data = aw.written() });
}

const Out = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(o: Out, gpa: Allocator) void {
        gpa.free(o.stdout);
        gpa.free(o.stderr);
    }

    fn exited(o: Out) ?u8 {
        return switch (o.term) {
            .exited => |c| c,
            else => null,
        };
    }
};

fn exec(ctx: *Ctx, argv: []const []const u8, cwd: ?[]const u8, extra: []const [2][]const u8) !Out {
    var env = try ctx.env.clone(ctx.gpa);
    defer env.deinit();
    for (extra) |kv| try env.put(kv[0], kv[1]);
    const r = std.process.run(ctx.gpa, ctx.io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = &env,
    }) catch |err| fatal("cannot run {s}: {t}", .{ argv[0], err });
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

fn path(ctx: *Ctx, comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(ctx.arena, fmt, args);
}

/// The batch file: the library, then one function per program. Returns the first line of each program.
fn writeBatch(ctx: *Ctx, dir: []const u8, active: []const *Result, masks: []const gen.Mask) ![]u32 {
    var aw: Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(prelude);
    var lines: u32 = @intCast(std.mem.count(u8, aw.written(), "\n"));
    const starts = try ctx.arena.alloc(u32, active.len + 1);
    for (active, masks, 0..) |r, mask, i| {
        starts[i] = lines + 1;
        const before = aw.written().len;
        try gen.render(w, r.program, mask, false);
        lines += @intCast(std.mem.count(u8, aw.written()[before..], "\n"));
    }
    starts[active.len] = lines + 1;

    var main_src: Io.Writer.Allocating = .init(ctx.gpa);
    defer main_src.deinit();
    const m = &main_src.writer;
    try m.writeAll("const std = @import(\"std\");\nconst harness = @import(\"harness.zig\");\nconst batch = @import(\"batch.zig\");\n\n");
    try m.writeAll("pub const panic = std.debug.FullPanic(harness.onPanic);\n\nconst table = [_]harness.Entry{\n");
    for (active) |r| try m.print("    .{{ .name = \"p{d}\", .run = batch.p{d} }},\n", .{ r.program.id, r.program.id });
    try m.writeAll("};\n\npub fn main(init: std.process.Init) !void {\n    return harness.main(init, &table);\n}\n");

    var d = try Io.Dir.cwd().createDirPathOpen(ctx.io, dir, .{});
    defer d.close(ctx.io);
    try d.writeFile(ctx.io, .{ .sub_path = "batch.zig", .data = aw.written() });
    try d.writeFile(ctx.io, .{ .sub_path = "run_main.zig", .data = main_src.written() });
    try d.writeFile(ctx.io, .{ .sub_path = "harness.zig", .data = harness_source });
    try d.writeFile(ctx.io, .{ .sub_path = "zv_options.zig", .data = "pub const ghost: bool = false;\n" });
    return starts;
}

/// Compiles the batch with stock zig; the exe is `dir/run`. Returns the compiler's stderr on failure.
fn compile(ctx: *Ctx, dir: []const u8) !?[]u8 {
    const emit = try path(ctx, "-femit-bin={s}/run{s}", .{ dir, ctx.exe_suffix });
    const cache = try path(ctx, "{s}/.cache", .{ctx.cfg.out});
    const root = try path(ctx, "-Mroot={s}/run_main.zig", .{dir});
    const zv_src = try path(ctx, "-Mzv={s}/src/zv.zig", .{ctx.cfg.repo});
    const opts = try path(ctx, "-Mzv_options={s}/zv_options.zig", .{dir});
    const argv = [_][]const u8{
        ctx.cfg.zig, "build-exe", "-O", "Debug", emit,         "--cache-dir", cache,
        "--dep",     "zv",        root, "--dep", "zv_options", zv_src,        opts,
    };
    const out = try exec(ctx, &argv, null, &.{});
    defer ctx.gpa.free(out.stdout);
    if (out.exited() == @as(?u8, 0)) {
        ctx.gpa.free(out.stderr);
        return null;
    }
    return out.stderr;
}

fn compileErrorLines(stderr: []const u8, lines: *std.ArrayList(u32), gpa: Allocator) !void {
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        if (std.mem.find(u8, line, ": error:") == null) continue;
        const at = std.mem.find(u8, line, "batch.zig:") orelse continue;
        const rest = line[at + "batch.zig:".len ..];
        const end = std.mem.findScalar(u8, rest, ':') orelse continue;
        const n = std.fmt.parseInt(u32, rest[0..end], 10) catch continue;
        try lines.append(gpa, n);
    }
}

const RunOutcome = struct { truth: Truth, fault: []const u8 };

fn execute(ctx: *Ctx, dir: []const u8, index: usize) !RunOutcome {
    const exe = try path(ctx, "{s}/run{s}", .{ dir, ctx.exe_suffix });
    const idx = try path(ctx, "{d}", .{index});
    const out = try exec(ctx, &.{ exe, idx }, null, &.{});
    defer out.deinit(ctx.gpa);
    if (std.mem.find(u8, out.stderr, "FAULT ")) |at| {
        const rest = out.stderr[at + "FAULT ".len ..];
        const line = std.mem.trimEnd(u8, rest[0 .. std.mem.findScalar(u8, rest, '\n') orelse rest.len], "\r");
        return .{ .truth = .fault, .fault = try ctx.arena.dupe(u8, line) };
    }
    if (std.mem.find(u8, out.stderr, "PANIC ")) |at| {
        const rest = out.stderr[at + "PANIC ".len ..];
        const line = std.mem.trimEnd(u8, rest[0 .. std.mem.findScalar(u8, rest, '\n') orelse rest.len], "\r");
        return .{ .truth = .invalid, .fault = try ctx.arena.dupe(u8, line) };
    }
    if (out.exited() == @as(?u8, 0) and std.mem.find(u8, out.stderr, "OK") != null) return .{ .truth = .clean, .fault = "" };
    return .{ .truth = .fault, .fault = "crash (signal or access violation)" };
}

fn runBatch(ctx: *Ctx, first: u32, n: u32, results: *std.ArrayList(*Result)) !void {
    const dir = try path(ctx, "{s}/b{d:0>4}", .{ ctx.cfg.out, first / ctx.cfg.batch });
    const batch_results = try ctx.arena.alloc(Result, n);
    for (batch_results, 0..) |*r, k| {
        const p = try gen.generate(ctx.arena, ctx.cfg.seed, first + @as(u32, @intCast(k)));
        r.* = .{ .program = p, .tags = gen.tagsOf(p, try gen.fullMask(ctx.arena, p)), .truth = .clean, .detail = "" };
    }
    var active: std.ArrayList(*Result) = .empty;
    for (batch_results) |*r| try active.append(ctx.arena, r);

    var round: usize = 0;
    while (true) : (round += 1) {
        if (round == 8) fatal("{s}: the batch still does not compile after {d} rounds", .{ dir, round });
        const masks = try ctx.arena.alloc(gen.Mask, active.items.len);
        for (masks, active.items) |*m, r| m.* = try gen.fullMask(ctx.arena, r.program);
        const starts = try writeBatch(ctx, dir, active.items, masks);
        const failure = try compile(ctx, dir) orelse break;
        defer ctx.gpa.free(failure);
        var lines: std.ArrayList(u32) = .empty;
        defer lines.deinit(ctx.gpa);
        try compileErrorLines(failure, &lines, ctx.gpa);
        var dropped: usize = 0;
        var keep: std.ArrayList(*Result) = .empty;
        for (active.items, 0..) |r, i| {
            const bad = for (lines.items) |l| {
                if (l >= starts[i] and l < starts[i + 1]) break true;
            } else false;
            if (bad) {
                r.truth = .invalid;
                r.detail = "does not compile";
                dropped += 1;
            } else try keep.append(ctx.arena, r);
        }
        if (ctx.cfg.verbose) std.debug.print("{s}\n", .{failure});
        if (dropped == 0) fatal("{s}: compile error outside the generated programs:\n{s}", .{ dir, failure });
        std.debug.print("oracle: batch {s}: {d} programs do not compile, retrying\n", .{ dir, dropped });
        active = keep;
    }

    for (active.items, 0..) |r, i| {
        const o = try execute(ctx, dir, i);
        r.truth = o.truth;
        r.detail = o.fault;
    }

    var live: std.ArrayList(*Result) = .empty;
    for (active.items) |r| if (r.truth != .invalid) try live.append(ctx.arena, r);
    for (batch_results) |*r| try results.append(ctx.arena, r);
    for (0..2) |mi| {
        if (!ctx.cfg.modes[mi]) continue;
        try analyze(ctx, dir, live.items, @fromBackingInt(@intCast(mi)));
    }
}

/// Exports the batch for one mode, runs zv-own and stores the verdicts; for a program that faults and is called
/// clean it also reads the function's own footer.
fn analyze(ctx: *Ctx, dir: []const u8, rs: []const *Result, mode: Mode) !void {
    const sub = try path(ctx, "{s}/{t}", .{ dir, mode });
    const batch_zig = try path(ctx, "{s}/batch.zig", .{dir});
    const script = try path(ctx, "{s}/tools/zvc_export.sh", .{ctx.cfg.repo});
    const extra: []const [2][]const u8 = if (mode == .std) &.{.{ "ZV_AIR_STD", "1" }} else &.{};
    const ex = try exec(ctx, &.{ "sh", script, sub, batch_zig }, null, extra);
    defer ex.deinit(ctx.gpa);
    if (ex.exited() != @as(?u8, 0)) fatal("export failed ({t}):\n{s}", .{ mode, ex.stderr });
    const pack = try path(ctx, "{s}/batch.zvp", .{sub});

    const verdicts = try ownRows(ctx, dir, pack, null);
    for (rs) |r| {
        const name = try path(ctx, "batch.p{d}", .{r.program.id});
        const verdict = verdicts.get(name) orelse .missing;
        var own: Own = .{ .verdict = verdict, .counted = .{} };
        if (r.truth == .fault and verdict == .clean) own.counted = try ownFooter(ctx, dir, pack, name);
        r.own[@backingInt(mode)] = own;
    }
}

fn ownRows(ctx: *Ctx, dir: []const u8, pack: []const u8, only: ?[]const u8) !std.StringHashMapUnmanaged(Verdict) {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(ctx.arena, &.{ ctx.own, "--summary", "--module" });
    try argv.append(ctx.arena, try path(ctx, "target={s}", .{dir}));
    try argv.appendSlice(ctx.arena, &.{ "--module", try path(ctx, "zv={s}/src", .{ctx.cfg.repo}) });
    if (only) |o| try argv.appendSlice(ctx.arena, &.{ "--only", o });
    try argv.append(ctx.arena, pack);
    const out = try exec(ctx, argv.items, null, &.{});
    defer out.deinit(ctx.gpa);
    if ((out.exited() orelse 99) > 1) fatal("zv-own failed on {s}:\n{s}", .{ pack, out.stderr });
    var map: std.StringHashMapUnmanaged(Verdict) = .empty;
    var it = std.mem.splitScalar(u8, out.stdout, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const labels = [_]struct { []const u8, Verdict }{
            .{ "clean    ", .clean },
            .{ "FINDINGS ", .findings },
            .{ "UNPROVEN ", .unproven },
            .{ "COUNTED  ", .counted },
            .{ "TRUSTED  ", .trusted },
        };
        for (labels) |l| {
            if (std.mem.startsWith(u8, line, l[0])) try map.put(ctx.arena, try ctx.arena.dupe(u8, line[l[0].len..]), l[1]);
        }
    }
    return map;
}

/// What zv-own counts for the one function: every number on the "assumed", "also assumed" and "undecided" lines,
/// and the gap between decided and followed.
fn ownFooter(ctx: *Ctx, dir: []const u8, pack: []const u8, name: []const u8) !Counted {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(ctx.arena, &.{ ctx.own, "--module" });
    try argv.append(ctx.arena, try path(ctx, "target={s}", .{dir}));
    try argv.appendSlice(ctx.arena, &.{ "--module", try path(ctx, "zv={s}/src", .{ctx.cfg.repo}), "--only", name, pack });
    const out = try exec(ctx, argv.items, null, &.{});
    defer out.deinit(ctx.gpa);
    return parseFooter(out.stdout);
}

fn parseFooter(stdout: []const u8) Counted {
    var c: Counted = .{};
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const assumed = "zv-own: assumed, not checked: ";
        const also = "zv-own: also assumed: ";
        const undecided = "zv-own: undecided, counted and not reported: ";
        const decided = "zv-own: decided: ";
        if (std.mem.startsWith(u8, line, assumed)) {
            const n = leadingInts(line[assumed.len..], 2);
            c.unknown_calls = n[0];
            c.transfers = n[1];
        } else if (std.mem.startsWith(u8, line, also)) {
            const n = leadingInts(line[also.len..], 4);
            c.unmodelled = n[0];
            c.blind = n[1];
            c.dynamic_len = n[2];
            c.lent = n[3];
        } else if (std.mem.startsWith(u8, line, undecided)) {
            const n = leadingInts(line[undecided.len..], 4);
            c.maybe_alias = n[0];
            c.maybe_stale = n[1];
            c.summarized = n[2];
            c.alias_params = n[3];
        } else if (std.mem.startsWith(u8, line, decided)) {
            var nums: [4]usize = @splat(0);
            var k: usize = 0;
            var words = std.mem.tokenizeAny(u8, line[decided.len..], " ");
            while (words.next()) |word| {
                const v = std.fmt.parseInt(usize, word, 10) catch continue;
                if (k < 4) nums[k] = v;
                k += 1;
            }
            c.open_ends = nums[1] -| nums[0];
            c.open_uses = nums[3] -| nums[2];
        }
    }
    return c;
}

/// The integer that opens each of the first `n` comma separated segments of a footer line.
fn leadingInts(text: []const u8, comptime n: usize) [n]usize {
    var out: [n]usize = @splat(0);
    var segs = std.mem.splitSequence(u8, text, ", ");
    var k: usize = 0;
    while (segs.next()) |seg| : (k += 1) {
        if (k == n) break;
        const end = std.mem.findScalar(u8, seg, ' ') orelse seg.len;
        out[k] = std.fmt.parseInt(usize, seg[0..end], 10) catch 0;
    }
    return out;
}

// Minimization.

const MinResult = report.Minimized;

fn minimizeAll(ctx: *Ctx, results: []const *Result) ![]MinResult {
    var seen_text: std.StringHashMapUnmanaged(usize) = .empty;
    var found: std.ArrayList(MinResult) = .empty;
    if (ctx.cfg.minimize == 0) return found.items;
    for (0..2) |mi| {
        if (!ctx.cfg.modes[mi]) continue;
        const mode: Mode = @fromBackingInt(@intCast(mi));
        // One representative per signature (the bug steps present), the smallest program, the commonest signatures first.
        var sigs: std.StringArrayHashMapUnmanaged(struct { count: u32, best: usize }) = .empty;
        for (results, 0..) |r, idx| {
            if (r.class(mode) != .silent_miss) continue;
            const key = try report.signature(ctx.arena, r.tags);
            const gop = try sigs.getOrPut(ctx.arena, key);
            const size = gen.unitCount(r.program, try gen.fullMask(ctx.arena, r.program));
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .count = 1, .best = idx };
            } else {
                gop.value_ptr.count += 1;
                const cur = gen.unitCount(results[gop.value_ptr.best].program, try gen.fullMask(ctx.arena, results[gop.value_ptr.best].program));
                if (size < cur) gop.value_ptr.best = idx;
            }
        }
        const Entry = struct { key: []const u8, count: u32, best: usize };
        var entries: std.ArrayList(Entry) = .empty;
        for (sigs.keys(), sigs.values()) |k, v| try entries.append(ctx.arena, .{ .key = k, .count = v.count, .best = v.best });
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lt);
        var done: u32 = 0;
        var attempts: u32 = 0;
        for (entries.items) |e| {
            if (done == ctx.cfg.minimize or attempts == 2 * ctx.cfg.minimize) break;
            attempts += 1;
            const r = results[e.best];
            std.debug.print("oracle: minimizing p{d} ({t}, signature {s}, {d} programs)\n", .{ r.program.id, mode, e.key, e.count });
            const mask = try minimize(ctx, r.program, mode);
            var aw: Io.Writer.Allocating = .init(ctx.arena);
            try gen.render(&aw.writer, r.program, mask, true);
            const text = aw.written();
            const gop = try seen_text.getOrPut(ctx.arena, try normalized(ctx.arena, text));
            if (gop.found_existing) {
                const old = &found.items[gop.value_ptr.*];
                old.merged += 1;
                old.programs += e.count;
                if (old.mode != mode) old.also_other_mode = true;
                continue;
            }
            gop.value_ptr.* = found.items.len;
            done += 1;
            const both = (try evaluate(ctx, r.program, mask, if (mode == .plain) .std else .plain)).silent;
            try found.append(ctx.arena, .{
                .id = r.program.id,
                .mode = mode,
                .signature = try report.signature(ctx.arena, gen.tagsOf(r.program, mask)),
                .programs = e.count,
                .source = text,
                .tags = gen.tagsOf(r.program, mask),
                .also_other_mode = both,
                .fault = r.detail,
            });
        }
    }
    return found.items;
}

const Eval = struct { silent: bool };

/// Whether the program under the mask is still a silent miss in the mode.
fn evaluate(ctx: *Ctx, p: gen.Program, mask: gen.Mask, mode: Mode) !Eval {
    const dir = try path(ctx, "{s}/min", .{ctx.cfg.out});
    var one: Result = .{ .program = p, .tags = .{}, .truth = .clean, .detail = "" };
    const rs = [_]*Result{&one};
    _ = try writeBatch(ctx, dir, &rs, &.{mask});
    const sub = try path(ctx, "{s}/{t}", .{ dir, mode });
    const script = try path(ctx, "{s}/tools/zvc_export.sh", .{ctx.cfg.repo});
    const extra: []const [2][]const u8 = if (mode == .std) &.{.{ "ZV_AIR_STD", "1" }} else &.{};
    const ex = try exec(ctx, &.{ "sh", script, sub, try path(ctx, "{s}/batch.zig", .{dir}) }, null, extra);
    defer ex.deinit(ctx.gpa);
    if (ex.exited() != @as(?u8, 0)) return .{ .silent = false };
    const pack = try path(ctx, "{s}/batch.zvp", .{sub});
    const verdicts = try ownRows(ctx, dir, pack, null);
    const name = try path(ctx, "batch.p{d}", .{p.id});
    if ((verdicts.get(name) orelse .missing) != .clean) return .{ .silent = false };
    if (!(try ownFooter(ctx, dir, pack, name)).isEmpty()) return .{ .silent = false };
    if (try compile(ctx, dir)) |stderr| {
        ctx.gpa.free(stderr);
        return .{ .silent = false };
    }
    const o = try execute(ctx, dir, 0);
    return .{ .silent = o.truth == .fault };
}

fn minimize(ctx: *Ctx, p: gen.Program, mode: Mode) !gen.Mask {
    var mask = try gen.fullMask(ctx.arena, p);
    var evals: u32 = 0;
    var changed = true;
    while (changed and evals < ctx.cfg.min_evals) {
        changed = false;
        const groups = p.groups();
        var g: u16 = 1;
        while (g <= groups) : (g += 1) {
            if (!groupOn(p, mask, g)) continue;
            const trial = try ctx.arena.dupe(bool, mask);
            for (p.units, trial) |u, *on| {
                if (u.group == g) on.* = false;
            }
            if (!anyBody(p, trial)) continue;
            evals += 1;
            if ((try evaluate(ctx, p, trial, mode)).silent) {
                mask = trial;
                changed = true;
            }
        }
        for (p.units, 0..) |u, i| {
            if (u.fixed or !mask[i] or evals >= ctx.cfg.min_evals) continue;
            const trial = try ctx.arena.dupe(bool, mask);
            trial[i] = false;
            evals += 1;
            if ((try evaluate(ctx, p, trial, mode)).silent) {
                mask = trial;
                changed = true;
            }
        }
    }
    // A group with no body left is an empty block: drop its frame.
    var g: u16 = 1;
    while (g <= p.groups()) : (g += 1) {
        var body = false;
        for (p.units, mask) |u, on| {
            if (u.group == g and on and !u.fixed) body = true;
        }
        if (body) continue;
        for (p.units, mask) |u, *on| {
            if (u.group == g) on.* = false;
        }
    }
    return mask;
}

fn groupOn(p: gen.Program, mask: []const bool, g: u16) bool {
    for (p.units, mask) |u, on| {
        if (u.group == g and on) return true;
    }
    return false;
}

fn anyBody(p: gen.Program, mask: []const bool) bool {
    for (p.units, mask) |u, on| {
        if (on and !u.fixed) return true;
    }
    return false;
}

/// The text of a minimized function without its name and with the variable names (v<group>_<n>) made equal.
fn normalized(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = std.mem.findScalar(u8, text, '\n') orelse 0;
    while (i < text.len) {
        const boundary = i == 0 or !(std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_');
        if (text[i] == 'v' and boundary) {
            var j = i + 1;
            while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
            if (j > i + 1 and j < text.len and text[j] == '_') {
                var k = j + 1;
                while (k < text.len and std.ascii.isDigit(text[k])) k += 1;
                if (k > j + 1) {
                    try out.append(arena, 'v');
                    i = k;
                    continue;
                }
            }
        }
        try out.append(arena, text[i]);
        i += 1;
    }
    return out.items;
}
