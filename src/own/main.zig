//! zv-own: the static ownership checker. Reads zig-zv AIR packs through `zv_air` and never links compiler code.
//!
//!   zv-own [options] PATH...     PATH is a `.zvp` pack or an index directory
//!     --src DIR                  where module-relative source paths are found (default `.`)
//!     --module NAME=DIR          a different directory for the sources of one module
//!     --only PATH                only functions whose name has PATH as dotted components (`min` selects `a.min`, not `a.minMul`)
//!     --files PREFIX             only functions declared in files whose module-relative path starts with PREFIX (repeatable)
//!     --project NAME             a module whose functions are the project's (repeatable; default `target` and `root`): the
//!                                others are dependencies, which are checked and printed but counted apart
//!     --expect FILE              lines `NAME clean|error|unproven`; exit 0 iff every verdict equals the pinned one
//!     --pins FILE                lines `SHA256 PATH`: the sources the packs were exported from; any difference is an error
//!     --max-unproven N           fail when more than N functions are unproven
//!     --max-trusted N            fail when more than N functions are declared `.trusted` in an `ownership` manifest
//!     --summary                  one line per function, clean ones too
//!     --effects                  as --summary, and what each function was found to do (kills, frees, returns, stores) and assumed
//!     --dump                     the AIR of the selected functions as text, and stop
//! Exit status: 0 when no function has a finding (or matches --expect), 1 otherwise, 2 for bad usage.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zv_air = @import("zv_air");
const sources_mod = @import("zv_sources");
const sources = sources_mod;
const source = sources_mod.source;
const schema = zv_air.schema;
const check = @import("check.zig");
const diag = @import("diag.zig");
const dump = @import("dump.zig");
const spec = @import("spec.zig");

const Verdict = enum { clean, @"error", unproven, trusted };

const Options = struct {
    paths: []const []const u8 = &.{},
    dirs: sources.Dirs = .{},
    only: ?[]const u8 = null,
    files: []const []const u8 = &.{},
    project: []const []const u8 = &.{ "target", "root" },
    expect: ?[]const u8 = null,
    pins: ?[]const u8 = null,
    max_unproven: ?usize = null,
    max_trusted: ?usize = null,
    summary: bool = false,
    effects: bool = false,
    dump: bool = false,
};

/// Parameter names come from the source: the packs do not carry them.
const Names = struct {
    srcs: *sources.Sources,
    arena: Allocator,

    fn lookup(context: *anyopaque, ref: check.Ref, index: u32) ?[]const u8 {
        const self: *Names = @ptrCast(@alignCast(context));
        const loaded = (self.srcs.forFile(ref.pack, ref.func.file) catch return null) orelse return null;
        const fqn = ref.pack.str(ref.func.fqn);
        const declared = source.declaredName(self.arena, fqn) catch return null;
        const last = if (std.mem.lastIndexOfScalar(u8, declared, '.')) |i| declared[i + 1 ..] else declared;
        const names = (loaded.src.paramNames(self.arena, last, ref.func.line) catch return null) orelse return null;
        return if (index < names.len) names[index] else null;
    }
};

