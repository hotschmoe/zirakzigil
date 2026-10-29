//! Hash-consed terms of the verification conditions: booleans, bit-vectors, unbounded integers and
//! arrays. Constructors fold constants and apply the identities that keep queries small; every term
//! is identified by structure, so equal terms are the same `Term`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Term = enum(u32) { _ };

pub const Sort = union(enum) {
    bool,
    bv: u16,
    int,
    array: struct { idx: u16, elem: u16 },
    /// A sequence of unbounded integers (ghost).
    seq,

    pub fn eql(a: Sort, b: Sort) bool {
        return std.meta.eql(a, b);
    }
};

pub const Op = enum {
    not,
    @"and",
    @"or",
    ite,
    eq,
    add,
    sub,
    mul,
    udiv,
    urem,
    sdiv,
    srem,
    smod,
    neg,
    bnot,
    band,
    bor,
    bxor,
    shl,
    lshr,
    ashr,
    ult,
    ule,
    slt,
    sle,
    zext,
    sext,
    extract,
    concat,
    select,
    store,
    iadd,
    isub,
    imul,
    idiv,
    imod,
    ineg,
    ilt,
    ile,
    bv2nat,
    int2bv,
    seq_empty,
    seq_unit,
    seq_concat,
    seq_len,
    seq_at,
    seq_extract,
};

pub const App = struct {
    op: Op,
    sort: Sort,
    args: [3]Term,
    len: u8,
    p: u16 = 0,
    q: u16 = 0,

    pub fn operands(a: *const App) []const Term {
        return a.args[0..a.len];
    }
};

pub const Node = union(enum) {
    bool_lit: bool,
    bv_lit: struct { bits: u16, value: u128 },
    int_lit: i128,
    variable: struct { name: u32, sort: Sort },
    app: App,
};

const NodeContext = struct {
    pub fn hash(_: NodeContext, n: Node) u64 {
        var h = std.hash.Wyhash.init(0);
        std.hash.autoHash(&h, n);
        return h.final();
    }
    pub fn eql(_: NodeContext, a: Node, b: Node) bool {
        return std.meta.eql(a, b);
    }
};

pub fn mask(bits: u16) u128 {
    return if (bits >= 128) std.math.maxInt(u128) else (@as(u128, 1) << @intCast(bits)) - 1;
}

pub fn signed(bits: u16, value: u128) i128 {
    if (bits >= 128) return @bitCast(value);
    const shift: u7 = @intCast(128 - bits);
    return @as(i128, @bitCast(value << shift)) >> shift;
}

