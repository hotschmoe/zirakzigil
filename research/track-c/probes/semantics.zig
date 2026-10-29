//! Small, version-neutral probe for what stock backends keep of Zig semantics.
//! Exported so the compiler must analyze every function. No std import, so the
//! output is the function itself plus compiler_rt, not the whole standard library.

export fn addChecked(a: u32, b: u32) u32 {
    return a + b;
}

export fn addWrap(a: u32, b: u32) u32 {
    return a +% b;
}

export fn index(buf: [*]const u8, len: usize, i: usize) u8 {
    const s: []const u8 = buf[0..len];
    return s[i];
}

export fn requires(ok: bool) void {
    if (!ok) @panic("precondition violated");
}

export fn midpoint(lo: u32, hi: u32) u32 {
    requires(lo <= hi);
    return lo + (hi - lo) / 2;
}

fn generic(comptime T: type, x: T, y: T) T {
    return if (x > y) x else y;
}

export fn useGeneric(a: u32, b: u8) u32 {
    return generic(u32, a, 2) + generic(u8, b, 4);
}

export fn mayFail(x: u32) u32 {
    if (x == 0) unreachable;
    return x * 2;
}

export fn contracts(lo: u32, hi: u32) u32 {
    if (!(lo <= hi)) @panic("zv: precondition violated");
    const mid = lo + (hi - lo) / 2;
    if (!(lo <= mid and mid <= hi)) @panic("zv: postcondition violated");
    return mid;
}
