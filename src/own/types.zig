//! What the checker needs to know about types, read from a pack: which values are linear, which hold
//! pointers, and which are allocators. Answers are memoized per type id.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zv_air = @import("zv_air");
const schema = zv_air.schema;

pub const Types = struct {
    pack: *const schema.Pack,
    tokens: []Memo,
    pointers: []Memo,

    const Memo = enum(u8) { unknown, busy, no, yes };

    pub fn init(arena: Allocator, pack: *const schema.Pack) Allocator.Error!Types {
        const n = pack.t.types.len;
        const tokens = try arena.alloc(Memo, n);
        const pointers = try arena.alloc(Memo, n);
        @memset(tokens, .unknown);
        @memset(pointers, .unknown);
        return .{ .pack = pack, .tokens = tokens, .pointers = pointers };
    }

    pub fn rec(t: Types, id: schema.TypeId) schema.TypeRec {
        return t.pack.t.types[@backingInt(id)];
    }

    pub fn name(t: Types, id: schema.TypeId) []const u8 {
        return if (id == .none) "?" else t.pack.typeName(id);
    }

    pub fn kind(t: Types, id: schema.TypeId) schema.TypeKind {
        return if (id == .none) .void else t.rec(id).kind;
    }

    /// `zv.Linear(T)`: a value that must be consumed exactly once.
    pub fn isLinear(t: Types, id: schema.TypeId) bool {
        if (id == .none) return false;
        const r = t.rec(id);
        return r.kind == .@"struct" and std.mem.startsWith(u8, t.pack.str(r.name), "zv.Linear(");
    }

    /// A struct that holds a `zv.PinCheck` by value: its address is part of what it is, so it must not be copied.
    pub fn isPinned(t: Types, id: schema.TypeId) bool {
        return t.pinnedBelow(id, 0);
    }

    fn pinnedBelow(t: Types, id: schema.TypeId, depth: u32) bool {
        if (id == .none or depth > 8) return false;
        const r = t.rec(id);
        switch (r.kind) {
            .@"struct" => {
                if (std.mem.eql(u8, t.pack.str(r.name), "zv.PinCheck")) return true;
                const fields = t.pack.fieldsOf(id) orelse return false;
                for (fields) |f| if (t.pinnedBelow(f.ty, depth + 1)) return true;
                return false;
            },
            .optional, .error_union, .array => return t.pinnedBelow(r.child, depth + 1),
            else => return false,
        }
    }

    pub fn isPointer(t: Types, id: schema.TypeId) bool {
        return t.kind(id) == .pointer;
    }

    /// A slice or a many-item pointer, possibly behind an optional: a field whose value is storage an object owns.
    pub fn isStorage(t: Types, id: schema.TypeId) bool {
        const at = t.payload(id);
        if (at == .none) return false;
        const r = t.rec(at);
        return r.kind == .pointer and r.flags.size != .one;
    }

    /// A read-only pointer to one object (not to a buffer), possibly optional: it borrows, and nothing it points to is
    /// the owner's to move.
    pub fn isSingle(t: Types, id: schema.TypeId) bool {
        const at = t.payload(id);
        if (at == .none) return false;
        const r = t.rec(at);
        return r.kind == .pointer and r.flags.size == .one and r.flags.is_const;
    }

    /// The fields of a struct or the variants of a union (or those of the one inside an optional or error union), when the
    /// pack knows them.
    pub fn structFields(t: Types, id: schema.TypeId) ?[]const schema.FieldRec {
        const at = t.payload(id);
        if (at == .none or (t.rec(at).kind != .@"struct" and t.rec(at).kind != .@"union") or t.isLinear(at) or t.isAllocator(at)) return null;
        const fields = t.pack.fieldsOf(at) orelse return null;
        return if (fields.len == 0) null else fields;
    }

    pub fn isAllocator(t: Types, id: schema.TypeId) bool {
        return id != .none and std.mem.eql(u8, t.pack.typeName(id), "mem.Allocator");
    }

    /// The type a pointer points to.
    pub fn pointee(t: Types, id: schema.TypeId) ?schema.TypeId {
        if (id == .none) return null;
        const r = t.rec(id);
        if (r.kind != .pointer or r.child == .none) return null;
        return r.child;
    }

    /// The value inside an optional or an error union; the type itself otherwise.
    pub fn payload(t: Types, id: schema.TypeId) schema.TypeId {
        var at = id;
        while (at != .none) {
            const r = t.rec(at);
            switch (r.kind) {
                .optional, .error_union => at = r.child,
                else => break,
            }
        }
        return at;
    }

    /// Whether a value of this type holds a linear token somewhere by value. A struct whose fields the pack
    /// does not know is taken to hold none; `fieldsKnown` says when that is a guess.
    pub fn hasTokens(t: Types, id: schema.TypeId) bool {
        if (id == .none) return false;
        const slot = &t.tokens[@backingInt(id)];
        switch (slot.*) {
            .yes => return true,
            .no, .busy => return false,
            .unknown => {},
        }
        slot.* = .busy;
        const r = t.rec(id);
        const answer = switch (r.kind) {
            .@"struct" => t.isLinear(id) or t.anyField(id, hasTokens),
            .@"union" => t.anyField(id, hasTokens),
            .optional, .error_union, .array, .vector => t.hasTokens(r.child),
            else => false,
        };
        slot.* = if (answer) .yes else .no;
        return answer;
    }

    /// Whether a value of this type holds a pointer or slice somewhere by value (so it can dangle).
    pub fn hasPointers(t: Types, id: schema.TypeId) bool {
        if (id == .none) return false;
        const slot = &t.pointers[@backingInt(id)];
        switch (slot.*) {
            .yes => return true,
            .no, .busy => return false,
            .unknown => {},
        }
        slot.* = .busy;
        const r = t.rec(id);
        const answer = switch (r.kind) {
            .pointer, .@"fn", .@"anyframe" => true,
            .@"struct", .@"union" => if (t.pack.fieldsOf(id) == null) !t.isEmptyAggregate(id) else t.anyField(id, hasPointers),
            .optional, .error_union, .array, .vector => t.hasPointers(r.child),
            else => false,
        };
        slot.* = if (answer) .yes else .no;
        return answer;
    }

    /// A struct or union whose fields the pack lacks reads as holding pointers (the safe guess for dangling)
    /// unless it is a type the pack knows to be empty: there is no way to tell, so only `zv.Linear` is special.
    fn isEmptyAggregate(t: Types, id: schema.TypeId) bool {
        _ = t;
        _ = id;
        return false;
    }

    pub fn fieldsKnown(t: Types, id: schema.TypeId) bool {
        return t.pack.fieldsOf(id) != null;
    }

    fn anyField(t: Types, id: schema.TypeId, comptime pred: fn (Types, schema.TypeId) bool) bool {
        const fields = t.pack.fieldsOf(id) orelse return false;
        for (fields) |f| if (f.ty != .none and pred(t, f.ty)) return true;
        return false;
    }

    /// The name of a field, or its index when the pack gives none.
    pub fn fieldName(t: Types, buf: []u8, id: schema.TypeId, index: u32) []const u8 {
        if (t.pack.fieldsOf(id)) |fields| if (index < fields.len) {
            const n = t.pack.str(fields[index].name);
            if (n.len != 0) return n;
        };
        return std.fmt.bufPrint(buf, "{d}", .{index}) catch "?";
    }
};
