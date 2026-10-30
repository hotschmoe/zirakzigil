//! Cases for `zv.Cell(T)`, the typed permission with a ghost value (docs/phase4.md M4): a box whose ghost cell must say
//! what the real field holds, and what zvc must refuse about a cell token that is forged, written after it was given
//! away, read after it was written over, or kept twice. Verdicts are pinned in `cells.expect`. Ghost builds only.

const zv = @import("zv");

pub const Pair = struct { a: zv.Cell(u32), b: zv.Cell(u32) };

pub const Box = struct {
    val: u32,
    /// Ghost: the permission for `val`, holding what it holds.
    cell: zv.Cell(u32),

    pub const assurance = .{
        .set = .verified,
        .get = .verified,
        .swap = .verified,
        .twoMints = .verified,
        .setNoWrite = .verified,
        .writeTwice = .verified,
        .readStale = .verified,
        .writeAfterGive = .verified,
        .dupCell = .verified,
        .forgeCell = .verified,
        .forgeValue = .verified,
        .stealCell = .verified,
        .giveAway = .verified,
    };

    pub fn giveAway(c: zv.Cell(u32)) void {
        c.discard();
    }

    inline fn sound(b: Box) bool {
        return b.cell.value() == b.val;
    }

    pub fn set(self: *Box, v: u32) void {
        zv.requires(sound(self.*));
        self.val = v;
        self.cell = self.cell.write(v);
        return zv.ensures({}, sound(self.*) and self.val == v);
    }

    pub fn get(self: *const Box) u32 {
        zv.requires(sound(self.*));
        return zv.ensures(self.val, self.cell.value() == self.val);
    }

    pub fn swap(a: *Box, b: *Box) void {
        zv.requires(sound(a.*) and sound(b.*));
        const x = a.val;
        const y = b.val;
        a.val = y;
        b.val = x;
        a.cell = a.cell.write(y);
        b.cell = b.cell.write(x);
        return zv.ensures({}, sound(a.*) and sound(b.*) and a.val == y and b.val == x);
    }

    pub fn twoMints(x: u32, y: u32) u32 {
        const p = zv.Cell(u32).own(1, x);
        const q = zv.Cell(u32).own(2, y);
        return zv.ensures(p.value(), p.value() == x and q.value() == y);
    }

    /// The store is not recorded in the cell: it still says the old value.
    pub fn setNoWrite(self: *Box, v: u32) void {
        zv.requires(sound(self.*));
        self.val = v;
        return zv.ensures({}, sound(self.*));
    }

    /// One token written twice.
    pub fn writeTwice(self: *Box, v: u32) void {
        zv.requires(sound(self.*));
        const c = self.cell;
        self.cell = c.write(v);
        self.cell = c.write(v +% 1);
    }

    /// The value of the cell before the write, read after it.
    pub fn readStale(self: *Box, v: u32) u32 {
        zv.requires(sound(self.*));
        const old = self.cell;
        self.cell = old.write(v);
        return old.value();
    }

    /// Writes through a token that was given away.
    pub fn writeAfterGive(self: *Box) void {
        zv.requires(sound(self.*));
        const c = self.cell;
        Box.giveAway(c);
        self.cell = c.write(1);
    }

    /// Two copies of the one token.
    pub fn dupCell(self: *Box) Pair {
        zv.requires(sound(self.*));
        const p: Pair = .{ .a = self.cell, .b = self.cell };
        return p;
    }

    pub fn forgeCell(slot: usize, v: u32) zv.Cell(u32) {
        const c: zv.Cell(u32) = .{ .where = slot, .held = v };
        return c;
    }

    pub fn forgeValue(c: zv.Cell(u32)) zv.Cell(u32) {
        var d = c;
        d.held = 7;
        return d;
    }

    /// Takes the cell of another box: that box is left without one.
    pub fn stealCell(a: *Box, b: *Box) void {
        zv.requires(sound(a.*) and sound(b.*));
        a.cell = b.cell.write(1);
        a.val = 1;
    }
};