pub const Pool = struct {
    gpa: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    index: std.HashMapUnmanaged(Node, Term, NodeContext, 80) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    name_index: std.StringHashMapUnmanaged(u32) = .empty,
    arena: std.heap.ArenaAllocator,
    fresh_count: u32 = 0,

    pub fn init(gpa: Allocator) Pool {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(p: *Pool) void {
        p.nodes.deinit(p.gpa);
        p.index.deinit(p.gpa);
        p.names.deinit(p.gpa);
        p.name_index.deinit(p.gpa);
        p.arena.deinit();
    }

    fn intern(p: *Pool, n: Node) Allocator.Error!Term {
        const gop = try p.index.getOrPut(p.gpa, n);
        if (!gop.found_existing) {
            gop.value_ptr.* = @fromBackingInt(@intCast(p.nodes.items.len));
            try p.nodes.append(p.gpa, n);
        }
        return gop.value_ptr.*;
    }

    pub fn node(p: *const Pool, t: Term) Node {
        return p.nodes.items[@backingInt(t)];
    }

    pub fn sortOf(p: *const Pool, t: Term) Sort {
        return switch (p.node(t)) {
            .bool_lit => .bool,
            .bv_lit => |l| .{ .bv = l.bits },
            .int_lit => .int,
            .variable => |v| v.sort,
            .app => |a| a.sort,
        };
    }

    pub fn bitsOf(p: *const Pool, t: Term) u16 {
        return switch (p.sortOf(t)) {
            .bv => |b| b,
            else => unreachable,
        };
    }

    pub fn name(p: *const Pool, id: u32) []const u8 {
        return p.names.items[id];
    }

    pub fn tru(p: *Pool) Allocator.Error!Term {
        return p.intern(.{ .bool_lit = true });
    }

    pub fn fls(p: *Pool) Allocator.Error!Term {
        return p.intern(.{ .bool_lit = false });
    }

    pub fn boolean(p: *Pool, b: bool) Allocator.Error!Term {
        return p.intern(.{ .bool_lit = b });
    }

    pub fn bv(p: *Pool, bits: u16, value: u128) Allocator.Error!Term {
        return p.intern(.{ .bv_lit = .{ .bits = bits, .value = value & mask(bits) } });
    }

    pub fn bvSigned(p: *Pool, bits: u16, value: i128) Allocator.Error!Term {
        return p.bv(bits, @bitCast(value));
    }

    pub fn int(p: *Pool, value: i128) Allocator.Error!Term {
        return p.intern(.{ .int_lit = value });
    }

    pub fn variable(p: *Pool, var_name: []const u8, sort: Sort) Allocator.Error!Term {
        const gop = try p.name_index.getOrPut(p.gpa, var_name);
        if (!gop.found_existing) {
            const owned = try p.arena.allocator().dupe(u8, var_name);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = @intCast(p.names.items.len);
            try p.names.append(p.gpa, owned);
        }
        return p.intern(.{ .variable = .{ .name = gop.value_ptr.*, .sort = sort } });
    }

    pub fn fresh(p: *Pool, base: []const u8, sort: Sort) Allocator.Error!Term {
        p.fresh_count += 1;
        var buf: [256]u8 = undefined;
        const n = std.fmt.bufPrint(&buf, "{s}!{d}", .{ base, p.fresh_count }) catch base;
        return p.variable(n, sort);
    }

    pub fn isTrue(p: *const Pool, t: Term) bool {
        return switch (p.node(t)) {
            .bool_lit => |b| b,
            else => false,
        };
    }

    pub fn isFalse(p: *const Pool, t: Term) bool {
        return switch (p.node(t)) {
            .bool_lit => |b| !b,
            else => false,
        };
    }

    pub fn bvValue(p: *const Pool, t: Term) ?u128 {
        return switch (p.node(t)) {
            .bv_lit => |l| l.value,
            else => null,
        };
    }

    pub fn intValue(p: *const Pool, t: Term) ?i128 {
        return switch (p.node(t)) {
            .int_lit => |v| v,
            else => null,
        };
    }

    fn app1(p: *Pool, op: Op, sort: Sort, a: Term, pp: u16, q: u16) Allocator.Error!Term {
        return p.intern(.{ .app = .{ .op = op, .sort = sort, .args = .{ a, @fromBackingInt(@intCast(0)), @fromBackingInt(@intCast(0)) }, .len = 1, .p = pp, .q = q } });
    }

    fn app2(p: *Pool, op: Op, sort: Sort, a: Term, b: Term) Allocator.Error!Term {
        return p.intern(.{ .app = .{ .op = op, .sort = sort, .args = .{ a, b, @fromBackingInt(@intCast(0)) }, .len = 2 } });
    }

    fn app3(p: *Pool, op: Op, sort: Sort, a: Term, b: Term, c: Term) Allocator.Error!Term {
        return p.intern(.{ .app = .{ .op = op, .sort = sort, .args = .{ a, b, c }, .len = 3 } });
    }

    fn isOp(p: *const Pool, t: Term, op: Op) ?App {
        return switch (p.node(t)) {
            .app => |a| if (a.op == op) a else null,
            else => null,
        };
    }

    // Booleans.

    pub fn not(p: *Pool, a: Term) Allocator.Error!Term {
        switch (p.node(a)) {
            .bool_lit => |b| return p.boolean(!b),
            .app => |ap| if (ap.op == .not) return ap.args[0],
            else => {},
        }
        return p.app1(.not, .bool, a, 0, 0);
    }

    pub fn @"and"(p: *Pool, a: Term, b: Term) Allocator.Error!Term {
        if (p.isFalse(a) or p.isFalse(b)) return p.fls();
        if (p.isTrue(a)) return b;
        if (p.isTrue(b)) return a;
        if (a == b) return a;
        if (p.isNegationOf(a, b)) return p.fls();
        return p.app2(.@"and", .bool, a, b);
    }

    pub fn @"or"(p: *Pool, a: Term, b: Term) Allocator.Error!Term {
        if (p.isTrue(a) or p.isTrue(b)) return p.tru();
        if (p.isFalse(a)) return b;
        if (p.isFalse(b)) return a;
        if (a == b) return a;
        if (p.isNegationOf(a, b)) return p.tru();
        return p.app2(.@"or", .bool, a, b);
    }

    fn isNegationOf(p: *const Pool, a: Term, b: Term) bool {
        if (p.isOp(a, .not)) |n| if (n.args[0] == b) return true;
        if (p.isOp(b, .not)) |n| if (n.args[0] == a) return true;
        return false;
    }

    pub fn implies(p: *Pool, a: Term, b: Term) Allocator.Error!Term {
        return p.@"or"(try p.not(a), b);
    }

    pub fn all(p: *Pool, ts: []const Term) Allocator.Error!Term {
        var acc = try p.tru();
        for (ts) |t| acc = try p.@"and"(acc, t);
        return acc;
    }

    pub fn ite(p: *Pool, c: Term, a: Term, b: Term) Allocator.Error!Term {
        if (p.isTrue(c)) return a;
        if (p.isFalse(c)) return b;
        if (a == b) return a;
        const sort = p.sortOf(a);
        assert(sort.eql(p.sortOf(b)));
        if (sort == .bool) {
            if (p.isTrue(a) and p.isFalse(b)) return c;
            if (p.isFalse(a) and p.isTrue(b)) return p.not(c);
            if (p.isTrue(a)) return p.@"or"(c, b);
            if (p.isFalse(b)) return p.@"and"(c, a);
        }
        if (p.isOp(c, .not)) |n| return p.ite(n.args[0], b, a);
        return p.app3(.ite, sort, c, a, b);
    }

    pub fn eq(p: *Pool, a: Term, b: Term) Allocator.Error!Term {
        assert(p.sortOf(a).eql(p.sortOf(b)));
        if (a == b) return p.tru();
        switch (p.node(a)) {
            .bool_lit => |x| return if (x) b else p.not(b),
            .bv_lit => |x| if (p.node(b) == .bv_lit) return p.boolean(x.value == p.node(b).bv_lit.value),
            .int_lit => |x| if (p.node(b) == .int_lit) return p.boolean(x == p.node(b).int_lit),
            else => {},
        }
        if (p.node(b) == .bool_lit) return p.eq(b, a);
        return p.app2(.eq, .bool, a, b);
    }

    pub fn ne(p: *Pool, a: Term, b: Term) Allocator.Error!Term {
        return p.not(try p.eq(a, b));
    }

    // Bit-vectors.

    pub fn bin(p: *Pool, op: Op, a: Term, b: Term) Allocator.Error!Term {
        const bits = p.bitsOf(a);
        assert(bits == p.bitsOf(b));
        if (p.bvValue(a)) |x| if (p.bvValue(b)) |y| if (foldBin(op, bits, x, y)) |v| return p.bv(bits, v);
        const y_zero = p.bvValue(b) == 0;
        const x_zero = p.bvValue(a) == 0;
        switch (op) {
            .add => {
                if (y_zero) return a;
                if (x_zero) return b;
            },
            .sub => if (y_zero) return a,
            .mul => {
                if (y_zero or x_zero) return p.bv(bits, 0);
                if (p.bvValue(b) == 1) return a;
                if (p.bvValue(a) == 1) return b;
            },
            .band => {
                if (y_zero or x_zero) return p.bv(bits, 0);
                if (a == b) return a;
                if (p.bvValue(b) == mask(bits)) return a;
                if (p.bvValue(a) == mask(bits)) return b;
            },
            .bor => {
                if (y_zero) return a;
                if (x_zero) return b;
                if (a == b) return a;
            },
            .bxor => {
                if (y_zero) return a;
                if (x_zero) return b;
                if (a == b) return p.bv(bits, 0);
            },
            .shl, .lshr, .ashr => if (y_zero) return a,
            else => {},
        }
        return p.app2(op, .{ .bv = bits }, a, b);
    }

    fn foldBin(op: Op, bits: u16, x: u128, y: u128) ?u128 {
        const m = mask(bits);
        return switch (op) {
            .add => (x +% y) & m,
            .sub => (x -% y) & m,
            .mul => (x *% y) & m,
            .udiv => if (y == 0) null else x / y,
            .urem => if (y == 0) null else x % y,
            .sdiv => blk: {
                const sx = signed(bits, x);
                const sy = signed(bits, y);
                if (sy == 0 or sy == -1) break :blk null;
                break :blk @as(u128, @bitCast(@divTrunc(sx, sy))) & m;
            },
            .srem => blk: {
                const sx = signed(bits, x);
                const sy = signed(bits, y);
                if (sy == 0 or sy == -1) break :blk null;
                break :blk @as(u128, @bitCast(@rem(sx, sy))) & m;
            },
            .band => x & y,
            .bor => x | y,
            .bxor => x ^ y,
            .shl => if (y >= bits) 0 else (x << @intCast(y)) & m,
            .lshr => if (y >= bits) 0 else x >> @intCast(y),
            .ashr => blk: {
                const sx = signed(bits, x);
                const sh: u7 = if (y >= bits) @intCast(@min(bits - 1, 127)) else @intCast(y);
                break :blk @as(u128, @bitCast(sx >> sh)) & m;
            },
            else => null,
        };
    }

    pub fn cmp(p: *Pool, op: Op, a: Term, b: Term) Allocator.Error!Term {
        const bits = p.bitsOf(a);
        assert(bits == p.bitsOf(b));
        if (p.bvValue(a)) |x| if (p.bvValue(b)) |y| {
            return p.boolean(switch (op) {
                .ult => x < y,
                .ule => x <= y,
                .slt => signed(bits, x) < signed(bits, y),
                .sle => signed(bits, x) <= signed(bits, y),
                else => unreachable,
            });
        };
        if (a == b) return p.boolean(op == .ule or op == .sle);
        return p.app2(op, .bool, a, b);
    }

    pub fn bnot(p: *Pool, a: Term) Allocator.Error!Term {
        const bits = p.bitsOf(a);
        if (p.bvValue(a)) |x| return p.bv(bits, ~x);
        return p.app1(.bnot, .{ .bv = bits }, a, 0, 0);
    }

    pub fn neg(p: *Pool, a: Term) Allocator.Error!Term {
        const bits = p.bitsOf(a);
        if (p.bvValue(a)) |x| return p.bv(bits, 0 -% x);
        return p.app1(.neg, .{ .bv = bits }, a, 0, 0);
    }

    pub fn zext(p: *Pool, a: Term, to: u16) Allocator.Error!Term {
        const bits = p.bitsOf(a);
        if (to == bits) return a;
        assert(to > bits);
        if (p.bvValue(a)) |x| return p.bv(to, x);
        return p.app1(.zext, .{ .bv = to }, a, to - bits, 0);
    }

    pub fn sext(p: *Pool, a: Term, to: u16) Allocator.Error!Term {
        const bits = p.bitsOf(a);
        if (to == bits) return a;
        assert(to > bits);
        if (p.bvValue(a)) |x| return p.bvSigned(to, signed(bits, x));
        return p.app1(.sext, .{ .bv = to }, a, to - bits, 0);
    }

    /// Bits `hi..lo` inclusive.
    pub fn extract(p: *Pool, a: Term, hi: u16, lo: u16) Allocator.Error!Term {
        const bits = p.bitsOf(a);
        assert(hi >= lo and hi < bits);
        if (lo == 0 and hi + 1 == bits) return a;
        if (p.bvValue(a)) |x| return p.bv(hi - lo + 1, x >> @intCast(lo));
        return p.app1(.extract, .{ .bv = hi - lo + 1 }, a, hi, lo);
    }

    pub fn concat(p: *Pool, hi: Term, lo: Term) Allocator.Error!Term {
        const hb = p.bitsOf(hi);
        const lb = p.bitsOf(lo);
        if (p.bvValue(hi)) |x| if (p.bvValue(lo)) |y| return p.bv(hb + lb, (x << @intCast(lb)) | y);
        return p.app2(.concat, .{ .bv = hb + lb }, hi, lo);
    }

    // Arrays.

    pub fn select(p: *Pool, arr: Term, idx: Term) Allocator.Error!Term {
        const s = p.sortOf(arr).array;
        assert(p.bitsOf(idx) == s.idx);
        if (p.isOp(arr, .store)) |st| {
            if (st.args[1] == idx) return st.args[2];
            if (p.bvValue(st.args[1]) != null and p.bvValue(idx) != null) return p.select(st.args[0], idx);
        }
        return p.app2(.select, .{ .bv = s.elem }, arr, idx);
    }

    pub fn store(p: *Pool, arr: Term, idx: Term, v: Term) Allocator.Error!Term {
        return p.app3(.store, p.sortOf(arr), arr, idx, v);
    }

    // Unbounded integers (ghost).

    pub fn ibin(p: *Pool, op: Op, a: Term, b: Term) Allocator.Error!Term {
        if (p.intValue(a)) |x| if (p.intValue(b)) |y| switch (op) {
            .iadd => return p.int(x + y),
            .isub => return p.int(x - y),
            .imul => return p.int(x * y),
            .idiv => if (y != 0) return p.int(@divFloor(x, y)),
            .imod => if (y != 0) return p.int(@mod(x, y)),
            .ilt => return p.boolean(x < y),
            .ile => return p.boolean(x <= y),
            else => unreachable,
        };
        const sort: Sort = switch (op) {
            .ilt, .ile => .bool,
            else => .int,
        };
        return p.app2(op, sort, a, b);
    }

    pub fn ineg(p: *Pool, a: Term) Allocator.Error!Term {
        if (p.intValue(a)) |x| return p.int(-x);
        return p.app1(.ineg, .int, a, 0, 0);
    }

    pub fn bv2nat(p: *Pool, a: Term, is_signed: bool) Allocator.Error!Term {
        const bits = p.bitsOf(a);
        if (p.bvValue(a)) |x| return p.int(if (is_signed) signed(bits, x) else @intCast(x));
        return p.app1(.bv2nat, .int, a, @intFromBool(is_signed), 0);
    }

    pub fn int2bv(p: *Pool, a: Term, bits: u16) Allocator.Error!Term {
        if (p.intValue(a)) |x| return p.bvSigned(bits, x);
        return p.app1(.int2bv, .{ .bv = bits }, a, bits, 0);
    }

    // Sequences (ghost), of unbounded integers.

    pub fn seqEmpty(p: *Pool) Allocator.Error!Term {
        return p.intern(.{ .app = .{ .op = .seq_empty, .sort = .seq, .args = @splat(@fromBackingInt(@intCast(0))), .len = 0 } });
    }

    pub fn seqUnit(p: *Pool, a: Term) Allocator.Error!Term {
        return p.app1(.seq_unit, .seq, a, 0, 0);
    }

    pub fn seqConcat(p: *Pool, a: Term, b: Term) Allocator.Error!Term {
        if (p.isOp(a, .seq_empty) != null) return b;
        if (p.isOp(b, .seq_empty) != null) return a;
        return p.app2(.seq_concat, .seq, a, b);
    }

    pub fn seqLen(p: *Pool, a: Term) Allocator.Error!Term {
        if (p.isOp(a, .seq_empty) != null) return p.int(0);
        if (p.isOp(a, .seq_unit) != null) return p.int(1);
        return p.app1(.seq_len, .int, a, 0, 0);
    }

    pub fn seqAt(p: *Pool, a: Term, i: Term) Allocator.Error!Term {
        if (p.isOp(a, .seq_unit)) |u| if (p.intValue(i) == 0) return u.args[0];
        return p.app2(.seq_at, .int, a, i);
    }

    /// `a[off .. off + len]`.
    pub fn seqExtract(p: *Pool, a: Term, off: Term, len: Term) Allocator.Error!Term {
        return p.app3(.seq_extract, .seq, a, off, len);
    }
};
