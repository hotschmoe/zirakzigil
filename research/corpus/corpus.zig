//! Version-neutral AIR corpus: compiles unchanged on Zig 0.16.0 and 0.17.0,
//! and touches a broad spread of AIR instruction kinds.
const std = @import("std");

pub fn arith(a: u32, b: u32) u32 {
    const s = a +% b;
    const d = a -| b;
    const p = @mulWithOverflow(a, b);
    return s ^ d ^ p[0] ^ @as(u32, p[1]) ^ (a / (b | 1)) ^ (a % (b | 1)) ^ (a << 3) ^ (b >> 2);
}

pub fn floats(x: f64, y: f32) f64 {
    return @sqrt(x) + @as(f64, y) * 0.5 - @floor(x) + @mulAdd(f64, x, x, 1.0);
}

pub fn bits(x: u64) u32 {
    return @popCount(x) + @clz(x) + @ctz(x) + @as(u32, @truncate(@byteSwap(x) ^ @bitReverse(x)));
}

pub fn casts(x: i64, f: f32) u8 {
    const a: i32 = @intCast(x & 0xff);
    const b: u16 = @truncate(@as(u64, @bitCast(x)));
    const c: i32 = @intFromFloat(f);
    const d: f32 = @floatFromInt(a);
    return @truncate(@as(u32, @bitCast(a +% c)) +% b +% @as(u32, @intFromFloat(@abs(d))));
}

pub fn slices(buf: []u8, idx: usize) u8 {
    if (buf.len == 0) return 0;
    const s = buf[idx % buf.len ..];
    var sum: u8 = 0;
    for (s, 0..) |x, i| sum +%= x +% @as(u8, @truncate(i));
    @memset(buf[0..@min(buf.len, 2)], 7);
    return sum +% buf.ptr[0];
}

pub fn arrays() u32 {
    var a = [_]u32{ 1, 2, 3, 4 };
    const b = a;
    a[1] = b[3];
    var total: u32 = 0;
    for (a) |v| total += v;
    return total;
}

pub fn optionals(x: ?*const u32, y: ?u32) u32 {
    const a = if (x) |p| p.* else 0;
    const b = y orelse 5;
    return a + b;
}

pub const Error = error{ Bad, Worse };

pub fn mayFail(x: u32) Error!u32 {
    if (x == 0) return error.Bad;
    if (x > 100) return error.Worse;
    return x * 2;
}

pub fn errors(x: u32) u32 {
    const a = mayFail(x) catch |e| switch (e) {
        error.Bad => return 1,
        error.Worse => return 2,
    };
    return a;
}

pub fn tryChain(x: u32) Error!u32 {
    errdefer std.mem.doNotOptimizeAway(x);
    const a = try mayFail(x);
    return try mayFail(a);
}

pub const Shape = union(enum) {
    circle: f32,
    rect: struct { w: f32, h: f32 },
    none,
};

pub fn area(s: Shape) f32 {
    return switch (s) {
        .circle => |r| 3.14159 * r * r,
        .rect => |r| r.w * r.h,
        .none => 0,
    };
}

pub fn switches(x: u8) u8 {
    return switch (x) {
        0 => 1,
        1...9 => x * 2,
        'a', 'b', 'c' => 3,
        else => |v| v -% 1,
    };
}

pub fn loops(n: u32) u32 {
    var i: u32 = 0;
    var acc: u32 = 0;
    outer: while (i < n) : (i += 1) {
        var j: u32 = 0;
        while (j < 4) : (j += 1) {
            if (j == i) continue :outer;
            if (acc > 1000) break :outer;
            acc +%= i * j;
        }
    }
    return acc;
}

pub const Packed = packed struct(u16) { a: u4, b: u8, c: u4 };

pub fn packedOps(p: Packed) Packed {
    var q = p;
    q.b +%= q.a;
    q.c = @truncate(q.b);
    return q;
}

pub const Node = struct {
    value: i32,
    next: ?*Node,

    pub fn sum(self: *const Node) i32 {
        var total: i32 = 0;
        var cur: ?*const Node = self;
        while (cur) |n| : (cur = n.next) total +%= n.value;
        return total;
    }
};

pub fn generic(comptime T: type, items: []const T) T {
    var best: T = items[0];
    for (items[1..]) |x| best = @max(best, x);
    return best;
}

pub fn useGeneric() i64 {
    const a = [_]u8{ 3, 9, 2 };
    const b = [_]i64{ -3, 4 };
    return generic(u8, &a) + generic(i64, &b);
}

inline fn helper(x: u32) u32 {
    return x *% 3;
}

pub fn inlineCalls(x: u32) u32 {
    return helper(x) + helper(x + 1);
}

pub fn fnPointers(f: *const fn (u32) u32, x: u32) u32 {
    return f(x) + @call(.never_inline, arith, .{ x, 1 });
}

pub fn atomics(p: *u32) u32 {
    _ = @atomicRmw(u32, p, .Add, 1, .seq_cst);
    @atomicStore(u32, p, 5, .release);
    return @atomicLoad(u32, p, .acquire) + (@cmpxchgStrong(u32, p, 5, 6, .seq_cst, .seq_cst) orelse 0);
}

pub fn vectors(a: @Vector(4, f32), b: @Vector(4, f32)) f32 {
    const c = a * b + a;
    return @reduce(.Add, c);
}

pub fn deferred(x: u32) u32 {
    var y = x;
    defer y += 1;
    {
        defer y *= 2;
    }
    return y;
}

pub fn unreachableAndAssert(x: u32) u32 {
    std.debug.assert(x != 7);
    if (x == 8) unreachable;
    return x;
}

pub fn structs() u32 {
    const P = struct { x: u32, y: u32 = 4 };
    var p: P = .{ .x = 1 };
    p.y += p.x;
    const t = .{ p.x, p.y, @as(u32, 9) };
    return t[0] + t[1] + t[2];
}

pub fn memory(dst: []u8, src: []const u8) void {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
}

test "corpus" {
    var buf = [_]u8{ 1, 2, 3, 4 };
    var n: Node = .{ .value = 2, .next = null };
    var at: u32 = 0;
    const v: @Vector(4, f32) = .{ 1, 2, 3, 4 };
    var dst: [4]u8 = undefined;
    memory(&dst, &buf);
    std.mem.doNotOptimizeAway(.{
        arith(3, 4),                                     floats(2, 1),
        bits(0xf0),                                      casts(300, 2.5),
        slices(&buf, 1),                                 arrays(),
        optionals(&at, null),                            errors(5),
        tryChain(3) catch 0,                             area(.{ .circle = 1 }),
        area(.{ .rect = .{ .w = 1, .h = 2 } }),          switches('b'),
        loops(5),                                        packedOps(.{ .a = 1, .b = 2, .c = 3 }),
        n.sum(),                                         useGeneric(),
        inlineCalls(2),                                  fnPointers(&inlineCalls, 3),
        atomics(&at),                                    vectors(v, v),
        deferred(2),                                     unreachableAndAssert(3),
        structs(),
    });
}
