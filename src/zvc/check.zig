//! Discharges the obligations of one function with Z3 and turns each failure into a counterexample a
//! person can act on: the obligation, the source position, and concrete values of the inputs and of the
//! named locals at that point.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const term = @import("term.zig");
const smt = @import("smt.zig");
const vc = @import("vc.zig");
const value = @import("value.zig");
const Term = term.Term;

pub const Line = struct { name: []const u8, text: []const u8 };

pub const Counterexample = struct {
    inputs: []const Line,
    locals: []const Line,
};

pub const Failure = struct {
    ob: vc.Obligation,
    /// Null when the solver gave up.
    ce: ?Counterexample,
};

pub const Outcome = struct {
    obligations: usize = 0,
    failures: []const Failure = &.{},
    /// Solver time in nanoseconds.
    solver_ns: u96 = 0,
};

pub const Options = struct {
    z3: []const u8,
    timeout_ms: u32,
    trace: ?*Io.Writer = null,
    /// Elements of a slice or array shown in a counterexample.
    shown: u32 = 8,
};

pub const Error = smt.Session.Error;

pub fn discharge(gpa: Allocator, io: Io, arena: Allocator, v: *vc.Vc, opts: Options) Error!Outcome {
    var out: Outcome = .{};
    if (v.obligations.items.len == 0) return out;
    const session = try smt.Session.start(gpa, io, .{ .z3 = opts.z3, .timeout_ms = opts.timeout_ms, .trace = opts.trace });
    defer session.stop();
    var failures: std.ArrayList(Failure) = .empty;
    var seen: std.AutoHashMapUnmanaged([2]Term, void) = .empty;
    const start = Io.Clock.awake.now(io);
    for (v.obligations.items) |ob| {
        const key: [2]Term = .{ ob.pc, ob.goal };
        if ((try seen.getOrPut(arena, key)).found_existing) continue;
        out.obligations += 1;
        const asked = Io.Clock.awake.now(io);
        const verdict = try session.refute(arena, v.pool, ob.pc, ob.goal);
        if (opts.trace) |t| try t.print(";; {t} after {d} ms: {s}\n", .{ verdict, @divTrunc(asked.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_ms), ob.text });
        switch (verdict) {
            .unsat => try session.done(),
            .unknown => {
                try session.done();
                try failures.append(arena, .{ .ob = ob, .ce = null });
            },
            .sat => {
                const ce = try counterexample(arena, session, v, ob, opts.shown);
                try session.done();
                try failures.append(arena, .{ .ob = ob, .ce = ce });
            },
        }
    }
    out.solver_ns = @intCast(start.untilNow(io, .awake).toNanoseconds());
    out.failures = failures.items;
    return out;
}

