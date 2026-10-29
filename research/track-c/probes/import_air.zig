//! Attempts to use upstream compiler AIR from a stock compiler. Referencing a
//! declaration forces analysis of Air.zig and everything it imports.
const Air = @import("air_upstream");

pub fn main() void {
    // Calling the printer analyzes its body. That body imports the
    // compiler-only `build_options` module.
    Air.write(undefined, undefined, undefined, null) catch {};
}
