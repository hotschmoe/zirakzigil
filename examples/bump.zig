//! A bump allocator over a fixed region of bytes, specified with `zv.PointsTo` permission tokens
//! (docs/phase4.md). The core manages offsets; the bytes themselves stay with the caller, as in Verus, where
//! an allocator hands out addresses and a token says who may use them. `zvc` proves of every block it
//! hands out: in bounds, aligned, and disjoint from every other block that is live, and that `free` and
//! `reset` give back exactly what was taken. The allocator state is a value that goes in and comes out
//! (`zvc` follows no pointer parameters yet), and so does every token: one that is passed on is gone.
//!
//! Positions, not lengths, are what the specification talks about (`end` of a block, not `off + len`): every
//! fact is then a comparison, and the proofs need no arithmetic beyond computing the positions once.
//!
//! `Arena` is the checked shell over a real buffer: it turns blocks into slices and keeps the permission
//! for everything handed out, so `reset` is always legal for its callers.

const std = @import("std");
const zv = @import("zv");

pub const assurance = .{
    .init = .verified,
    .padTo = .verified,
    .carve = .verified,
    .alloc = .verified,
    .free = .verified,
    .reset = .verified,
    .pair = .verified,
    .Arena = .{ .init = .checked, .alloc = .checked, .reset = .checked },
    .laws = .{ .blocks_hold = .tested, .pair_holds = .tested },
};

comptime {
    zv.requireAssurance(@This(), .tested);
}

const module = @This();

pub const Bump = struct {
    cap: usize,
    /// Everything below `next` was handed out or skipped for alignment; everything from `next` on is free.
    next: usize,
    /// Ghost: the permission for the free bytes, `[next, cap)`.
    free: zv.PointsTo,
};

pub const Block = struct {
    /// Where the allocator was before this block, where the bytes start (after the alignment padding) and where
    /// they end.
    base: usize,
    off: usize,
    end: usize,
    /// Ghost: the permission for `[base, end)`: the padding and the bytes.
    perm: zv.PointsTo,
};

pub const Result = struct { bump: Bump, block: ?Block };

pub const Two = struct { bump: Bump, first: ?Block, second: ?Block };

inline fn wf(b: Bump) bool {
    return !zv.ghost or (b.next <= b.cap and b.free.lo == b.next and b.free.hi == b.cap);
}

inline fn owns(blk: Block) bool {
    return !zv.ghost or (blk.perm.lo == blk.base and blk.perm.hi == blk.end and blk.base <= blk.off and blk.off <= blk.end);
}

inline fn isPow2(n: usize) bool {
    return n != 0 and n & (n -% 1) == 0;
}

inline fn carved(b: Bump, off: usize, end: usize, r: Result) bool {
    const blk = r.block orelse return false;
    return wf(r.bump) and owns(blk) and r.bump.cap == b.cap and r.bump.next == end and
        blk.base == b.next and blk.off == off and blk.end == end;
}

inline fn granted(b: Bump, len: usize, alignment: usize, r: Result) bool {
    const blk = r.block orelse return false;
    return wf(r.bump) and owns(blk) and r.bump.cap == b.cap and r.bump.next == blk.end and
        blk.base == b.next and blk.off +% len == blk.end and blk.off & (alignment -% 1) == 0;
}

inline fn padFor(n: usize, alignment: usize) usize {
    return (0 -% n) & (alignment -% 1);
}

/// A request is refused only when it does not fit with the padding it needs.
inline fn refused(b: Bump, len: usize, alignment: usize, r: Result) bool {
    if (r.block) |_| return false;
    const room = b.cap -% b.next;
    const pad = padFor(b.next, alignment);
    return wf(r.bump) and r.bump.cap == b.cap and r.bump.next == b.next and (pad > room or len > room -% pad);
}

pub fn init(region: []u8) Bump {
    const whole = if (zv.ghost) zv.PointsTo.own(region) else {};
    const b: Bump = .{ .cap = region.len, .next = 0, .free = whole };
    return zv.ensures(b, b.cap == region.len and b.next == 0 and wf(b));
}

/// The bytes from `n` to the next multiple of `alignment`, which must be a power of two.
pub fn padTo(n: usize, alignment: usize) usize {
    zv.requires(isPow2(alignment));
    const pad = (0 -% n) & (alignment - 1);
    return zv.ensures(pad, pad < alignment and (n +% pad) & (alignment -% 1) == 0);
}

