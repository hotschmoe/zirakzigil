//! The mistakes zv-own found in real projects (docs/reviews/own-2.md), reduced to the std types they use, and the one
//! it missed. `bad*` are real bugs and must be reported; `ok*` are the corrected shapes next to them.

const std = @import("std");
const Allocator = std.mem.Allocator;

// libvaxis src/vxfw/ListView.zig:482: the list is deinitialized and appended to.
pub fn badDeinitThenAppend(arena: Allocator, viewport: u16, cursor: u16) !usize {
    var child_list: std.ArrayList(u32) = .empty;
    try child_list.append(arena, 1);
    if (cursor == viewport) {
        child_list.deinit(arena);
        try child_list.append(arena, 2);
    }
    return child_list.items.len;
}

pub fn okDeinitThenInit(arena: Allocator, viewport: u16, cursor: u16) !usize {
    var child_list: std.ArrayList(u32) = .empty;
    try child_list.append(arena, 1);
    if (cursor == viewport) {
        child_list.deinit(arena);
        child_list = .empty;
        try child_list.append(arena, 2);
    }
    const n = child_list.items.len;
    child_list.deinit(arena);
    return n;
}

// libvaxis src/vxfw/Button.zig:114: a widget whose userdata points at a local is returned in a surface.
const Widget = struct { userdata: *const anyopaque, draw: ?*const fn (*const anyopaque) void = null };
const Text = struct {
    text: []const u8,
    fn widget(self: *const Text) Widget {
        return .{ .userdata = self };
    }
};
const Surface = struct { child: Widget, rows: u16 };

pub fn badWidgetOfLocal(label: []const u8) Surface {
    const text: Text = .{ .text = label };
    return .{ .child = text.widget(), .rows = 1 };
}

pub fn okWidgetOfParam(text: *const Text) Surface {
    return .{ .child = text.widget(), .rows = 1 };
}

// libvaxis Button.draw as written: the local widget goes through a child that copies it into a slice from the arena
// (reached by a function pointer there). The checker does not follow the elements, and counts the pointer it lent.
const Center = struct {
    child: Widget,

    fn draw(self: *const Center, arena: Allocator) ![]Widget {
        const children = try arena.alloc(Widget, 1);
        children[0] = self.child;
        return children;
    }
};

pub fn lostWidgetChild(arena: Allocator, label: []const u8) ![]Widget {
    const text: Text = .{ .text = label };
    const center: Center = .{ .child = text.widget() };
    return center.draw(arena);
}

// zigimg OctTreeQuantizer.init: the address of the local is registered, and the local is returned by value.
const Node = struct { level: u8 };
const Quantizer = struct {
    root: Node,
    levels: [2]?*Node,
    fn addLevelNode(self: *Quantizer, level: usize, node: *Node) void {
        self.levels[level] = node;
    }
};

pub fn badRegisterThenReturn() Quantizer {
    var result: Quantizer = .{ .root = .{ .level = 0 }, .levels = .{ null, null } };
    result.addLevelNode(0, &result.root);
    return result;
}

// zls src/TrigramStore.zig:154: `lists` is taken before the loop and used after swapRemoveAt moved the entries.
const Trigrams = std.array_hash_map.Auto(u32, std.ArrayList(u32));

pub fn badValuesAcrossSwapRemove(gpa: Allocator, map: *Trigrams) void {
    const lists = map.values();
    var index: usize = 0;
    while (index < lists.len) {
        if (lists[index].items.len == 0) {
            lists[index].deinit(gpa);
            map.swapRemoveAt(index);
        } else {
            index += 1;
        }
    }
}

pub fn okValuesReloaded(gpa: Allocator, map: *Trigrams) void {
    var index: usize = 0;
    while (index < map.count()) {
        if (map.values()[index].items.len == 0) {
            map.values()[index].deinit(gpa);
            map.swapRemoveAt(index);
        } else {
            index += 1;
        }
    }
}

// lsp-kit Message.parseFromSliceLeaky: a std.json.Scanner is copied by value and shares its heap stack with the original.
const Scanner = struct {
    stack: std.ArrayList(u8) = .empty,

    fn skipValue(self: *Scanner, gpa: Allocator) !void {
        try self.stack.ensureTotalCapacity(gpa, 4096);
        self.stack.appendAssumeCapacity(1);
    }
};

pub fn badScannerCopy(gpa: Allocator) !u8 {
    var source: Scanner = .{};
    defer source.stack.deinit(gpa);
    try source.stack.append(gpa, 0);
    const saved = source;
    try source.skipValue(gpa);
    return saved.stack.items[0];
}

