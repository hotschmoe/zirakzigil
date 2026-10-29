//! Pinned types: a struct that holds a `zv.PinCheck` records its own address, so a by-value copy is a bug.
//! The static form of the runtime check in tests/should_panic/pin_copy.zig.

const zv = @import("zv");

pub const Node = struct {
    pin: zv.PinCheck = .{},
    self_ref: ?*Node = null,
    value: u32 = 0,

    pub fn touch(n: *Node) void {
        n.pin.check();
    }
};

pub const Wrapper = struct { inner: Node = .{}, extra: u8 = 0 };

pub fn okInPlace() u32 {
    var n: Node = .{};
    n.pin.pin();
    n.self_ref = &n;
    n.touch();
    n.value = 3;
    return n.value;
}

pub fn okThroughPointer(n: *Node) u32 {
    const p = n;
    p.touch();
    return p.value;
}

pub fn okFreshValue() Node {
    return .{ .value = 7 };
}

pub fn badCopy() void {
    var original: Node = .{};
    original.pin.pin();
    original.self_ref = &original;
    var moved = original;
    moved.touch();
}

pub fn badPassByValue(n: *Node) u32 {
    return byValue(n.*);
}

fn byValue(n: Node) u32 {
    return n.value;
}

pub fn badCopyInsideWrapper(w: *Wrapper) Node {
    return w.inner;
}

pub fn okCopyField(w: *Wrapper) u8 {
    return w.extra;
}