const Row = struct { name: []const u8, verdict: Verdict, result: *const check.Result, pack: *const schema.Pack, project: bool };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;
    const opts = parseArgs(arena, try init.minimal.args.toSlice(arena)) orelse return usage();

    if (opts.pins) |path| try checkPins(io, arena, path);
    var loaded: std.ArrayList(zv_air.reader.Loaded) = .empty;
    defer for (loaded.items) |l| l.deinit(gpa);
    for (opts.paths) |path| try loadPath(gpa, io, arena, path, &loaded);
    if (loaded.items.len == 0) fatal("no packs found", .{});
    var packs: std.ArrayList(*const schema.Pack) = .empty;
    for (loaded.items) |*l| try packs.append(arena, &l.pack);

    var srcs: sources.Sources = .{ .io = io, .arena = arena, .dirs = opts.dirs };
    var prog = try check.Program.init(gpa, arena, packs.items);
    var names_ctx: Names = .{ .srcs = &srcs, .arena = arena };
    prog.param_names = .{ .context = &names_ctx, .lookup = Names.lookup };

    var trusted: std.StringHashMapUnmanaged(void) = .empty;
    var unread: usize = 0;
    try readManifests(arena, &srcs, packs.items, &prog, &trusted, &unread);
    var rows: std.ArrayList(Row) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (packs.items) |pack| for (pack.t.funcs) |f| {
        const fqn = pack.str(f.fqn);
        if (!selected(pack, f, opts)) continue;
        const name = try source.declaredName(arena, fqn);
        if (opts.only) |only| if (!zv_air.names.selects(name, only)) continue;
        // The same function exported into several packs is one function.
        const file = pack.t.files[@backingInt(f.file)];
        var key: std.ArrayList(u8) = .empty;
        try key.print(arena, "{s}:{s}:{d}:{s}", .{ pack.str(file.module), pack.str(file.path), f.line, fqn });
        for (pack.t.params[f.params.off..][0..f.params.len]) |param| try key.print(arena, ",{s}", .{pack.typeName(param.ty)});
        // Instances of a generic function that print alike are told apart by their ids, when there is one pack.
        if (packs.items.len == 1) try key.print(arena, "#{x}", .{f.id});
        if ((try seen.getOrPut(arena, key.items)).found_existing) continue;
        if (opts.dump) {
            try dump.func(out, pack, f);
            continue;
        }
        const result = try prog.analyze(.{ .pack = pack, .func = f });
        const verdict: Verdict = if (trusted.contains(name)) .trusted else if (result.errors() != 0) .@"error" else if (result.unsupported()) .unproven else .clean;
        const module = pack.str(file.module);
        var project = false;
        for (opts.project) |m| project = project or std.mem.eql(u8, m, module);
        try rows.append(arena, .{ .name = name, .verdict = verdict, .result = result, .pack = pack, .project = project });
    };
    if (opts.dump) return out.flush();

    var counts: [4]usize = @splat(0);
    var dep_counts: [4]usize = @splat(0);
    for (rows.items) |row| {
        (if (row.project) &counts else &dep_counts)[@backingInt(row.verdict)] += 1;
        try printRow(out, &srcs, row, opts.summary or opts.effects);
        if (opts.effects) try printEffects(out, row);
        try out.flush();
    }
    try out.print("\nzv-own: {d} clean, {d} with findings, {d} unproven, {d} trusted\n", .{ counts[0], counts[1], counts[2], counts[3] });
    const dep_total = dep_counts[0] + dep_counts[1] + dep_counts[2] + dep_counts[3];
    if (dep_total != 0) try out.print("zv-own: and in dependencies, which the line above does not count: {d} clean, {d} with findings, {d} unproven, {d} trusted\n", .{ dep_counts[0], dep_counts[1], dep_counts[2], dep_counts[3] });
    var ok = counts[1] + dep_counts[1] == 0 and counts[2] + dep_counts[2] == 0;
    if (opts.expect) |path| ok = try compareExpected(io, arena, out, path, rows.items);
    if (opts.max_unproven) |limit| if (counts[2] > limit) {
        try out.print("zv-own: more unproven functions than the {d} allowed\n", .{limit});
        ok = false;
    };
    if (opts.max_trusted) |limit| if (counts[3] > limit) {
        try out.print("zv-own: more trusted functions than the {d} allowed\n", .{limit});
        ok = false;
    };
    var total: check.Stats = .{};
    for (rows.items) |row| {
        if (!row.project) continue;
        total.maybe_alias += row.result.stats.maybe_alias;
        total.maybe_stale += row.result.stats.maybe_stale;
        total.summarized += row.result.stats.summarized;
        total.alias_params += row.result.stats.alias_params;
        total.unknown_calls += row.result.stats.unknown_calls;
        total.transfers += row.result.stats.transfers;
        total.unmodelled += row.result.stats.unmodelled;
        total.blind += row.result.stats.blind;
        total.dynamic_len += row.result.stats.dynamic_len;
        total.lent += row.result.stats.lent;
        total.ends += row.result.stats.ends;
        total.uses += row.result.stats.uses;
    }
    if (unread != 0) try out.print("zv-own: {d} source files were not found: their ownership manifests were not read\n", .{unread});
    try out.print("zv-own: assumed, not checked: {d} calls to functions outside the packs or too odd to read, {d} linear values handed to memory it does not follow\n", .{ total.unknown_calls, total.transfers });
    if (total.unmodelled + total.blind + total.dynamic_len + total.lent != 0)
        try out.print("zv-own: also assumed: {d} container methods with no model (taken to invalidate), {d} operations on memory it cannot name, {d} resizes by a length it cannot show to be non-zero, {d} pointers to locals handed to calls that return a new block or that the summary does not trace (what the result keeps of them is not followed)\n", .{ total.unmodelled, total.blind, total.dynamic_len, total.lent });
    if (total.maybe_alias + total.maybe_stale + total.summarized + total.alias_params != 0)
        try out.print("zv-own: undecided, counted and not reported: {d} uses of a pointer that may lead into freed memory, {d} pointers stale only if a container had no room, {d} ends that may not have happened to the block (a site that stands for several allocations, one of many, a value that may be one of several, a growth that depends on room), {d} functions that end or change memory through two or more pointer parameters, assumed not to overlap\n", .{ total.maybe_alias, total.maybe_stale, total.summarized, total.alias_params });
    if (total.ends + total.uses != 0) {
        const open_ends = @min(total.summarized, total.ends);
        const open_uses = @min(total.maybe_alias + total.maybe_stale, total.uses);
        try out.print("zv-own: decided: {d} of {d} ends and {d} of {d} uses of memory it follows\n", .{ total.ends - open_ends, total.ends, total.uses - open_uses, total.uses });
    }
    try out.flush();
    if (!ok) std.process.exit(1);
}

