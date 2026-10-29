//! SMT-LIB2: printing of terms and a Z3 process spoken to over stdin and stdout.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const term = @import("term.zig");
const Term = term.Term;
const Sort = term.Sort;
const Pool = term.Pool;

pub fn writeSort(w: *Io.Writer, s: Sort) Io.Writer.Error!void {
    switch (s) {
        .bool => try w.writeAll("Bool"),
        .bv => |n| try w.print("(_ BitVec {d})", .{n}),
        .array => |a| try w.print("(Array (_ BitVec {d}) (_ BitVec {d}))", .{ a.idx, a.elem }),
        .seq => try w.print("(Seq (_ BitVec {d}))", .{term.ghost_bits}),
    }
}

/// Emits declarations and definitions into a buffer, each term once.
pub const Script = struct {
    emitted: std.DynamicBitSetUnmanaged = .{},
    /// While a scope is open, what it emitted: the scope's end takes it back.
    scoped: std.ArrayList(u32) = .empty,
    recording: bool = false,

    pub fn deinit(s: *Script, gpa: Allocator) void {
        s.emitted.deinit(gpa);
        s.scoped.deinit(gpa);
    }

    fn grow(s: *Script, gpa: Allocator, len: usize) Allocator.Error!void {
        if (s.emitted.bit_length < len) try s.emitted.resize(gpa, len + 256, false);
    }

    fn mark(s: *Script, gpa: Allocator, i: usize) Allocator.Error!void {
        s.emitted.set(i);
        if (s.recording) try s.scoped.append(gpa, @intCast(i));
    }

    pub fn closeScope(s: *Script) void {
        for (s.scoped.items) |i| s.emitted.unset(i);
        s.scoped.clearRetainingCapacity();
        s.recording = false;
    }

    /// Writes whatever `t` needs that earlier calls have not written.
    pub fn define(s: *Script, gpa: Allocator, pool: *const Pool, w: *Io.Writer, t: Term) (Allocator.Error || Io.Writer.Error)!void {
        try s.grow(gpa, pool.nodes.items.len);
        var stack: std.ArrayList(struct { t: Term, expanded: bool }) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ .t = t, .expanded = false });
        while (stack.pop()) |item| {
            const i = @backingInt(item.t);
            if (s.emitted.isSet(i)) continue;
            switch (pool.node(item.t)) {
                .bool_lit, .bv_lit => continue,
                .variable => |v| {
                    try s.mark(gpa, i);
                    try w.print("(declare-const |{s}| ", .{pool.name(v.name)});
                    try writeSort(w, v.sort);
                    try w.writeAll(")\n");
                },
                .app => |a| {
                    if (!item.expanded) {
                        try stack.append(gpa, .{ .t = item.t, .expanded = true });
                        for (a.operands()) |arg| try stack.append(gpa, .{ .t = arg, .expanded = false });
                        continue;
                    }
                    try s.mark(gpa, i);
                    try w.print("(define-fun t{d} () ", .{i});
                    try writeSort(w, a.sort);
                    try w.writeByte(' ');
                    try writeApp(w, pool, a);
                    try w.writeAll(")\n");
                },
            }
        }
    }
};

pub fn writeRef(w: *Io.Writer, pool: *const Pool, t: Term) Io.Writer.Error!void {
    switch (pool.node(t)) {
        .bool_lit => |b| try w.writeAll(if (b) "true" else "false"),
        .bv_lit => |l| try w.print("(_ bv{d} {d})", .{ l.value, l.bits }),
        .variable => |v| try w.print("|{s}|", .{pool.name(v.name)}),
        .app => try w.print("t{d}", .{@backingInt(t)}),
    }
}

