//! Coverage evidence for the Phase 0 gate. `instrument.zig` plants a call to
//! `hit` at the top of every function body in a generated copy of the source;
//! nobody writes it by hand (the tool rejects source that does). The first
//! execution of each function prints one `zv-cover <id>` line to stdout, which
//! the build captures; stderr stays free for test failures.

const std = @import("std");

fn Once(comptime id: u32) type {
    return struct {
        comptime id: u32 = id,
        var seen: bool = false;
    };
}

pub inline fn hit(comptime id: u32) void {
    if (@inComptime()) return;
    const once = Once(id);
    if (once.seen) return;
    once.seen = true;
    var line: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "zv-cover {d}\n", .{id}) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, text) catch {};
}
