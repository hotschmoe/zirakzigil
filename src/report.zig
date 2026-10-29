//! The Phase 0 gate: what every public function of a library claims, and the
//! evidence that the claim holds.
//!
//! Host-side tooling (it prints), not part of the freestanding library path.
//! A consumer hands over its root module once and lets the build do the rest
//! (`zirakzigil.addAssuranceGate` wires the evidence in):
//!
//!     // tools/assurance.zig
//!     pub fn main(init: std.process.Init) !void {
//!         try zv.report.run(init, @import("mylib"), .tested);
//!     }
//!
//! The walk starts at the root and reaches every module through its public
//! declarations, so a module cannot dodge the gate by not being listed.
//!
//! What a level means operationally:
//!
//!   .tested    a law or scenario in the evidence suites executed the function
//!              (unit tests are not evidence; the suites are chosen by the build)
//!   .checked   the same, in a build where its contracts fire
//!   .verified  the same, plus `zvc` discharges it
//!   .trusted   exempt from evidence; a code owner vouches for it
//!
//! The evidence is dynamic: a generated copy of the source has a hit planted in
//! every function body (`zv.cover`), the suites run against that copy, and the
//! functions that reported a hit are the evidenced ones. `run` exits non-zero
//! if a claim has no evidence, names no function in the source, or sits below
//! the floor. Without evidence arguments it prints the manifest table alone.

const std = @import("std");
const manifest = @import("manifest.zig");
const Level = manifest.Level;

pub const Suite = struct {
    name: []const u8,
    /// The captured stderr of the suite's run; lines `zv-cover <id>` are hits.
    output: []const u8,
};

/// The instrumenter's map (`id<TAB>module<TAB>declaration` per line) and the suites that ran.
pub const Evidence = struct {
    map: []const u8,
    suites: []const Suite,
};

const max_suites = 8;

const Module = struct {
    name: []const u8,
    claims: usize = 0,
    by_level: [4]usize = @splat(0),
    hit: [max_suites]usize = @splat(0),
    missing: usize = 0,
};