/// Library code (`zv`) and the exporter's root are not what a project asks to have checked.
fn selected(pack: *const schema.Pack, f: schema.Func, opts: Options) bool {
    const file = pack.t.files[@backingInt(f.file)];
    const module = pack.str(file.module);
    const path = pack.str(file.path);
    if (opts.files.len != 0) {
        for (opts.files) |prefix| if (std.mem.startsWith(u8, path, prefix)) return true;
        return false;
    }
    if (std.mem.eql(u8, module, "zv") or std.mem.eql(u8, module, "std") or std.mem.eql(u8, module, "ubsan_rt")) return false;
    if (std.mem.eql(u8, module, "root") and std.mem.startsWith(u8, path, "air_")) return false;
    return true;
}

fn printRow(out: *Io.Writer, srcs: *sources.Sources, row: Row, all: bool) !void {
    const label = switch (row.verdict) {
        .clean => "clean    ",
        .@"error" => "FINDINGS ",
        .unproven => "UNPROVEN ",
        .trusted => "TRUSTED  ",
    };
    if ((row.verdict == .clean or row.verdict == .trusted) and !all) return;
    try out.print("{s}{s}\n", .{ label, row.name });
    for (row.result.diags) |d| {
        try printWhere(out, srcs, row.pack, d.loc);
        try out.print(": {s}: {s}\n", .{ d.kind.title(), d.text });
        try printExcerpt(out, srcs, row.pack, d.loc);
        for (d.notes) |n| {
            if (n.loc == .none) {
                try out.print("      note: {s}\n", .{n.text});
                continue;
            }
            try out.writeAll("      note");
            try printWhere(out, srcs, row.pack, n.loc);
            try out.print(": {s}\n", .{n.text});
        }
        if (d.trail != null) {
            try out.writeAll("      path:");
            var items: [64]*const diag.Trail = undefined;
            var n: usize = 0;
            var at = d.trail;
            while (at) |t| : (at = t.prev) {
                if (n == items.len) break;
                items[n] = t;
                n += 1;
            }
            while (n > 0) {
                n -= 1;
                try out.writeAll(" ");
                try printPos(out, srcs, row.pack, items[n].loc);
                try out.print(" {t};", .{items[n].what});
            }
            try out.writeByte('\n');
        }
    }
}

