//! Which `Air.Inst.Data` field and which payload type each tag uses, read from the doc
//! comments of Air.zig at comptime, plus a small override table for tags the comments do not cover.

const std = @import("std");
const Air = @import("../Air.zig");

const Tag = Air.Inst.Tag;
const Data = Air.Inst.Data;
const src = @embedFile("../Air.zig");

pub const Payload = union(enum) {
    none,
    /// Name of a struct in Air.zig read with `extraData`, or wrapped by an `unwrap*` helper.
    extra: []const u8,
    /// `pl_op.payload` is a NullTerminatedString.
    string,
    /// Variable-length operand list whose length comes from the instruction type.
    elements,
};

pub const Shape = struct {
    /// Name of the `Data` field, or empty when nothing could be derived.
    field: []const u8,
    payload: Payload = .none,
    source: enum { doc, inherited, convention, override, none },
};

const OverrideEntry = struct { []const u8, Shape };

const overrides = [_]OverrideEntry{
    .{ "struct_field_ptr_index_0", .{ .field = "ty_op", .source = .override } },
    .{ "trap", .{ .field = "no_op", .source = .override } },
    .{ "breakpoint", .{ .field = "no_op", .source = .override } },
    .{ "dbg_empty_stmt", .{ .field = "no_op", .source = .override } },
    .{ "unreach", .{ .field = "no_op", .source = .override } },
    .{ "err_return_trace", .{ .field = "ty", .source = .override } },
    .{ "set_err_return_trace", .{ .field = "un_op", .source = .override } },
    .{ "dbg_var_ptr", .{ .field = "pl_op", .payload = .string, .source = .override } },
    .{ "dbg_var_val", .{ .field = "pl_op", .payload = .string, .source = .override } },
    .{ "dbg_arg_inline", .{ .field = "pl_op", .payload = .string, .source = .override } },
    .{ "select", .{ .field = "pl_op", .payload = .{ .extra = "Bin" }, .source = .override } },
    .{ "mul_add", .{ .field = "pl_op", .payload = .{ .extra = "Bin" }, .source = .override } },
    .{ "slice_elem_ptr", .{ .field = "ty_pl", .payload = .{ .extra = "Bin" }, .source = .override } },
    .{ "ptr_elem_ptr", .{ .field = "ty_pl", .payload = .{ .extra = "Bin" }, .source = .override } },
    .{ "aggregate_init", .{ .field = "ty_pl", .payload = .elements, .source = .override } },
};

const Entry = struct { name: []const u8, doc: []const u8 };

const entries = collect();

fn collect() []const Entry {
    @setEvalBranchQuota(100_000_000);
    const start = std.mem.indexOf(u8, src, "pub const Tag = enum(") orelse @compileError("Air.Inst.Tag declaration not found");
    var out: []const Entry = &.{};
    var pos = start;
    var doc_start: ?usize = null;
    while (pos < src.len) {
        const eol = std.mem.indexOfScalarPos(u8, src, pos, '\n') orelse src.len;
        const line = std.mem.trim(u8, src[pos..eol], " \t\r");
        if (std.mem.startsWith(u8, line, "pub const Ref")) break;
        if (std.mem.startsWith(u8, line, "///")) {
            if (doc_start == null) doc_start = pos;
        } else if (tagName(line)) |name| {
            out = out ++ [1]Entry{.{ .name = name, .doc = if (doc_start) |d| src[d..pos] else "" }};
            doc_start = null;
        } else if (line.len != 0) doc_start = null;
        pos = eol + 1;
    }
    return out;
}

fn tagName(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[line.len - 1] != ',') return null;
    var name: []const u8 = line[0 .. line.len - 1];
    if (std.mem.startsWith(u8, name, "@\"") and name[name.len - 1] == '"') name = name[2 .. name.len - 1];
    for (name) |ch| switch (ch) {
        'a'...'z', '0'...'9', '_' => {},
        else => return null,
    };
    return name;
}

