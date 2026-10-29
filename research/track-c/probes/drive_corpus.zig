//! Forces analysis of every corpus function. The corpus test already does this,
//! but `zig build-obj` on the corpus file alone emits nothing: unreferenced
//! functions are not analyzed.
const c = @import("corpus");
const std = @import("std");

export fn drive() void {
    var buf = [_]u8{ 1, 2, 3, 4 };
    var n: c.Node = .{ .value = 2, .next = null };
    var at: u32 = 0;
    const v: @Vector(4, f32) = .{ 1, 2, 3, 4 };
    var dst: [4]u8 = undefined;
    c.memory(&dst, &buf);
    std.mem.doNotOptimizeAway(.{
        c.arith(3, 4),                            c.floats(2, 1),
        c.bits(0xf0),                             c.casts(300, 2.5),
        c.slices(&buf, 1),                        c.arrays(),
        c.optionals(&at, null),                   c.errors(5),
        c.tryChain(3) catch 0,                    c.area(.{ .circle = 1 }),
        c.area(.{ .rect = .{ .w = 1, .h = 2 } }), c.switches('b'),
        c.loops(5),                               c.packedOps(.{ .a = 1, .b = 2, .c = 3 }),
        n.sum(),                                  c.useGeneric(),
        c.inlineCalls(2),                         c.fnPointers(&c.inlineCalls, 3),
        c.atomics(&at),                           c.vectors(v, v),
        c.deferred(2),                            c.unreachableAndAssert(3),
        c.structs(),
    });
}
