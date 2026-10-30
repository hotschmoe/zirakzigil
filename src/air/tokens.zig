//! The permission tokens of `zv` as a pack shows them: the one table `zvc` and `zv-own` share, so neither spells the
//! names itself. `zv.PointsTo` is a range of bytes; `zv.BlockSet` is a set of the blocks of a pool.

const std = @import("std");

/// The type of a byte-range token, as a pack prints it.
pub const type_name = "zv.PointsTo__struct";

/// The type of a block-set token.
pub const set_type_name = "zv.BlockSet__struct";

/// The type of a typed cell token (`zv.Cell(T)`), as a pack prints it: the same for every `T`.
pub const cell_type_name = "zv.Cell__struct";

pub const Op = enum { own, split, join, discard };

pub const SetOp = enum { own, cut, join, discard, apart };

pub const CellOp = enum { own, write, discard };

/// The operation a callee name is, when it is one of `zv.PointsTo`.
pub fn opOf(callee: []const u8) ?Op {
    if (!std.mem.startsWith(u8, callee, type_name ++ ".")) return null;
    return std.meta.stringToEnum(Op, callee[type_name.len + 1 ..]);
}

/// The operation a callee name is, when it is one of `zv.BlockSet`.
pub fn setOpOf(callee: []const u8) ?SetOp {
    if (!std.mem.startsWith(u8, callee, set_type_name ++ ".")) return null;
    return std.meta.stringToEnum(SetOp, callee[set_type_name.len + 1 ..]);
}

/// The operation a callee name is, when it is one of `zv.Cell(T)`.
pub fn cellOpOf(callee: []const u8) ?CellOp {
    if (!std.mem.startsWith(u8, callee, cell_type_name ++ ".")) return null;
    return std.meta.stringToEnum(CellOp, callee[cell_type_name.len + 1 ..]);
}

/// Whether the operation ends the tokens it is given.
pub fn consumes(op: Op) bool {
    return switch (op) {
        .own => false,
        .split, .join, .discard => true,
    };
}

pub fn cellConsumes(op: CellOp) bool {
    return switch (op) {
        .own => false,
        .write, .discard => true,
    };
}

pub fn setConsumes(op: SetOp) bool {
    return switch (op) {
        .own => false,
        .cut, .join, .discard, .apart => true,
    };
}

/// Whether `name` is a token type.
pub fn isTokenType(name: []const u8) bool {
    return std.mem.eql(u8, name, type_name) or std.mem.eql(u8, name, set_type_name) or std.mem.eql(u8, name, cell_type_name);
}

/// Whether `name` is declared inside a token type (`Pair`) or is an operation of one.
pub fn inside(name: []const u8) bool {
    return std.mem.startsWith(u8, name, type_name ++ ".") or std.mem.startsWith(u8, name, set_type_name ++ ".") or std.mem.startsWith(u8, name, cell_type_name ++ ".");
}