/// The block `[off, end)`, with the padding before it from where the allocator was.
pub fn carve(b: Bump, off: usize, end: usize) Result {
    zv.requires(wf(b) and b.next <= off and off <= end and end <= b.cap);
    const parts = if (zv.ghost) b.free.split(end) else {};
    const r: Result = .{
        .bump = .{ .cap = b.cap, .next = end, .free = if (zv.ghost) parts.tail else {} },
        .block = .{ .base = b.next, .off = off, .end = end, .perm = if (zv.ghost) parts.head else {} },
    };
    return zv.ensures(r, carved(b, off, end, r));
}

/// A block of `len` bytes at a multiple of `alignment`, which must be a power of two.
pub fn alloc(b: Bump, len: usize, alignment: usize) Result {
    zv.requires(wf(b) and isPow2(alignment));
    const pad = padTo(b.next, alignment);
    const room = b.cap - b.next;
    if (pad <= room and len <= room - pad) {
        const off = b.next + pad;
        const r = carve(b, off, off + len);
        return zv.ensures(r, granted(b, len, alignment, r));
    }
    const r: Result = .{ .bump = b, .block = null };
    return zv.ensures(r, refused(b, len, alignment, r));
}

/// Takes back the block that was handed out last, padding included.
pub fn free(b: Bump, blk: Block) Bump {
    zv.requires(wf(b) and owns(blk) and blk.end == b.next);
    const whole = if (zv.ghost) blk.perm.join(b.free) else {};
    const out: Bump = .{ .cap = b.cap, .next = blk.base, .free = whole };
    return zv.ensures(out, out.cap == b.cap and out.next == blk.base and wf(out));
}

/// Takes back every block at once. `used` is the permission for all of them, joined: `[0, next)`, which is
/// the proof that nobody holds one any more.
pub fn reset(b: Bump, used: zv.PointsTo) Bump {
    zv.requires(wf(b));
    zv.requires(!zv.ghost or (used.lo == 0 and used.hi == b.next));
    const whole = if (zv.ghost) used.join(b.free) else {};
    const out: Bump = .{ .cap = b.cap, .next = 0, .free = whole };
    return zv.ensures(out, out.cap == b.cap and out.next == 0 and wf(out));
}

inline fn together(b: Bump, n: usize, m: usize, alignment: usize, t: Two) bool {
    const x = t.first orelse return false;
    const y = t.second orelse return false;
    return wf(t.bump) and owns(x) and owns(y) and t.bump.cap == b.cap and t.bump.next == y.end and
        x.base == b.next and x.off +% n == x.end and y.off +% m == y.end and
        x.off & (alignment -% 1) == 0 and y.off & (alignment -% 1) == 0 and
        x.end <= y.off and (!zv.ghost or x.perm.hi <= y.perm.lo);
}

inline fn nothing(b: Bump, t: Two) bool {
    if (t.first) |_| return false;
    if (t.second) |_| return false;
    return wf(t.bump) and t.bump.cap == b.cap and t.bump.next == b.next;
}

/// Two allocations in a row: a caller that knows `alloc` only through its contract still gets blocks that
/// do not overlap, and a failure of the second leaves the allocator as it was.
pub fn pair(b: Bump, n: usize, m: usize, alignment: usize) Two {
    zv.requires(wf(b) and isPow2(alignment));
    const r1 = alloc(b, n, alignment);
    if (r1.block) |x| {
        const r2 = alloc(r1.bump, m, alignment);
        if (r2.block) |y| {
            const t: Two = .{ .bump = r2.bump, .first = x, .second = y };
            return zv.ensures(t, together(b, n, m, alignment, t));
        }
        const t: Two = .{ .bump = free(r2.bump, x), .first = null, .second = null };
        return zv.ensures(t, nothing(b, t));
    }
    const t: Two = .{ .bump = r1.bump, .first = null, .second = null };
    return zv.ensures(t, nothing(b, t));
}

/// The shell over bytes: blocks become slices, and the permissions of everything handed out stay in `used`.
pub const Arena = struct {
    region: []align(base_alignment) u8,
    bump: Bump,
    used: zv.PointsTo,

    /// The strictest alignment `alloc` accepts; `region` is aligned to it.
    pub const base_alignment = 64;

    pub fn init(region: []align(base_alignment) u8) Arena {
        const core = module.init(region);
        const parts = if (zv.ghost) core.free.split(0) else {};
        return .{
            .region = region,
            .bump = .{ .cap = core.cap, .next = core.next, .free = if (zv.ghost) parts.tail else {} },
            .used = if (zv.ghost) parts.head else {},
        };
    }

    pub fn alloc(self: *Arena, comptime alignment: usize, len: usize) ?[]align(alignment) u8 {
        comptime std.debug.assert(alignment <= base_alignment);
        const r = module.alloc(self.bump, len, alignment);
        self.bump = r.bump;
        const blk = r.block orelse return null;
        if (zv.ghost) self.used = self.used.join(blk.perm);
        return @alignCast(self.region[blk.off..blk.end]);
    }

    pub fn reset(self: *Arena) void {
        const core = module.reset(self.bump, self.used);
        const parts = if (zv.ghost) core.free.split(0) else {};
        self.bump = .{ .cap = core.cap, .next = core.next, .free = if (zv.ghost) parts.tail else {} };
        self.used = if (zv.ghost) parts.head else {};
    }
};

