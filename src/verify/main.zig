//! zv-verify: the parts of `zig build verify` that are not the build graph (see `addVerify` in build.zig).
//!
//!   zv-verify export (--zig-zv EXE | --ensure SCRIPT --work DIR) --zig EXE --lib DIR --zv-src FILE --roots DIR --out DIR
//!                    TARGET...
//!     TARGET is `--file FILE.zig [--only PATH]... [--dep NAME=FILE.zig]... [--shallow] [--std]`
//!     Writes OUT/<stem>.zvp for each file: Debug, ghost code on, a fixed target, never linked.
//!   zv-verify check --zvc EXE --cache DIR [--z3 EXE] [--src DIR] [--total] [--timeout MS] [--max-trusted N]
//!                   [--max-assume N] PACK...
//!     Proves every `.verified` function with zvc, one process per function whose verdict is not in CACHE.
//!     A verdict is keyed by the AIR of the function and of everything it calls, their manifest levels, and the
//!     versions of zvc and Z3, so an edit re-proves only the functions it can change.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zv_air = @import("zv_air");
const schema = zv_air.schema;
const sources = @import("zv_sources");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) usage();
    if (std.mem.eql(u8, args[1], "export")) return exportPacks(init, args[2..]);
    if (std.mem.eql(u8, args[1], "check")) return check(init, args[2..]);
    usage();
}