fn writeApp(w: *Io.Writer, pool: *const Pool, a: term.App) Io.Writer.Error!void {
    const args = a.operands();
    switch (a.op) {
        .zext => try w.print("((_ zero_extend {d}) ", .{a.p}),
        .sext => try w.print("((_ sign_extend {d}) ", .{a.p}),
        .extract => try w.print("((_ extract {d} {d}) ", .{ a.p, a.q }),
        .seq_empty => return w.print("(as seq.empty (Seq (_ BitVec {d})))", .{term.ghost_bits}),
        .seq_len => {
            try w.print("((_ int2bv {d}) (seq.len ", .{term.ghost_bits});
            try writeRef(w, pool, args[0]);
            return w.writeAll("))");
        },
        .seq_at => {
            try w.writeAll("(seq.nth ");
            try writeRef(w, pool, args[0]);
            try w.writeAll(" (bv2nat ");
            try writeRef(w, pool, args[1]);
            return w.writeAll("))");
        },
        .seq_extract => {
            try w.writeAll("(seq.extract ");
            try writeRef(w, pool, args[0]);
            try w.writeAll(" (bv2nat ");
            try writeRef(w, pool, args[1]);
            try w.writeAll(") (bv2nat ");
            try writeRef(w, pool, args[2]);
            return w.writeAll("))");
        },
        else => {
            try w.writeByte('(');
            try w.writeAll(switch (a.op) {
                .not => "not",
                .@"and" => "and",
                .@"or" => "or",
                .ite => "ite",
                .eq => "=",
                .add => "bvadd",
                .sub => "bvsub",
                .mul => "bvmul",
                .udiv => "bvudiv",
                .urem => "bvurem",
                .sdiv => "bvsdiv",
                .srem => "bvsrem",
                .smod => "bvsmod",
                .neg => "bvneg",
                .bnot => "bvnot",
                .band => "bvand",
                .bor => "bvor",
                .bxor => "bvxor",
                .shl => "bvshl",
                .lshr => "bvlshr",
                .ashr => "bvashr",
                .ult => "bvult",
                .ule => "bvule",
                .slt => "bvslt",
                .sle => "bvsle",
                .umul_ok => "bvumul_noovfl",
                .smul_hi_ok => "bvsmul_noovfl",
                .smul_lo_ok => "bvsmul_noudfl",
                .concat => "concat",
                .select => "select",
                .store => "store",
                .seq_unit => "seq.unit",
                .seq_concat => "seq.++",
                .zext, .sext, .extract, .seq_empty, .seq_len, .seq_at, .seq_extract => unreachable,
            });
            for (args) |arg| {
                try w.writeByte(' ');
                try writeRef(w, pool, arg);
            }
            return w.writeByte(')');
        },
    }
    for (args, 0..) |arg, i| {
        if (i != 0) try w.writeByte(' ');
        try writeRef(w, pool, arg);
    }
    try w.writeByte(')');
}

pub const SExpr = union(enum) {
    atom: []const u8,
    list: []const SExpr,

    pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!?SExpr {
        var i: usize = 0;
        return parseAt(arena, text, &i);
    }

    fn parseAt(arena: Allocator, text: []const u8, i: *usize) Allocator.Error!?SExpr {
        while (i.* < text.len and std.ascii.isWhitespace(text[i.*])) i.* += 1;
        if (i.* >= text.len) return null;
        if (text[i.*] == '(') {
            i.* += 1;
            var items: std.ArrayList(SExpr) = .empty;
            while (true) {
                while (i.* < text.len and std.ascii.isWhitespace(text[i.*])) i.* += 1;
                if (i.* >= text.len) return null;
                if (text[i.*] == ')') {
                    i.* += 1;
                    return .{ .list = try items.toOwnedSlice(arena) };
                }
                try items.append(arena, (try parseAt(arena, text, i)) orelse return null);
            }
        }
        const start = i.*;
        if (text[start] == '|') {
            i.* += 1;
            while (i.* < text.len and text[i.*] != '|') i.* += 1;
            i.* = @min(i.* + 1, text.len);
            return .{ .atom = text[start + 1 .. i.* - 1] };
        }
        while (i.* < text.len and !std.ascii.isWhitespace(text[i.*]) and text[i.*] != '(' and text[i.*] != ')') i.* += 1;
        return .{ .atom = text[start..i.*] };
    }
};