/// LAWS: the allocator behaves like its specification on any sequence of requests.
pub const laws = struct {
    /// Blocks stay inside the region, aligned in memory, disjoint, and keep their bytes, through any
    /// mix of allocations and resets; every request that fits with its worst padding is served.
    pub fn blocks_hold(ops: [24]u8, sizes: [24]u8) bool {
        var region: [256]u8 align(Arena.base_alignment) = undefined;
        var arena = Arena.init(&region);
        var live: [24]struct { off: usize, len: usize, id: u8 } = undefined;
        var n: usize = 0;
        for (ops, sizes, 0..) |op, size, step| {
            if (op % 8 == 0) {
                arena.reset();
                n = 0;
            } else {
                const len: usize = size % 70;
                const got = switch (op % 4) {
                    0 => allocAt(&arena, 1, len),
                    1 => allocAt(&arena, 8, len),
                    2 => allocAt(&arena, 16, len),
                    else => allocAt(&arena, 64, len),
                };
                const slice = got orelse {
                    if (len + 63 <= arena.region.len - arena.bump.next) return false;
                    continue;
                };
                const off = @intFromPtr(slice.ptr) - @intFromPtr(&region);
                if (off + slice.len > region.len) return false;
                const id: u8 = @intCast(step + 1);
                @memset(slice, id);
                live[n] = .{ .off = off, .len = slice.len, .id = id };
                n += 1;
            }
            for (live[0..n], 0..) |a, i| {
                for (region[a.off..][0..a.len]) |byte| if (byte != a.id) return false;
                for (live[i + 1 .. n]) |b| if (a.off + a.len > b.off and b.off + b.len > a.off) return false;
            }
        }
        return true;
    }

    fn allocAt(arena: *Arena, comptime alignment: usize, len: usize) ?[]u8 {
        const slice = arena.alloc(alignment, len) orelse return null;
        if (@intFromPtr(slice.ptr) % alignment != 0) @panic("misaligned block");
        return slice;
    }

    /// Two allocations never overlap, whatever the sizes and alignments; a second that does not fit leaves
    /// the region untouched, and `free` of the first gives back exactly what it took.
    pub fn pair_holds(n: u8, m: u8, shift: u3) bool {
        var region: [128]u8 align(Arena.base_alignment) = undefined;
        const t = pair(init(&region), n % 80, m % 80, @as(usize, 1) << shift);
        const x = t.first orelse return t.second == null and t.bump.next == 0;
        const y = t.second orelse return false;
        return x.end <= y.off and y.end <= region.len and t.bump.next == y.end;
    }
};

test "laws hold on random request sequences" {
    try zv.checkLaws(laws, .{ .iterations = 4_000, .seed = 0xB0B });
}

test "an arena refuses what does not fit and serves again after reset" {
    var region: [64]u8 align(Arena.base_alignment) = undefined;
    var arena = Arena.init(&region);
    const a = arena.alloc(16, 40).?;
    try std.testing.expectEqual(@as(usize, 40), a.len);
    try std.testing.expect(arena.alloc(16, 40) == null);
    const b = arena.alloc(8, 24).?;
    try std.testing.expectEqual(@as(usize, 24), b.len);
    arena.reset();
    try std.testing.expect(arena.alloc(64, 64) != null);
}

test "the core alone: pair gives disjoint blocks and undoes a failed second request" {
    var region: [32]u8 align(Arena.base_alignment) = undefined;
    const t = pair(init(&region), 10, 12, 4);
    const x = t.first.?;
    const y = t.second.?;
    try std.testing.expect(x.end <= y.off and y.off % 4 == 0);
    const refused_too = pair(init(&region), 10, 30, 4);
    try std.testing.expect(refused_too.first == null and refused_too.bump.next == 0);
}

test "tokens cost nothing outside ghost builds" {
    try std.testing.expectEqual(@as(usize, if (zv.ghost) 4 * @sizeOf(usize) else 2 * @sizeOf(usize)), @sizeOf(Bump));
}