fn counterexample(arena: Allocator, session: *smt.Session, v: *vc.Vc, ob: vc.Obligation, shown: u32) Error!Counterexample {
    const pool = v.pool;
    try shrink(arena, session, v);
    var terms: std.ArrayList(Term) = .empty;
    for (v.inputs()) |in| switch (in.kind) {
        .int => |i| try terms.append(arena, i.term),
        .bool => |b| try terms.append(arena, b),
        .slice => |s| try terms.append(arena, s.len),
        .array => {},
    };
    for (ob.locals) |l| try terms.append(arena, l.value);
    const first = try session.values(arena, pool, terms.items);

    var at: usize = 0;
    var element_terms: std.ArrayList(Term) = .empty;
    var element_counts: std.ArrayList(u64) = .empty;
    for (v.inputs()) |in| {
        const mem, const count: u64 = switch (in.kind) {
            .int => {
                at += 1;
                continue;
            },
            .bool => {
                at += 1;
                continue;
            },
            .slice => |s| blk: {
                const len = constBits(first[at]) orelse 0;
                at += 1;
                break :blk .{ s.mem, @min(len, shown) };
            },
            .array => |a| .{ a.mem, @min(a.len, shown) },
        };
        try element_counts.append(arena, count);
        for (0..count) |i| try element_terms.append(arena, try pool.select(mem, try pool.bv(64, i)));
    }
    const second = try session.values(arena, pool, element_terms.items);

    var inputs: std.ArrayList(Line) = .empty;
    at = 0;
    var el: usize = 0;
    var group: usize = 0;
    for (v.inputs()) |in| {
        switch (in.kind) {
            .int => |i| {
                try inputs.append(arena, .{ .name = in.name, .text = try fmtConst(arena, first[at], i.signed) });
                at += 1;
            },
            .bool => {
                try inputs.append(arena, .{ .name = in.name, .text = try fmtConst(arena, first[at], false) });
                at += 1;
            },
            .slice => |s| {
                const len = constBits(first[at]) orelse 0;
                at += 1;
                const count = element_counts.items[group];
                group += 1;
                try inputs.append(arena, .{ .name = in.name, .text = try fmtElements(arena, len, second[el..][0..count], s.signed) });
                el += count;
            },
            .array => |a| {
                const count = element_counts.items[group];
                group += 1;
                try inputs.append(arena, .{ .name = in.name, .text = try fmtElements(arena, a.len, second[el..][0..count], a.signed) });
                el += count;
            },
        }
    }
    var locals: std.ArrayList(Line) = .empty;
    for (ob.locals, first[at..]) |l, c| {
        var duplicate = false;
        for (locals.items) |x| duplicate = duplicate or std.mem.eql(u8, x.name, l.name);
        for (inputs.items) |x| duplicate = duplicate or std.mem.eql(u8, x.name, l.name);
        if (duplicate) continue;
        try locals.append(arena, .{ .name = l.name, .text = try fmtConst(arena, c, l.signed) });
    }
    return .{ .inputs = inputs.items, .locals = locals.items };
}

/// Prefers the plainest counterexample. An unsigned input takes the least value that still violates the
/// obligation, found by bisection; a signed one the first of 0, 1, 2, 3, -1 and the extremes that does.
fn shrink(arena: Allocator, session: *smt.Session, v: *vc.Vc) Error!void {
    const pool = v.pool;
    for (v.inputs()) |in| {
        const t, const signed = switch (in.kind) {
            .int => |i| .{ i.term, i.signed },
            .slice => |s| .{ s.len, false },
            else => continue,
        };
        const bits = pool.bitsOf(t);
        if (!signed) {
            var lo: u256 = 0;
            var hi: u256 = term.mask(bits);
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (try session.pin(arena, pool, try pool.cmp(.ule, t, try pool.bv(bits, mid)))) hi = mid else lo = mid + 1;
            }
            _ = try session.pin(arena, pool, try pool.eq(t, try pool.bv(bits, lo)));
            continue;
        }
        const half = @as(u256, 1) << @intCast(bits - 1);
        const candidates = [_]u256{ 0, 1, 2, 3, term.mask(bits), half - 1, half };
        for (candidates) |c| if (try session.pin(arena, pool, try pool.eq(t, try pool.bv(bits, c)))) break;
    }
    try session.remodel(arena);
}

fn constBits(c: smt.Const) ?u64 {
    return switch (c) {
        .bv => |b| @truncate(b.value),
        else => null,
    };
}

fn fmtConst(arena: Allocator, c: smt.Const, signed: bool) Allocator.Error![]const u8 {
    switch (c) {
        .bool => |b| return if (b) "true" else "false",
        .int => |i| return std.fmt.allocPrint(arena, "{d}", .{i}),
        .bv => |b| {
            if (signed) {
                const s = term.signed(b.bits, b.value);
                if (s < 0) return std.fmt.allocPrint(arena, "{d}", .{s});
            }
            if (b.value > 0xffff) return std.fmt.allocPrint(arena, "{d} (0x{x})", .{ b.value, b.value });
            return std.fmt.allocPrint(arena, "{d}", .{b.value});
        },
        .other => return "?",
    }
}

fn fmtElements(arena: Allocator, len: u64, elements: []const smt.Const, signed: bool) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "len {d}, [", .{len});
    for (elements, 0..) |e, i| {
        if (i != 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, try fmtConst(arena, e, signed));
    }
    if (len > elements.len) try out.appendSlice(arena, ", ...");
    try out.append(arena, ']');
    return out.items;
}
