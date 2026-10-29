//! What a consumer checks with `zig build own`: a permit that must be spent exactly once.
//! The pack next to it is the export of this file (tools/own_repin.sh); `own/SOURCES` pins the source.

const zv = @import("zv");

pub const Permit = zv.Linear(u32);

pub fn issue(slot: u32) Permit {
    return Permit.init(slot);
}

pub fn redeem(p: Permit) u32 {
    return p.consume();
}

pub fn use(slot: u32, ok: bool) u32 {
    const p = issue(slot);
    if (!ok) return redeem(p) + 1;
    return redeem(p);
}