/// What a call to the function does, as the checker derived it from the body.
fn printEffects(out: *Io.Writer, row: Row) !void {
    const s = row.result.summary;
    try out.print("      effects: complete={} frees={x} moves={x} token_stores={x}\n", .{ s.complete, s.frees, s.moves, s.token_stores });
    const st = row.result.stats;
    if (st.blind + st.unknown_calls + st.unmodelled + st.dynamic_len + st.maybe_alias + st.maybe_stale != 0) try out.print("      assumed: {d} unknown calls, {d} unmodelled, {d} blind, {d} dynamic lengths, {d} may-alias, {d} may-stale\n", .{ st.unknown_calls, st.unmodelled, st.blind, st.dynamic_len, st.maybe_alias, st.maybe_stale });
    for (s.kills) |k| {
        try out.print("      kills param {d} {t} path {any}{s}{s}", .{ k.slot.param, k.slot.kind, k.slot.path, if (k.on_fail) " on-fail" else "", if (k.lost) " lost" else "" });
        for (k.when, 0..) |c, i| try out.print("{s} param {d} path {any} {s} {d}", .{ if (i == 0) " when" else " and", c.slot.param, c.slot.path, if (c.eq) "==" else "!=", c.value });
        try out.writeByte(10);
    }
    for (s.ret) |q| {
        try out.print("      returns path {any} from", .{q.path});
        for (q.descs) |d| try printDesc(out, d);
        try out.writeByte(10);
    }
    for (s.writes) |q| {
        try out.print("      writes param {d} {t} path {any} must={} from", .{ q.into.param, q.into.kind, q.into.path, q.must });
        for (q.descs) |d| try printDesc(out, d);
        try out.writeByte(10);
    }
    for (s.derefs) |q| {
        try out.print("      derefs param {d} {t} path {any}", .{ q.param, q.kind, q.path });
        try out.writeByte(10);
    }
}

fn printDesc(out: *Io.Writer, d: check.Desc) !void {
    const tag: []const u8 = if (d.obj) " obj" else "";
    switch (d.src) {
        .from => |x| try out.print(" [param {d} {t} {any}{s}]", .{ x.param, x.kind, x.path, tag }),
        .fresh => |k| try out.print(" [fresh {d}{s}]", .{ k, tag }),
        .gone => try out.print(" [gone{s}]", .{tag}),
        .con => |c| try out.print(" [constant {d}]", .{c}),
    }
}

fn printPos(out: *Io.Writer, srcs: *sources.Sources, pack: *const schema.Pack, loc: schema.LocId) !void {
    if (srcs.where(pack, loc)) |w| try out.print("{d}:{d}", .{ w.line, w.col }) else try out.writeAll("?");
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

/// The worst verdict of every function of that name (generic instances share one).
fn compareExpected(io: Io, arena: Allocator, out: *Io.Writer, path: []const u8, rows: []const Row) !bool {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| fatal("{s}: {t}", .{ path, err });
    var ok = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next().?;
        const want = std.meta.stringToEnum(Verdict, it.next() orelse "") orelse fatal("{s}: bad line `{s}`", .{ path, line });
        var got: ?Verdict = null;
        for (rows) |row| if (std.mem.eql(u8, row.name, name)) {
            got = if (got) |g| @fromBackingInt(@intCast(@max(@backingInt(g), @backingInt(row.verdict)))) else row.verdict;
        };
        const verdict = got orelse {
            try out.print("expected {s} {t}, but it was not checked at all\n", .{ name, want });
            ok = false;
            continue;
        };
        if (verdict != want) {
            try out.print("expected {s} {t}, got {t}\n", .{ name, want, verdict });
            ok = false;
        }
    }
    for (rows) |row| {
        var listed = false;
        var again = std.mem.splitScalar(u8, text, '\n');
        while (again.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var it = std.mem.tokenizeAny(u8, line, " \t");
            if (std.mem.eql(u8, it.next().?, row.name)) listed = true;
        }
        if (!listed) {
            try out.print("{s} is {t} but has no expectation\n", .{ row.name, row.verdict });
            ok = false;
        }
    }
    if (ok) try out.writeAll("zv-own: every verdict matches its expectation\n");
    return ok;
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
            std.debug.print("zv-own: {s} changed since the packs were exported\n", .{file});
            stale = true;
        }
    }
    if (stale) fatal("export the packs again (see {s})", .{path});
}

