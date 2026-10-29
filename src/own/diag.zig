//! What the checker reports: findings with a position, the path that leads there, and notes that point at
//! the related places (where a value was created, where it was consumed first).

const std = @import("std");
const zv_air = @import("zv_air");
const schema = zv_air.schema;
const dom = @import("domain.zig");

pub const Kind = enum {
    /// A linear value consumed a second time.
    double_consume,
    /// A linear value read or borrowed after it was consumed.
    use_after_consume,
    /// A linear value that a path leaves without consuming or handing on.
    leak,
    /// Memory read, written or passed on after it was freed, or after the storage it points into was reallocated.
    use_after_free,
    /// An allocation freed twice.
    double_free,
    /// A pointer into a stack slot that outlives the function.
    escape_local,
    /// A pointer into an arena or other region that outlives it.
    escape_region,
    /// A value of a pinned type (it holds a `zv.PinCheck`) copied by value.
    pinned_copy,
    /// Two ranges of one array that overlap where they must not (`@memcpy`).
    alias,
    /// A construct outside the supported fragment: the function is neither accepted nor refuted.
    unsupported,

    pub fn isError(k: Kind) bool {
        return k != .unsupported;
    }

    pub fn title(k: Kind) []const u8 {
        return switch (k) {
            .double_consume => "consumed twice",
            .use_after_consume => "use after consume",
            .leak => "leak",
            .use_after_free => "use after free",
            .double_free => "double free",
            .escape_local => "pointer to a local escapes",
            .escape_region => "pointer escapes its region",
            .alias => "overlapping ranges",
            .pinned_copy => "pinned value copied",
            .unsupported => "outside the supported fragment",
        };
    }
};

pub const Note = struct { loc: schema.LocId, text: []const u8 };

/// One branch decision on the way to a finding.
pub const Trail = struct {
    prev: ?*const Trail,
    loc: schema.LocId,
    what: enum { then, @"else", case, @"error" },
    /// What the branch says of a scalar in memory, when it is a test of one.
    probes: []const dom.Probe = &.{},
};

pub const Diag = struct {
    kind: Kind,
    loc: schema.LocId,
    text: []const u8,
    notes: []const Note = &.{},
    /// The branches taken to reach `loc`, innermost first.
    trail: ?*const Trail = null,
};
