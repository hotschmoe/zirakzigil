//! The choke point's vocabulary. Every end (a free, a deinit, an invalidation, a callee's kill) and every use of memory the
//! run follows has an `Outcome`: it was reported, it was decided clean (and why), or it is counted (and why). The
//! deciders return `Outcome` and `Run.settle` is the one place that writes it down, so a rule that drops an event has no
//! way to say nothing: the type has no empty case and an unused result does not compile. See docs/phase3.md.

const std = @import("std");

/// What an event is. `end`: memory stops being valid (or may have). `use`: a read, write or pass of memory the run follows.
/// `note`: neither, an assumption the run makes at an instruction (it counts in the footer, not toward the ends and uses).
pub const Site = enum(u8) { end, use, note };

/// Why an event is not decided. The first three are assumptions about code outside the packs; the others are events the
/// checker saw and could not settle.
pub const Reason = enum(u8) {
    /// A call to a function outside the packs, or too odd to read, that takes or returns pointers: assumed to end nothing.
    unknown_call,
    /// A linear value handed to memory the run does not follow.
    transfer,
    /// A container method nobody wrote down and whose body is not in the packs: taken to invalidate.
    unmodelled,
    /// An operation on memory the run cannot name a place for: its effect is not applied.
    blind,
    /// A `resize` by a length the run cannot show to be non-zero: assumed not to free.
    dynamic_len,
    /// A pointer to a local handed to a call whose result may keep it: not followed.
    lent,
    /// A use or a free of something that is ended on some of the things a pointer may lead to, not on all.
    maybe_alias,
    /// A pointer into storage that an operation reallocates only if there is no room, and the room is not known.
    maybe_stale,
    /// An end of an identity that stands for several allocations, or that depends on room, or on a condition nobody can read.
    summarized,
    /// A function that ends or changes memory through two pointer parameters of one type, assumed not to overlap (a call
    /// that passes one object twice is checked at the call).
    alias_params,
    /// An end of, or a growth of, memory that is a global: what it holds is not all in the run.
    global,
    /// An end of a value the run has no provenance for: nothing it knows says what was freed.
    untracked,
    /// An end the function made of a caller-visible identity that its summary cannot say.
    unexpressed,
    /// An event whose rule decided nothing: the call-level backstop found an end with no outcome.
    dropped,

    pub const all = std.enums.values(Reason);

    /// Assumptions about code the packs do not hold. Everything else is an event the checker met and left open.
    pub fn assumed(reason: Reason) bool {
        return switch (reason) {
            .unknown_call, .transfer, .unmodelled, .alias_params => true,
            else => false,
        };
    }

    /// Whether the reason keeps a function from being `clean`. Two pointer parameters that do not overlap is a precondition
    /// that a call is checked against, not something the function's own code left open.
    pub fn opens(reason: Reason) bool {
        return reason != .alias_params;
    }

    /// The reasons a callee's run hands to its callers: the effect may be on memory the caller sees and the summary cannot say where.
    pub fn escapes(reason: Reason) bool {
        return switch (reason) {
            .blind, .global, .untracked, .unexpressed, .dropped => true,
            else => false,
        };
    }

    /// The phrase after the count in the footer.
    pub fn phrase(reason: Reason) []const u8 {
        return switch (reason) {
            .unknown_call => "calls to functions outside the packs or too odd to read",
            .transfer => "linear values handed to memory it does not follow",
            .unmodelled => "container methods with no model (taken to invalidate)",
            .blind => "operations on memory it cannot name",
            .dynamic_len => "resizes by a length it cannot show to be non-zero",
            .lent => "pointers to locals handed to calls that return a new block or that the summary does not trace (what the result keeps of them is not followed)",
            .maybe_alias => "uses of a pointer that may lead into freed memory",
            .maybe_stale => "pointers stale only if a container had no room",
            .summarized => "ends that may not have happened to the block (a site that stands for several allocations, one of many, a value that may be one of several, a growth that depends on room)",
            .alias_params => "functions that end or change memory through two or more pointer parameters, assumed not to overlap",
            .global => "ends or growths of global memory (what a global holds is not followed)",
            .untracked => "ends of a value with no provenance (it came from memory or a call the run does not follow)",
            .unexpressed => "ends of memory the caller sees that the summary of the function cannot say",
            .dropped => "ends whose rule decided nothing",
        };
    }
};

/// Why an event was decided without a finding. Each is a rule that proved there is nothing to do here; they are listed
/// so that a drop is a named decision and not a missing line.
pub const Clean = enum(u8) {
    /// The memory it names was ended, or checked live, and any problem was reported.
    applied,
    /// The memory it names is followed and holds nothing that can end.
    empty,
    /// A condition the callee's effect needs is known to be false at this call.
    gated,
    /// The call is known not to reallocate (room was made).
    no_realloc,
    /// What it names is a stack slot or an object that is already gone: nothing is left to end.
    not_heap,
    /// The end is applied later, when the payload turns out to exist.
    deferred,
    /// A recursive call under the summary assumed for it: the settled round decides.
    assumed_round,
    /// The callee only asks whether a handle is still good.
    query,
};

pub const Outcome = union(enum) {
    reported,
    clean: Clean,
    counted: Reason,

    pub const applied: Outcome = .{ .clean = .applied };

    pub fn isCounted(o: Outcome) bool {
        return o == .counted;
    }
};

/// Reasons as a set: what a function's summary hands to its callers.
pub const Reasons = std.EnumSet(Reason);

pub const Stats = struct {
    insts: u32 = 0,
    /// Instructions with an end (a free, a deinit, an invalidation, a callee's kill) and with a use of memory the run follows.
    ends: u32 = 0,
    uses: u32 = 0,
    /// Of those, the instructions with an outcome that is counted.
    open_ends: u32 = 0,
    open_uses: u32 = 0,
    counts: std.EnumArray(Reason, u32) = .initFill(0),
    /// The events a rule decided without a finding, by the reason it names (`applied` is not among them).
    cleans: std.EnumArray(Clean, u32) = .initFill(0),

    pub fn count(s: Stats, reason: Reason) u32 {
        return s.counts.get(reason);
    }

    /// Events the checker met and left open (the assumptions about outside code are not among them).
    pub fn undecided(s: Stats) u32 {
        var n: u32 = 0;
        for (Reason.all) |reason| {
            if (!reason.assumed()) n += s.count(reason);
        }
        return n;
    }

    /// Everything a `clean` may not have: the undecided events and the assumptions made at an instruction.
    pub fn open(s: Stats) u32 {
        var n: u32 = 0;
        for (Reason.all) |reason| {
            if (reason.opens()) n += s.count(reason);
        }
        return n;
    }

    pub fn add(s: *Stats, other: Stats) void {
        s.insts += other.insts;
        s.ends += other.ends;
        s.uses += other.uses;
        s.open_ends += other.open_ends;
        s.open_uses += other.open_uses;
        for (Reason.all) |reason| s.counts.set(reason, s.count(reason) + other.count(reason));
        for (std.enums.values(Clean)) |why| s.cleans.set(why, s.cleans.get(why) + other.cleans.get(why));
    }
};
