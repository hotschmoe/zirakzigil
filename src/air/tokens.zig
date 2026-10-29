//! `zv.PointsTo` as a pack shows it: the one table `zvc` and `zv-own` share, so neither spells the names itself.

const std = @import("std");

/// The type of a token, as a pack prints it.
pub const type_name = "zv.PointsTo__struct";

pub const Op = enum { own, split, join, discard };

/// The operation a callee name is, when it is one of `zv.PointsTo`.
pub fn opOf(callee: []const u8) ?Op {
    if (!std.mem.startsWith(u8, callee, type_name ++ ".")) return null;
    return std.meta.stringToEnum(Op, callee[type_name.len + 1 ..]);
}

/// Whether the operation ends the tokens it is given.
pub fn consumes(op: Op) bool {
    return switch (op) {
        .own => false,
        .split, .join, .discard => true,
    };
}

/// Whether `name` is `zv.PointsTo` or something declared inside it (`Pair`).
pub fn inside(name: []const u8) bool {
    return std.mem.startsWith(u8, name, type_name ++ ".");
}
