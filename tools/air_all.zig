//! Root for exporting a file whose functions are not all reachable from its tests:
//!   zig-zv test -fno-emit-bin --zv-air-out DIR --dep target -Mroot=tools/air_all.zig -Mtarget=FILE.zig
//! Taking the address of every pub function as a runtime value makes the compiler analyze its body.
const std = @import("std");
const target = @import("target");

test "analyze every pub fn" {
    inline for (@typeInfo(target).@"struct".decl_names) |name| {
        const value = @field(target, name);
        if (@typeInfo(@TypeOf(value)) == .@"fn") std.mem.doNotOptimizeAway(&value);
    }
}