pub fn okScannerCopyAfter(gpa: Allocator) !u8 {
    var source: Scanner = .{};
    defer source.stack.deinit(gpa);
    try source.stack.append(gpa, 0);
    try source.skipValue(gpa);
    const saved = source;
    return saved.stack.items[0];
}

// zls src/Server.zig loop + processMessageReportError: the callee deinitializes the arena it was given by value, and
// the caller's errdefer deinitializes it again when the callee fails.
fn processMessage(gpa: Allocator, arena_state: std.heap.ArenaAllocator.State, canceled: bool) error{Canceled}!void {
    var arena_allocator = arena_state.promote(gpa);
    defer arena_allocator.deinit();
    _ = arena_allocator.allocator().alloc(u8, 64) catch {};
    if (canceled) return error.Canceled;
}

pub fn badLoopIteration(gpa: Allocator, canceled: bool) error{Canceled}!void {
    var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_allocator.deinit();
    _ = arena_allocator.allocator().alloc(u8, 100) catch {};
    try processMessage(gpa, arena_allocator.state, canceled);
}

// lsp-kit Message.parseFromSliceLeaky, as written: the name token is a slice into the input or a copy of it (freeing the
// copy frees nothing of the scanner), and the params scanner is saved by value and then advanced. The advance grows the
// shared stack only when the nesting is deep, which the checker counts and does not report.
const Parsed = union(enum) { unknown, params: std.json.Scanner, method: []const u8 };

pub fn savedScannerAdvances(gpa: Allocator, text: []const u8) !u8 {
    var source = std.json.Scanner.initCompleteInput(gpa, text);
    defer source.deinit();
    if (try source.next() != .object_begin) return error.UnexpectedToken;
    var state: Parsed = .unknown;
    while (true) {
        const name_token = try source.nextAllocMax(gpa, .alloc_if_needed, text.len);
        const is_params = switch (name_token) {
            .string, .allocated_string => |slice| std.mem.eql(u8, slice, "params"),
            .object_end => break,
            else => return error.UnexpectedToken,
        };
        switch (name_token) {
            .string => {},
            .allocated_string => |slice| gpa.free(slice),
            else => unreachable,
        }
        if (is_params) {
            state = .{ .params = source };
            try source.skipValue();
            continue;
        }
        try source.skipValue();
    }
    if (state == .params) {
        var saved = state.params;
        return @intFromBool(try saved.next() == .null);
    }
    return 0;
}

pub fn okNameTokens(gpa: Allocator, text: []const u8) !u8 {
    var source = std.json.Scanner.initCompleteInput(gpa, text);
    defer source.deinit();
    if (try source.next() != .object_begin) return error.UnexpectedToken;
    var params: u8 = 0;
    while (true) {
        const name_token = try source.nextAllocMax(gpa, .alloc_if_needed, text.len);
        const is_params = switch (name_token) {
            .string, .allocated_string => |slice| std.mem.eql(u8, slice, "params"),
            .object_end => break,
            else => return error.UnexpectedToken,
        };
        switch (name_token) {
            .string => {},
            .allocated_string => |slice| gpa.free(slice),
            else => unreachable,
        }
        params += @intFromBool(is_params);
        try source.skipValue();
    }
    return params;
}

// zls src/TrigramStore.zig init: the store grows in a loop through a method, then the lists are taken and entries are
// swap-removed while the slice taken before is used.
const Store = struct {
    map: Trigrams = .empty,
    declarations: std.ArrayList(u32) = .empty,

    fn append(store: *Store, gpa: Allocator, key: u32) !void {
        const gop = try store.map.getOrPut(gpa, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, key);
        try store.declarations.append(gpa, key);
    }

    fn deinit(store: *Store, gpa: Allocator) void {
        for (store.map.values()) |*list| list.deinit(gpa);
        store.map.deinit(gpa);
        store.declarations.deinit(gpa);
    }
};

pub fn badStoreInit(gpa: Allocator, n: u32) !Store {
    var store: Store = .{};
    errdefer store.deinit(gpa);
    var i: u32 = 0;
    while (i < n) : (i += 1) try store.append(gpa, i);
    const lists = store.map.values();
    var index: usize = 0;
    while (index < lists.len) {
        if (lists[index].items.len == 0) {
            lists[index].deinit(gpa);
            store.map.swapRemoveAt(index);
        } else {
            index += 1;
        }
    }
    return store;
}
