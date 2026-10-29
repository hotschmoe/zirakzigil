//! The `ownership` manifest: what a project tells `zv-own` about its own types when the checker cannot read it
//! off the code. Most code needs none: allocator flow, containers of std, `zv.Pool` and `zv.Slots`, and the
//! bodies of the functions in the packs are understood without a word written.
//!
//!     pub const Registry = struct {
//!         pub const ownership = .{
//!             .remove = .invalidates, // pointers handed out by the registry are stale afterwards
//!             .close = .ends,         // the registry is gone, with everything it handed out
//!         };
//!         ...
//!     };
//!     comptime { zv.requireOwnership(Registry); }
//!
//! Kinds: `.invalidates` (pointers into the receiver are stale), `.ends` (the receiver is gone), `.resets` (what
//! it handed out is gone, it stays usable), `.releases` (the buffer leaves the receiver, the result owns it),
//! `.reads` (only reads), `.handle` (the result is a handle that `.free` ends), `.free`, and, for the gate, `.trusted`:
//! the function is exempt from the check and counted (`--max-trusted`). A manifest can sit in any container; a name
//! is the method of that container.

const std = @import("std");

pub const kinds = [_][]const u8{ "invalidates", "ends", "resets", "releases", "reads", "handle", "free", "trusted" };

/// Compile error unless every entry of `T.ownership` names a declaration of `T` and a kind `zv-own` knows.
pub fn requireOwnership(comptime T: type) void {
    comptime {
        if (!@hasDecl(T, "ownership")) @compileError("zv: " ++ @typeName(T) ++ " has no `pub const ownership` manifest");
        const m = T.ownership;
        for (@typeInfo(@TypeOf(m)).@"struct".field_names) |name| {
            if (!@hasDecl(T, name))
                @compileError("zv: the ownership manifest of " ++ @typeName(T) ++ " names `" ++ name ++ "`, which it does not declare");
            const value = @field(m, name);
            if (@TypeOf(value) != @TypeOf(.enum_literal))
                @compileError("zv: ownership entry `" ++ name ++ "` must be an enum literal such as `.invalidates`");
            var known = false;
            for (kinds) |k| known = known or std.mem.eql(u8, k, @tagName(value));
            if (!known) @compileError("zv: `." ++ @tagName(value) ++ "` is not an ownership kind; use .invalidates, .ends, .resets, .releases, .reads, .handle, .free or .trusted");
        }
    }
}