fn usage() noreturn {
    fatal("usage: zv-verify export|check ... (see src/verify/main.zig)", .{});
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zv-verify: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn value(args: []const [:0]const u8, i: *usize) []const u8 {
    i.* += 1;
    if (i.* >= args.len) usage();
    return args[i.*];
}

fn nameOf(dep: []const u8) []const u8 {
    return dep[0 .. std.mem.indexOfScalar(u8, dep, '=') orelse usage()];
}

const Target = struct {
    file: []const u8,
    only: std.ArrayList([]const u8) = .empty,
    deps: std.ArrayList([]const u8) = .empty,
    shallow: bool = false,
    std: bool = false,
};

fn exportPacks(init: std.process.Init, args: []const [:0]const u8) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var zig_zv: ?[]const u8 = null;
    var ensure: ?[]const u8 = null;
    var work: []const u8 = "";
    var zig: []const u8 = "zig";
    var lib: []const u8 = "";
    var zv_src: []const u8 = "";
    var roots: []const u8 = "";
    var out: []const u8 = "";
    var targets: std.ArrayList(Target) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--zig-zv")) {
            zig_zv = value(args, &i);
        } else if (std.mem.eql(u8, a, "--ensure")) {
            ensure = value(args, &i);
        } else if (std.mem.eql(u8, a, "--work")) {
            work = value(args, &i);
        } else if (std.mem.eql(u8, a, "--zig")) {
            zig = value(args, &i);
        } else if (std.mem.eql(u8, a, "--lib")) {
            lib = value(args, &i);
        } else if (std.mem.eql(u8, a, "--zv-src")) {
            zv_src = value(args, &i);
        } else if (std.mem.eql(u8, a, "--roots")) {
            roots = value(args, &i);
        } else if (std.mem.eql(u8, a, "--out")) {
            out = value(args, &i);
        } else if (std.mem.eql(u8, a, "--file")) {
            try targets.append(arena, .{ .file = value(args, &i) });
        } else if (targets.items.len == 0) {
            usage();
        } else if (std.mem.eql(u8, a, "--only")) {
            try targets.items[targets.items.len - 1].only.append(arena, value(args, &i));
        } else if (std.mem.eql(u8, a, "--dep")) {
            try targets.items[targets.items.len - 1].deps.append(arena, value(args, &i));
        } else if (std.mem.eql(u8, a, "--shallow")) {
            targets.items[targets.items.len - 1].shallow = true;
        } else if (std.mem.eql(u8, a, "--std")) {
            targets.items[targets.items.len - 1].std = true;
        } else usage();
    }
    if (targets.items.len == 0 or out.len == 0 or lib.len == 0 or zv_src.len == 0 or roots.len == 0) usage();

    const zv = zig_zv orelse try buildZigZv(init, ensure orelse usage(), zig, work);
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, out);
    const scratch = try std.fs.path.join(arena, &.{ out, ".scratch" });
    cwd.deleteTree(io, scratch) catch {};
    defer cwd.deleteTree(io, scratch) catch {};
    try cwd.createDirPath(io, scratch);
    const options_file = try std.fs.path.join(arena, &.{ scratch, "zv_options.zig" });
    try cwd.writeFile(io, .{ .sub_path = options_file, .data = "pub const ghost: bool = true;\n" });

    const start = Io.Clock.awake.now(io);
    for (targets.items) |t| {
        const stem = std.fs.path.stem(t.file);
        const index = try std.fs.path.join(arena, &.{ scratch, stem });
        try cwd.createDirPath(io, index);

        var selection: std.ArrayList(u8) = .empty;
        try selection.appendSlice(arena, "const target = @import(\"target\");\npub const items = .{ ");
        if (t.only.items.len == 0) try selection.appendSlice(arena, "target");
        for (t.only.items, 0..) |path, n| try selection.print(arena, "{s}target.{s}", .{ if (n == 0) "" else ", ", path });
        try selection.appendSlice(arena, " };\n");
        const selection_file = try std.fs.path.join(arena, &.{ scratch, try std.fmt.allocPrint(arena, "{s}.selection.zig", .{stem}) });
        try cwd.writeFile(io, .{ .sub_path = selection_file, .data = selection.items });

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ zv, "test", "-fno-emit-bin", "-target", "x86_64-linux-gnu", "-mcpu", "baseline", "--zig-lib-dir", lib });
        try argv.appendSlice(arena, &.{ "--dep", "target", "--dep", "selection" });
        const air_root = try std.fs.path.join(arena, &.{ roots, if (t.shallow) "air_all.zig" else "air_deep.zig" });
        try argv.append(arena, try std.fmt.allocPrint(arena, "-Mroot={s}", .{air_root}));
        try argv.appendSlice(arena, &.{ "--dep", "zv" });
        for (t.deps.items) |d| try argv.appendSlice(arena, &.{ "--dep", nameOf(d) });
        try argv.append(arena, try std.fmt.allocPrint(arena, "-Mtarget={s}", .{t.file}));
        for (t.deps.items) |d| {
            try argv.appendSlice(arena, &.{ "--dep", "zv" });
            for (t.deps.items) |other| {
                if (!std.mem.eql(u8, nameOf(d), nameOf(other))) try argv.appendSlice(arena, &.{ "--dep", nameOf(other) });
            }
            try argv.append(arena, try std.fmt.allocPrint(arena, "-M{s}", .{d}));
        }
        try argv.appendSlice(arena, &.{ "--dep", "target", try std.fmt.allocPrint(arena, "-Mselection={s}", .{selection_file}) });
        try argv.appendSlice(arena, &.{ "--dep", "zv_options", try std.fmt.allocPrint(arena, "-Mzv={s}", .{zv_src}) });
        try argv.append(arena, try std.fmt.allocPrint(arena, "-Mzv_options={s}", .{options_file}));

        var env = try init.environ_map.clone(gpa);
        defer env.deinit();
        try env.put("ZV_AIR_OUT", index);
        if (t.std) try env.put("ZV_AIR_STD", "1") else _ = env.swapRemove("ZV_AIR_STD");
        const result = try std.process.run(gpa, io, .{ .argv = argv.items, .environ_map = &env });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
            fatal("exporting {s} failed", .{t.file});
        }

        var dir = try cwd.openDir(io, index, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        const pack_name = while (try it.next(io)) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".zvp")) break try arena.dupe(u8, entry.name);
        } else fatal("exporting {s} produced no pack", .{t.file});
        const bytes = try dir.readFileAllocOptions(io, pack_name, gpa, .unlimited, .@"8", null);
        defer gpa.free(bytes);
        const dest = try std.fs.path.join(arena, &.{ out, try std.fmt.allocPrint(arena, "{s}.zvp", .{stem}) });
        if (t.std) {
            const sliced = try zv_air.slice.slice(gpa, try schema.Pack.parse(bytes));
            defer gpa.free(sliced);
            try cwd.writeFile(io, .{ .sub_path = dest, .data = sliced });
        } else try cwd.writeFile(io, .{ .sub_path = dest, .data = bytes });
    }
    std.debug.print("zv: exported {d} pack(s) in {d} ms\n", .{ targets.items.len, start.untilNow(io, .awake).toMilliseconds() });
}