/// Write the gate report for `Root` and return whether the gate passes.
pub fn write(gpa: std.mem.Allocator, w: *std.Io.Writer, comptime Root: type, comptime floor: Level, evidence: ?Evidence) !bool {
    const a = comptime manifest.audit(Root, floor);
    if (a.problem.len != 0) {
        try w.print("FAIL\n{s}\n", .{a.problem});
        return false;
    }
    const ev = evidence orelse {
        try w.print("assurance: {d} functions classified at or above .{t}; no evidence supplied (use `zig build assurance`)\n", .{ a.counts.fns(), floor });
        return true;
    };
    if (ev.suites.len > max_suites) return error.TooManySuites;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // key ("module.decl") -> id; module list in map order
    var ids: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    var id_count: usize = 0;
    var modules: std.ArrayList(Module) = .empty;
    var lines = std.mem.tokenizeScalar(u8, ev.map, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id = try std.fmt.parseInt(u32, fields.next().?, 10);
        const module = fields.next().?;
        const decl = fields.next().?;
        const entry = try ids.getOrPut(arena, try std.fmt.allocPrint(arena, "{s}.{s}", .{ module, decl }));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(arena, id);
        id_count = @max(id_count, id + 1);
        if (!hasModule(modules.items, module)) try modules.append(arena, .{ .name = module });
    }

    const hits = try arena.alloc(std.DynamicBitSetUnmanaged, ev.suites.len);
    for (hits, ev.suites) |*bits, suite| {
        bits.* = try .initEmpty(arena, id_count);
        var out = std.mem.tokenizeScalar(u8, suite.output, '\n');
        while (out.next()) |line| {
            const at = std.mem.indexOf(u8, line, "zv-cover ") orelse continue;
            const id = std.fmt.parseInt(u32, std.mem.trimEnd(u8, line[at + "zv-cover ".len ..], &std.ascii.whitespace), 10) catch continue;
            if (id < id_count) bits.set(id);
        }
    }

    var failures: std.ArrayList(u8) = .empty;
    var foreign: std.ArrayList(u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const claims: []const manifest.Claim = comptime a.claims;
    for (claims) |claim| {
        const name = try stripArguments(arena, claim.name);
        if ((try seen.getOrPut(arena, name)).found_existing) continue;
        const owner = for (modules.items) |*m| {
            if (name.len > m.name.len and std.mem.startsWith(u8, name, m.name) and name[m.name.len] == '.') break m;
        } else null;
        if (owner) |m| {
            m.claims += 1;
            m.by_level[@backingInt(claim.level)] += 1;
            if (claim.level != .trusted) {
                const found = ids.get(name);
                if (found == null) {
                    m.missing += 1;
                    try failures.print(arena, "  {s}: classified .{t} but no such function in the source\n", .{ name, claim.level });
                } else {
                    var any = false;
                    for (hits, 0..) |bits, s| {
                        for (found.?.items) |id| if (bits.isSet(id)) {
                            m.hit[s] += 1;
                            any = true;
                            break;
                        };
                    }
                    if (!any) {
                        m.missing += 1;
                        try failures.print(arena, "  {s}: classified .{t}, executed by no suite\n", .{ name, claim.level });
                    }
                }
            }
        } else {
            try foreign.print(arena, "  {s}\n", .{name});
        }
    }

    try w.print("{s:<24} {s:>4} {s:>8} {s:>7} {s:>6} {s:>7}", .{ "module", "fns", "verified", "checked", "tested", "trusted" });
    for (ev.suites) |s| try w.print(" {s:>9}", .{s.name});
    try w.print(" {s:>8}  {s}\n", .{ "unproven", "status" });

    var total: Module = .{ .name = "TOTAL" };
    for (modules.items) |m| {
        if (m.claims == 0) continue;
        try writeRow(w, m, ev.suites.len);
        total.claims += m.claims;
        total.missing += m.missing;
        for (&total.by_level, m.by_level) |*t, n| t.* += n;
        for (&total.hit, m.hit) |*t, n| t.* += n;
    }
    try writeRow(w, total, ev.suites.len);
    if (failures.items.len != 0) try w.print("\nunproven claims (write a law or scenario that runs them, or lower the claim to .trusted with a code owner):\n{s}", .{failures.items});
    if (foreign.items.len != 0) try w.print("\nclaims from other packages (their own gates cover them):\n{s}", .{foreign.items});
    return total.missing == 0;
}

fn hasModule(modules: []const Module, name: []const u8) bool {
    for (modules) |m| if (std.mem.eql(u8, m.name, name)) return true;
    return false;
}

fn writeRow(w: *std.Io.Writer, m: Module, suites: usize) !void {
    try w.print("{s:<24} {d:>4} {d:>8} {d:>7} {d:>6} {d:>7}", .{
        m.name,
        m.claims,
        m.by_level[@backingInt(Level.verified)],
        m.by_level[@backingInt(Level.checked)],
        m.by_level[@backingInt(Level.tested)],
        m.by_level[@backingInt(Level.trusted)],
    });
    for (m.hit[0..suites]) |n| try w.print(" {d:>9}", .{n});
    try w.print(" {d:>8}  {s}\n", .{ m.missing, if (m.missing == 0) "ok" else "FAIL" });
}

/// `storage.ring_buffer.RingBuffer(u8).push` is declared as `RingBuffer.push`.
fn stripArguments(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    for (name) |c| {
        switch (c) {
            '(' => depth += 1,
            ')' => depth -= 1,
            else => if (depth == 0) try out.append(gpa, c),
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Print the gate and exit with status 1 if it fails. Evidence arguments, given by
/// the build: `--map <file>` and one `--suite <name> <file>` per suite that ran.
pub fn run(init: std.process.Init, comptime Root: type, comptime floor: Level) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var map: ?[]const u8 = null;
    var suites: std.ArrayList(Suite) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--map") and i + 1 < args.len) {
            i += 1;
            map = try readAll(init, args[i]);
        } else if (std.mem.eql(u8, args[i], "--suite") and i + 2 < args.len) {
            const output = try readAll(init, args[i + 2]);
            for (suites.items) |*existing| {
                if (std.mem.eql(u8, existing.name, args[i + 1])) {
                    existing.output = try std.mem.concat(arena, u8, &.{ existing.output, output });
                    break;
                }
            } else try suites.append(arena, .{ .name = args[i + 1], .output = output });
            i += 2;
        } else {
            std.debug.print("zv.report: unknown argument `{s}`\n", .{args[i]});
            std.process.exit(2);
        }
    }

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const evidence: ?Evidence = if (map) |m| .{ .map = m, .suites = suites.items } else null;
    const ok = try write(init.gpa, &stdout.interface, Root, floor, evidence);
    try stdout.interface.flush();
    if (!ok) std.process.exit(1);
}

fn readAll(init: std.process.Init, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, init.arena.allocator(), .unlimited);
}

test "evidence decides the verdict" {
    const Lib = struct {
        pub const assurance = .{};
        pub const mod = struct {
            pub const assurance = .{ .a = .tested, .b = .tested, .c = .trusted };
            pub fn a() void {}
            pub fn b() void {}
            pub fn c() void {}
        };
    };
    const map = std.fmt.comptimePrint("0\t{0s}\ta\n1\t{0s}\tb\n2\t{0s}\tc\n", .{@typeName(Lib.mod)});
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    const both = [_]Suite{.{ .name = "laws", .output = "noise\nzv-cover 0\nzv-cover 1\n" }};
    const ok = try write(std.testing.allocator, &w, Lib, .trusted, .{ .map = map, .suites = &both });
    try std.testing.expect(ok);

    w = .fixed(&buf);
    const one = [_]Suite{.{ .name = "laws", .output = "zv-cover 0\n" }};
    try std.testing.expect(!try write(std.testing.allocator, &w, Lib, .trusted, .{ .map = map, .suites = &one }));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), @typeName(Lib.mod) ++ ".b: classified .tested, executed by no suite") != null);
}