fn parseArgs(arena: Allocator, args: []const [:0]const u8) ?Options {
    var o: Options = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    var modules: std.ArrayList([2][]const u8) = .empty;
    var projects: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (!std.mem.startsWith(u8, a, "--")) {
            paths.append(arena, a) catch return null;
            continue;
        }
        if (std.mem.eql(u8, a, "--summary")) {
            o.summary = true;
        } else if (std.mem.eql(u8, a, "--effects")) {
            o.effects = true;
        } else if (std.mem.eql(u8, a, "--dump")) {
            o.dump = true;
        } else {
            i += 1;
            if (i >= args.len) return null;
            const v: []const u8 = args[i];
            if (std.mem.eql(u8, a, "--src")) {
                o.dirs.default = v;
            } else if (std.mem.eql(u8, a, "--only")) {
                o.only = v;
            } else if (std.mem.eql(u8, a, "--files")) {
                files.append(arena, v) catch return null;
            } else if (std.mem.eql(u8, a, "--project")) {
                projects.append(arena, v) catch return null;
            } else if (std.mem.eql(u8, a, "--expect")) {
                o.expect = v;
            } else if (std.mem.eql(u8, a, "--pins")) {
                o.pins = v;
            } else if (std.mem.eql(u8, a, "--max-trusted")) {
                o.max_trusted = std.fmt.parseInt(usize, v, 10) catch return null;
            } else if (std.mem.eql(u8, a, "--max-unproven")) {
                o.max_unproven = std.fmt.parseInt(usize, v, 10) catch return null;
            } else if (std.mem.eql(u8, a, "--module")) {
                const eq = std.mem.indexOfScalar(u8, v, '=') orelse return null;
                modules.append(arena, .{ v[0..eq], v[eq + 1 ..] }) catch return null;
            } else return null;
        }
    }
    if (paths.items.len == 0) return null;
    o.paths = paths.items;
    o.files = files.items;
    if (projects.items.len != 0) o.project = projects.items;
    o.dirs.by_module = modules.items;
    return o;
}

fn usage() noreturn {
    std.debug.print("usage: zv-own [--src DIR] [--module NAME=DIR] [--only PATH] [--files PREFIX] [--project NAME] [--expect FILE] [--pins FILE] [--max-unproven N] [--max-trusted N] [--summary] [--effects] [--dump] PACK|INDEX_DIR...\n", .{});
    std.process.exit(2);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zv-own: " ++ fmt ++ "\n", args);
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

/// Reads the `ownership` manifest of every source file the packs' functions come from: the effects a project gives
/// its own types (`.get = .reads`, `.remove = .invalidates`) and the functions it declares `.trusted`.
/// A source file that cannot be found has its manifest unread; the count is reported, never hidden.
fn readManifests(
    arena: Allocator,
    srcs: *sources.Sources,
    packs: []const *const schema.Pack,
    prog: *check.Program,
    trusted: *std.StringHashMapUnmanaged(void),
    unread: *usize,
) !void {
    var seen: std.AutoHashMapUnmanaged(*sources.Loaded, void) = .empty;
    var missing: std.StringHashMapUnmanaged(void) = .empty;
    for (packs) |pack| for (pack.t.funcs) |f| {
        const loaded = (try srcs.forFile(pack, f.file)) orelse {
            const rec = pack.t.files[@backingInt(f.file)];
            const key = try std.fmt.allocPrint(arena, "{s}:{s}", .{ pack.str(rec.module), pack.str(rec.path) });
            if (!(try missing.getOrPut(arena, key)).found_existing) {
                const mod = pack.str(rec.module);
                if (!std.mem.eql(u8, mod, "root") and !std.mem.eql(u8, mod, "") and !std.mem.eql(u8, mod, "std") and !std.mem.eql(u8, mod, "ubsan_rt")) unread.* += 1;
            }
            continue;
        };
        if ((try seen.getOrPut(arena, loaded)).found_existing) continue;
        for (try loaded.src.rawEntries(arena, "ownership")) |e| {
            if (std.mem.eql(u8, e.tag, "trusted")) {
                try trusted.put(arena, e.name, {});
            } else if (spec.Effect.fromTag(e.tag)) |effect| {
                try prog.annotations.put(arena, e.name, effect);
            }
        }
    };
}