/// The from-source fallback: SCRIPT (tools/ensure_zig_zv.sh) builds zig-zv once per patch queue and prints its path.
fn buildZigZv(init: std.process.Init, script: []const u8, zig: []const u8, work: []const u8) ![]const u8 {
    const arena = init.arena.allocator();
    var env = try init.environ_map.clone(init.gpa);
    defer env.deinit();
    try env.put("ZIG", zig);
    var child = try std.process.spawn(init.io, .{ .argv = &.{ "sh", script, work }, .environ_map = &env, .stdout = .pipe });
    var buffer: [1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(init.io, &buffer);
    const text = try reader.interface.allocRemaining(arena, .limited(1 << 16));
    const term = try child.wait(init.io);
    if (term != .exited or term.exited != 0) fatal("building zig-zv from source failed (the log is above)", .{});
    return std.mem.trim(u8, text, " \r\n");
}

const Ref = struct { pack: *const schema.Pack, func: schema.Func };

const Check = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    srcs: *sources.Sources,
    by_name: std.StringHashMapUnmanaged(std.ArrayList(Ref)) = .empty,

    /// What a verdict on `root` rests on: the function and every function it calls, with their levels.
    fn closureKey(c: *Check, root: Ref, salt: *const [Sha256.digest_length]u8) ![16]u8 {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var members: std.ArrayList(Ref) = .empty;
        var pending: std.ArrayList(Ref) = .empty;
        try pending.append(c.arena, root);
        try seen.put(c.arena, root.pack.str(root.func.fqn), {});
        try members.append(c.arena, root);
        while (pending.pop()) |at| {
            for (at.pack.calleeRefsOf(at.func)) |ref| {
                const name = at.pack.calleeName(@fromBackingInt(@intCast(ref.callee)));
                const gop = try seen.getOrPut(c.arena, name);
                if (gop.found_existing) continue;
                for ((c.by_name.get(name) orelse continue).items) |callee| {
                    try members.append(c.arena, callee);
                    try pending.append(c.arena, callee);
                }
            }
        }
        std.mem.sort(Ref, members.items, {}, lessThan);
        var h = Sha256.init(.{});
        h.update(salt);
        for (members.items) |m| {
            const level = try c.srcs.levelOf(m.pack, m.func);
            h.update(m.pack.str(m.func.fqn));
            h.update(std.mem.asBytes(&m.func.id));
            h.update(std.mem.asBytes(&m.pack.meta.optimize));
            h.update(@tagName(level orelse .tested));
        }
        var digest: [Sha256.digest_length]u8 = undefined;
        h.final(&digest);
        return std.fmt.bytesToHex(digest[0..8].*, .lower);
    }

    fn lessThan(_: void, a: Ref, b: Ref) bool {
        const order = std.mem.order(u8, a.pack.str(a.func.fqn), b.pack.str(b.func.fqn));
        return order == .lt or (order == .eq and a.func.id < b.func.id);
    }
};

