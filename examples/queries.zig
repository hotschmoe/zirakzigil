//! zmoltcp's DNS client pattern on `zv.Slots`: a library socket that *borrows*
//! its query table from the caller, hands out generational handles, and
//! reports a stale handle as an error. This is the shape of
//! `zmoltcp/src/socket/dns.zig` with its hand-rolled `QueryHandle`,
//! `QuerySlot.generation`, `findFreeSlot` and `liveSlot` deleted:
//!
//!   dns.zig                                         here
//!   -----------------------------------------       -----------------------------
//!   QueryHandle{index, generation}                  QueryHandle = Table.Handle
//!   QuerySlot{state: ?QueryState, generation}       QuerySlot = Table.Slot
//!   findFreeSlot() + write state and generation     queries.insert(state)
//!   liveSlot(h) orelse return error.StaleHandle     try queries.get(h)
//!   slot.state = null                               queries.free(h) / queries.take(h)
//!   for (self.queries) |*slot| { slot.state orelse continue ... }
//!                                                   var it = queries.iterator(); while (it.next()) |e| ...
//!
//! Laws are the specification; the scenario test is the one end-to-end test.

const std = @import("std");
const zv = @import("zv");

pub const max_name = 32;

const Pending = struct { name: [max_name]u8 = undefined, name_len: u8, txid: u16 };
const State = union(enum) { pending: Pending, completed: u32, failure };

/// The brand is a unique type: handles of other tables do not fit this one.
const Table = zv.Slots(State, struct {});
pub const QuerySlot = Table.Slot;
pub const QueryHandle = Table.Handle;

pub const StartQueryError = error{ NoFreeSlot, NameTooLong };
pub const GetQueryResultError = error{ Pending, Failed, StaleHandle };

pub const assurance = .{
    .Socket = .{ .init = .tested, .startQuery = .tested, .getQueryResult = .tested, .cancelQuery = .tested, .process = .tested },
    .laws = .{ .queriesMatchModel = .tested },
};

comptime {
    zv.requireAssurance(@This(), .tested);
}

pub const Socket = struct {
    queries: Table,
    next_txid: u16 = 1,

    /// `slots` is borrowed: the caller owns the storage, as with zmoltcp sockets.
    pub fn init(slots: []QuerySlot) Socket {
        return .{ .queries = .init(slots) };
    }

    pub fn startQuery(self: *Socket, name: []const u8) StartQueryError!QueryHandle {
        if (name.len > max_name) return error.NameTooLong;
        var pending: Pending = .{ .name_len = @intCast(name.len), .txid = self.next_txid };
        @memcpy(pending.name[0..name.len], name);
        const handle = try self.queries.insert(.{ .pending = pending }); // error.NoFreeSlot
        self.next_txid +%= 1;
        return handle;
    }

    /// Reading a finished result frees its slot, so the handle is stale afterwards.
    pub fn getQueryResult(self: *Socket, handle: QueryHandle) GetQueryResultError!u32 {
        const state = try self.queries.get(handle); // error.StaleHandle
        if (state.* == .pending) return error.Pending;
        const done = self.queries.take(handle) catch unreachable; // `get` just proved it live
        return switch (done) {
            .completed => |addr| addr,
            .failure => error.Failed,
            .pending => unreachable,
        };
    }

    /// Cancelling twice, or after the result was read, is harmless.
    pub fn cancelQuery(self: *Socket, handle: QueryHandle) void {
        self.queries.free(handle) catch {};
    }

    /// An answer (or `null` for a failure response) for the query with `txid`.
    pub fn process(self: *Socket, txid: u16, answer: ?u32) void {
        var it = self.queries.iterator();
        while (it.next()) |entry| switch (entry.value.*) {
            .pending => |pending| if (pending.txid == txid) {
                entry.value.* = if (answer) |addr| .{ .completed = addr } else .failure;
                return;
            },
            else => {},
        };
    }
};

