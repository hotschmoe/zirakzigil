//! The reader library for zig-zv AIR packs (schema v2). Phase 2's `zvc` imports this as `zv_air`.
//! It shares no code with the compiler.

pub const schema = @import("schema.zig");
pub const json = @import("json.zig");
pub const reader = @import("reader.zig");
pub const slice = @import("slice.zig");
pub const Builder = @import("builder.zig").Builder;

pub const Pack = schema.Pack;
pub const Set = reader.Set;
pub const loadPack = reader.loadPack;