pub const Const = union(enum) {
    bool: bool,
    bv: struct { bits: u16, value: u256 },
    int: i128,
    other,

    pub fn fromSExpr(e: SExpr) Const {
        switch (e) {
            .atom => |a| {
                if (std.mem.eql(u8, a, "true")) return .{ .bool = true };
                if (std.mem.eql(u8, a, "false")) return .{ .bool = false };
                if (std.mem.startsWith(u8, a, "#x")) {
                    const v = std.fmt.parseInt(u256, a[2..], 16) catch return .other;
                    return .{ .bv = .{ .bits = @intCast(4 * (a.len - 2)), .value = v } };
                }
                if (std.mem.startsWith(u8, a, "#b")) {
                    const v = std.fmt.parseInt(u256, a[2..], 2) catch return .other;
                    return .{ .bv = .{ .bits = @intCast(a.len - 2), .value = v } };
                }
                if (std.fmt.parseInt(i128, a, 10)) |v| return .{ .int = v } else |_| return .other;
            },
            .list => |l| {
                if (l.len == 2 and l[0] == .atom and std.mem.eql(u8, l[0].atom, "-") and l[1] == .atom) {
                    const v = std.fmt.parseInt(i128, l[1].atom, 10) catch return .other;
                    return .{ .int = -v };
                }
                if (l.len == 3 and l[0] == .atom and std.mem.eql(u8, l[0].atom, "_") and l[1] == .atom and std.mem.startsWith(u8, l[1].atom, "bv")) {
                    const v = std.fmt.parseInt(u256, l[1].atom[2..], 10) catch return .other;
                    const bits = std.fmt.parseInt(u16, l[2].atom, 10) catch return .other;
                    return .{ .bv = .{ .bits = bits, .value = v } };
                }
                return .other;
            },
        }
    }
};

pub const Verdict = enum { unsat, sat, unknown };