fn between(text: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    @setEvalBranchQuota(10_000_000);
    const a = std.mem.indexOf(u8, text, open) orelse return null;
    const rest = text[a + open.len ..];
    const b = std.mem.indexOf(u8, rest, close) orelse return null;
    return rest[0..b];
}

fn docOf(comptime name: []const u8) []const u8 {
    for (entries) |e| if (std.mem.eql(u8, e.name, name)) return e.doc;
    return "";
}

fn hasDataField(comptime name: []const u8) bool {
    return @hasField(Data, name);
}

fn hasTag(comptime name: []const u8) bool {
    return @hasField(Tag, name);
}

fn camel(comptime name: []const u8) []const u8 {
    return comptime blk: {
        var out: []const u8 = "";
        var upper = true;
        for (name) |ch| {
            if (ch == '_') {
                upper = true;
                continue;
            }
            out = out ++ [1]u8{if (upper) std.ascii.toUpper(ch) else ch};
            upper = false;
        }
        break :blk out;
    };
}

fn conventionPayload(comptime name: []const u8) ?[]const u8 {
    var base = name;
    for ([_][]const u8{ "_weak", "_strong", "_cold" }) |suffix| {
        if (std.mem.endsWith(u8, base, suffix)) base = base[0 .. base.len - suffix.len];
    }
    const candidate = camel(base);
    return if (@hasDecl(Air, candidate) or @hasDecl(Air, "Unwrapped" ++ candidate)) candidate else null;
}

pub fn derive(comptime name: []const u8) Shape {
    return comptime impl(name, 0);
}

fn impl(comptime name: []const u8, comptime depth: u32) Shape {
    if (depth > 6) @compileError("shape inheritance cycle at " ++ name);
    @setEvalBranchQuota(10_000_000);
    for (overrides) |o| if (std.mem.eql(u8, o[0], name)) return o[1];
    const doc = docOf(name);
    var shape: Shape = .{ .field = "", .source = .none };
    if (between(doc, "Uses the `", "` field")) |f| {
        if (hasDataField(f)) shape = .{ .field = f, .source = .doc };
    }
    if (shape.field.len == 0) {
        for ([_][]const u8{ "Same as `", "Like `" }) |lead| {
            if (between(doc, lead, "`")) |base| if (hasTag(base) and !std.mem.eql(u8, base, name)) {
                const inherited = impl(base, depth + 1);
                return .{ .field = inherited.field, .payload = inherited.payload, .source = .inherited };
            };
        }
    }
    if (shape.field.len == 0 and hasDataField(name)) shape = .{ .field = name, .source = .convention };
    if (shape.field.len == 0) if (std.mem.lastIndexOfScalar(u8, name, '_')) |u| {
        const tail = name[u + 1 ..];
        const numeric = tail.len != 0 and for (tail) |ch| {
            if (!std.ascii.isDigit(ch)) break false;
        } else true;
        if (numeric and !std.mem.eql(u8, tail, "0") and hasTag(name[0..u] ++ "_0")) {
            const inherited = impl(name[0..u] ++ "_0", depth + 1);
            return .{ .field = inherited.field, .payload = inherited.payload, .source = .inherited };
        }
    };
    if (shape.field.len == 0) return shape;
    if (between(doc, "ayload is `", "`")) |p| {
        shape.payload = .{ .extra = p };
    } else if (std.mem.eql(u8, shape.field, "ty_pl") or std.mem.eql(u8, shape.field, "pl_op")) {
        if (conventionPayload(name)) |p| {
            shape.payload = .{ .extra = p };
            if (shape.source == .doc) shape.source = .convention;
        }
    }
    return shape;
}

pub const table = blk: {
    var t: std.EnumArray(Tag, Shape) = .initUndefined();
    for (@typeInfo(Tag).@"enum".field_names) |name| t.set(@field(Tag, name), derive(name));
    break :blk t;
};

pub fn of(tag: Tag) Shape {
    return table.get(tag);
}