pub const laws = struct {
    const Op = struct {
        kind: enum { start, answer, fail, get, cancel },
        which: zv.Ranged(0, 7),
        name_len: zv.Ranged(0, max_name + 8),
        addr: u32,
    };
    const Status = enum { pending, done, failed, gone };
    const capacity = 3;
    const long_name = "name-of-a-host-that-is-long-enough-to-overflow";

    /// Any script of operations behaves like a plain table of statuses: stale
    /// handles are always `StaleHandle`, results are read exactly once, and the
    /// table is full exactly when every slot is occupied.
    pub fn queriesMatchModel(ops: [20]Op) bool {
        var storage: [capacity]QuerySlot = @splat(.empty);
        var socket: Socket = .init(&storage);

        var handles: [20]QueryHandle = undefined;
        var txids: [20]u16 = undefined;
        var status: [20]Status = @splat(.gone);
        var addrs: [20]u32 = undefined;
        var n: usize = 0;
        var occupied: usize = 0;
        var next_txid: u16 = 1;

        for (ops) |op| {
            const k = if (n == 0) 0 else op.which.get() % n;
            switch (op.kind) {
                .start => if (socket.startQuery(long_name[0..op.name_len.get()])) |h| {
                    if (occupied == capacity or op.name_len.get() > max_name) return false;
                    handles[n] = h;
                    txids[n] = next_txid;
                    status[n] = .pending;
                    n += 1;
                    occupied += 1;
                    next_txid +%= 1;
                } else |err| switch (err) {
                    error.NameTooLong => if (op.name_len.get() <= max_name) return false,
                    error.NoFreeSlot => if (occupied != capacity or op.name_len.get() > max_name) return false,
                },
                .answer, .fail => if (n > 0) {
                    socket.process(txids[k], if (op.kind == .answer) op.addr else null);
                    if (status[k] == .pending) {
                        status[k] = if (op.kind == .answer) .done else .failed;
                        addrs[k] = op.addr;
                    }
                },
                .get => if (n > 0) {
                    if (socket.getQueryResult(handles[k])) |addr| {
                        if (status[k] != .done or addr != addrs[k]) return false;
                    } else |err| switch (err) {
                        error.Pending => if (status[k] != .pending) return false,
                        error.Failed => if (status[k] != .failed) return false,
                        error.StaleHandle => if (status[k] != .gone) return false,
                    }
                    if (status[k] == .done or status[k] == .failed) {
                        status[k] = .gone;
                        occupied -= 1;
                    }
                },
                .cancel => if (n > 0) {
                    socket.cancelQuery(handles[k]);
                    if (status[k] != .gone) occupied -= 1;
                    status[k] = .gone;
                },
            }
            if (socket.queries.count() != occupied) return false;
        }
        return true;
    }
};

test "laws: the socket matches the reference model" {
    try zv.checkLaws(laws, .{ .iterations = 5_000, .seed = 0xD25 });
}

test "scenario: results are read once, and handles die with their query" {
    var storage: [2]QuerySlot = @splat(.empty);
    var socket: Socket = .init(&storage);

    const a = try socket.startQuery("a.example");
    const b = try socket.startQuery("b.example");
    try std.testing.expectError(error.NoFreeSlot, socket.startQuery("c.example"));
    try std.testing.expectError(error.Pending, socket.getQueryResult(a));

    socket.process(1, 0x0a000001); // answers `a` (txid 1)
    try std.testing.expectEqual(0x0a000001, try socket.getQueryResult(a));
    try std.testing.expectError(error.StaleHandle, socket.getQueryResult(a)); // already read

    const c = try socket.startQuery("c.example"); // reuses a's slot
    try std.testing.expectEqual(a.index, c.index);
    try std.testing.expectError(error.StaleHandle, socket.getQueryResult(a)); // not c's result

    socket.cancelQuery(b);
    socket.cancelQuery(b); // harmless
    socket.process(3, null); // failure response for `c` (txid 3)
    try std.testing.expectError(error.Failed, socket.getQueryResult(c));
    try std.testing.expectEqual(0, socket.queries.count());
}