/// One Z3 process. Terms are declared into it once; each query lives in a pushed scope.
pub const Session = struct {
    gpa: Allocator,
    io: Io,
    child: std.process.Child,
    writer: Io.File.Writer,
    reader: Io.File.Reader,
    wbuf: [4096]u8 = undefined,
    rbuf: [4096]u8 = undefined,
    script: Script = .{},
    pending: Io.Writer.Allocating,
    trace: ?*Io.Writer,
    depth: u32 = 0,

    pub const Options = struct {
        z3: []const u8,
        timeout_ms: u32,
        trace: ?*Io.Writer = null,
    };

    pub const Error = Allocator.Error || Io.Writer.Error || Io.Reader.DelimiterError || std.process.SpawnError || error{ SolverError, ReadFailed };

    pub fn start(gpa: Allocator, io: Io, opts: Options) Error!*Session {
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .child = try std.process.spawn(io, .{
                .argv = &.{ opts.z3, "-in", "-smt2" },
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .ignore,
            }),
            .writer = undefined,
            .reader = undefined,
            .pending = .init(gpa),
            .trace = opts.trace,
        };
        s.writer = s.child.stdin.?.writerStreaming(io, &s.wbuf);
        s.reader = s.child.stdout.?.readerStreaming(io, &s.rbuf);
        try s.pending.writer.print("(set-option :timeout {d})\n(set-option :produce-models true)\n", .{opts.timeout_ms});
        return s;
    }

    pub fn stop(s: *Session) void {
        s.writer.interface.writeAll("(exit)\n") catch {};
        s.writer.interface.flush() catch {};
        if (s.child.stdin) |f| f.close(s.io);
        s.child.stdin = null;
        _ = s.child.wait(s.io) catch {};
        s.script.deinit(s.gpa);
        s.pending.deinit();
        s.gpa.destroy(s);
    }

    fn flush(s: *Session) Error!void {
        const text = s.pending.written();
        if (s.trace) |t| {
            try t.writeAll(text);
            try t.flush();
        }
        try s.writer.interface.writeAll(text);
        s.pending.clearRetainingCapacity();
    }

    /// Sends everything pending plus a marker, and returns the solver's lines up to the marker.
    fn roundTrip(s: *Session, arena: Allocator) Error![]const u8 {
        try s.pending.writer.writeAll("(echo \"zvc-sync\")\n");
        try s.flush();
        try s.writer.interface.flush();
        var out: Io.Writer.Allocating = .init(arena);
        while (true) {
            const line = (try s.reader.interface.takeDelimiter('\n')) orelse return error.SolverError;
            const trimmed = std.mem.trim(u8, line, "\r \"");
            if (std.mem.eql(u8, trimmed, "zvc-sync")) break;
            try out.writer.writeAll(trimmed);
            try out.writer.writeByte('\n');
        }
        return out.written();
    }

    pub fn define(s: *Session, pool: *const Pool, t: Term) Error!void {
        try s.script.define(s.gpa, pool, &s.pending.writer, t);
    }

    pub fn assertTerm(s: *Session, pool: *const Pool, t: Term) Error!void {
        try s.define(pool, t);
        const w = &s.pending.writer;
        try w.writeAll("(assert ");
        try writeRef(w, pool, t);
        try w.writeAll(")\n");
    }

    /// Checks `pc and not goal` in a fresh scope. Leaves the scope open for `values`; close it with `done`.
    pub fn refute(s: *Session, arena: Allocator, pool: *const Pool, pc: Term, goal: Term) Error!Verdict {
        std.debug.assert(s.depth == 0);
        try s.define(pool, pc);
        try s.define(pool, goal);
        const w = &s.pending.writer;
        try w.writeAll("(push 1)\n(assert ");
        try writeRef(w, pool, pc);
        try w.writeAll(")\n(assert (not ");
        try writeRef(w, pool, goal);
        try w.writeAll("))\n(check-sat)\n");
        s.depth = 1;
        s.script.recording = true;
        const reply = try s.roundTrip(arena);
        var lines = std.mem.splitScalar(u8, reply, '\n');
        const first = lines.next() orelse return error.SolverError;
        if (std.mem.eql(u8, first, "unsat")) return .unsat;
        if (std.mem.eql(u8, first, "sat")) return .sat;
        if (std.mem.eql(u8, first, "unknown")) return .unknown;
        if (s.trace) |t| try t.print(";; solver said: {s}\n", .{reply});
        return error.SolverError;
    }

    pub fn done(s: *Session) Error!void {
        std.debug.assert(s.depth != 0);
        try s.pending.writer.print("(pop {d})\n", .{s.depth});
        s.depth = 0;
        s.script.closeScope();
    }

    /// Adds `t` to the open scope when the query stays satisfiable; otherwise leaves the scope as it was.
    pub fn pin(s: *Session, arena: Allocator, pool: *const Pool, t: Term) Error!bool {
        std.debug.assert(s.depth != 0);
        try s.define(pool, t);
        const w = &s.pending.writer;
        try w.writeAll("(push 1)\n(assert ");
        try writeRef(w, pool, t);
        try w.writeAll(")\n(check-sat)\n");
        const reply = try s.roundTrip(arena);
        if (std.mem.startsWith(u8, reply, "sat")) {
            s.depth += 1;
            return true;
        }
        try w.writeAll("(pop 1)\n");
        return false;
    }

    /// Asks again, so that `values` reads a model of the scope as it now stands.
    pub fn remodel(s: *Session, arena: Allocator) Error!void {
        try s.pending.writer.writeAll("(check-sat)\n");
        const reply = try s.roundTrip(arena);
        if (!std.mem.startsWith(u8, reply, "sat")) return error.SolverError;
    }

    /// Values of terms in the model of the last `sat` answer.
    pub fn values(s: *Session, arena: Allocator, pool: *const Pool, ts: []const Term) Error![]const Const {
        const out = try arena.alloc(Const, ts.len);
        if (ts.len == 0) return out;
        for (ts) |t| try s.define(pool, t);
        const w = &s.pending.writer;
        try w.writeAll("(get-value (");
        for (ts, 0..) |t, i| {
            if (i != 0) try w.writeByte(' ');
            try writeRef(w, pool, t);
        }
        try w.writeAll("))\n");
        const reply = try s.roundTrip(arena);
        const parsed = (try SExpr.parse(arena, reply)) orelse return error.SolverError;
        if (parsed != .list or parsed.list.len != ts.len) return error.SolverError;
        for (parsed.list, out) |pair, *slot| {
            if (pair != .list or pair.list.len != 2) return error.SolverError;
            slot.* = Const.fromSExpr(pair.list[1]);
        }
        return out;
    }
};

/// Finds the solver: an explicit path, `ZV_Z3`, or `z3` on PATH.
pub fn locate(explicit: ?[]const u8, environ: *const std.process.Environ.Map) []const u8 {
    if (explicit) |p| return p;
    if (environ.get("ZV_Z3")) |p| return p;
    return "z3";
}