fn check(init: std.process.Init, args: []const [:0]const u8) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var zvc: []const u8 = "";
    var z3: ?[]const u8 = init.environ_map.get("ZV_Z3");
    var cache: []const u8 = "";
    var src: []const u8 = ".";
    var total = false;
    var timeout: []const u8 = "10000";
    var max_trusted: ?usize = null;
    var max_assume: ?usize = null;
    var packs: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--zvc")) {
            zvc = value(args, &i);
        } else if (std.mem.eql(u8, a, "--z3")) {
            z3 = value(args, &i);
        } else if (std.mem.eql(u8, a, "--cache")) {
            cache = value(args, &i);
        } else if (std.mem.eql(u8, a, "--src")) {
            src = value(args, &i);
        } else if (std.mem.eql(u8, a, "--total")) {
            total = true;
        } else if (std.mem.eql(u8, a, "--timeout")) {
            timeout = value(args, &i);
        } else if (std.mem.eql(u8, a, "--max-trusted")) {
            max_trusted = std.fmt.parseInt(usize, value(args, &i), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--max-assume")) {
            max_assume = std.fmt.parseInt(usize, value(args, &i), 10) catch usage();
        } else try packs.append(arena, a);
    }
    if (zvc.len == 0 or cache.len == 0 or packs.items.len == 0) usage();
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, cache);
    const start = Io.Clock.awake.now(io);

    var salt: [Sha256.digest_length]u8 = undefined;
    {
        var h = Sha256.init(.{});
        h.update(try cwd.readFileAlloc(io, zvc, arena, .unlimited));
        const version = std.process.run(gpa, io, .{ .argv = &.{ z3 orelse "z3", "--version" } }) catch |err|
            fatal("cannot run Z3 ({t}): set ZV_Z3 or -Dz3=PATH, or let `zig build` fetch the pinned release", .{err});
        defer gpa.free(version.stdout);
        defer gpa.free(version.stderr);
        h.update(version.stdout);
        h.update(timeout);
        h.update(if (total) "total" else "partial");
        h.final(&salt);
    }

    var loaded: std.ArrayList(zv_air.reader.Loaded) = .empty;
    defer {
        for (loaded.items) |l| l.deinit(gpa);
        loaded.deinit(gpa);
    }
    for (packs.items) |path| try loaded.append(gpa, zv_air.loadPack(gpa, io, cwd, path) catch |err| fatal("{s}: {t}", .{ path, err }));
    var srcs: sources.Sources = .{ .io = io, .arena = arena, .dirs = .{ .default = src } };
    var c: Check = .{ .gpa = gpa, .arena = arena, .io = io, .srcs = &srcs };
    var declared: std.StringHashMapUnmanaged(void) = .empty;
    for (loaded.items) |*l| for (l.pack.t.funcs) |f| {
        const gop = try c.by_name.getOrPut(arena, l.pack.str(f.fqn));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, .{ .pack = &l.pack, .func = f });
        try declared.put(arena, try sources.source.declaredName(arena, l.pack.str(f.fqn)), {});
    };

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var assumed: std.StringHashMapUnmanaged(void) = .empty;
    var premises: std.StringHashMapUnmanaged(void) = .empty;
    var proved: usize = 0;
    var cached: usize = 0;
    var failed: usize = 0;
    for (loaded.items) |*l| for (l.pack.t.funcs) |f| {
        const level = (try srcs.levelOf(&l.pack, f)) orelse continue;
        if (level != .verified) continue;
        const fqn = l.pack.str(f.fqn);
        const unique = try std.fmt.allocPrint(arena, "{s}#{x}", .{ fqn, f.id });
        if ((try seen.getOrPut(arena, unique)).found_existing) continue;
        const name = try sources.source.declaredName(arena, fqn);
        const key = try c.closureKey(.{ .pack = &l.pack, .func = f }, &salt);
        const entry = try std.fmt.allocPrint(arena, "{s}/{s}.proved", .{ cache, key });

        var line: []const u8 = undefined;
        const hit = cwd.readFileAlloc(io, entry, arena, .limited(1 << 16)) catch null;
        if (hit) |text| {
            line = text;
            cached += 1;
        } else {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(arena, &.{ zvc, "--src", src, "--timeout", timeout, "--only", name });
            if (total) try argv.append(arena, "--total");
            if (z3) |path| try argv.appendSlice(arena, &.{ "--z3", path });
            try argv.appendSlice(arena, packs.items);
            const result = try std.process.run(gpa, io, .{ .argv = argv.items });
            defer gpa.free(result.stdout);
            defer gpa.free(result.stderr);
            const exited_clean = result.term == .exited and result.term.exited == 0;
            line = (if (exited_clean) firstProved(result.stdout) else null) orelse {
                std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
                failed += 1;
                continue;
            };
            line = try arena.dupe(u8, line);
            try cwd.writeFile(io, .{ .sub_path = entry, .data = line });
        }
        proved += 1;
        try noteAssumptions(arena, line, &assumed, &premises);
        const shown = std.mem.trim(u8, line, "\r\n");
        std.debug.print("{s}{s}\n", .{ shown, if (hit != null) " (cached)" else "" });
    };

    // A function the manifest calls .verified that the packs do not contain was never looked at.
    var files = srcs.files.valueIterator();
    while (files.next()) |entry| {
        const l = entry.* orelse continue;
        var levels = l.levels.iterator();
        while (levels.next()) |e| {
            if (e.value_ptr.* != .verified or declared.contains(e.key_ptr.*)) continue;
            std.debug.print("UNPROVEN {s}: the manifest says .verified but no such function is in the packs: export again, or the function is generic and never instantiated\n", .{e.key_ptr.*});
            failed += 1;
        }
    }

    if (assumed.count() != 0) std.debug.print("zv: {d} trusted assumption(s), not machine-checked\n", .{assumed.count()});
    if (premises.count() != 0) std.debug.print("zv: {d} zv.assume premise(s), not proved\n", .{premises.count()});
    if (max_trusted) |limit| if (assumed.count() > limit) {
        std.debug.print("zv: more trusted assumptions than the {d} allowed\n", .{limit});
        failed += 1;
    };
    if (max_assume) |limit| if (premises.count() > limit) {
        std.debug.print("zv: more zv.assume premises than the {d} allowed\n", .{limit});
        failed += 1;
    };
    std.debug.print("zv: {d} proved ({d} from the cache), {d} not proved, {d} ms\n", .{ proved, cached, failed, start.untilNow(io, .awake).toMilliseconds() });
    if (failed != 0) std.process.exit(1);
}

/// The result line of the function itself in zvc's output: the first `proved` that is not a callee it relied on.
fn firstProved(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "proved   ") and std.mem.indexOf(u8, line, " (relied on)") == null) return line;
    }
    return null;
}

/// Counts the distinct `.trusted` functions and `zv.assume` sites a result line names.
fn noteAssumptions(arena: Allocator, line: []const u8, assumed: *std.StringHashMapUnmanaged(void), premises: *std.StringHashMapUnmanaged(void)) !void {
    const trusted_tag = ", assuming trusted:";
    const assume_tag = ", assuming zv.assume at";
    const trusted_at = std.mem.indexOf(u8, line, trusted_tag);
    const assume_at = std.mem.indexOf(u8, line, assume_tag);
    if (trusted_at) |at| {
        const end = if (assume_at) |a| if (a > at) a else line.len else line.len;
        var names = std.mem.tokenizeAny(u8, line[at + trusted_tag.len .. end], ", \r\n");
        while (names.next()) |n| try assumed.put(arena, try arena.dupe(u8, n), {});
    }
    if (assume_at) |at| {
        const end = if (trusted_at) |t| if (t > at) t else line.len else line.len;
        var sites = std.mem.tokenizeAny(u8, line[at + assume_tag.len .. end], ", \r\n");
        while (sites.next()) |s| try premises.put(arena, try arena.dupe(u8, s), {});
    }
}
