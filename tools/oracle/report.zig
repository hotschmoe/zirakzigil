//! Classification and the report (markdown and JSON). Nothing here depends on the clock or on iteration order of a
//! hash map, so the same seed and count give the same bytes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const gen = @import("gen.zig");

pub const Mode = enum { plain, std };
pub const Truth = enum { clean, fault, invalid };
pub const Verdict = enum { clean, counted, findings, unproven, trusted, missing };
pub const Class = enum { true_finding, silent_miss, counted_miss, assumed_miss, false_positive, true_clean, unproven_fault, unproven_clean, invalid };

/// What zv-own printed as assumed or undecided for one function (docs/phase3.md, "What is not followed").
pub const Counted = struct {
    unknown_calls: usize = 0,
    transfers: usize = 0,
    unmodelled: usize = 0,
    blind: usize = 0,
    dynamic_len: usize = 0,
    lent: usize = 0,
    maybe_alias: usize = 0,
    maybe_stale: usize = 0,
    summarized: usize = 0,
    alias_params: usize = 0,
    open_ends: usize = 0,
    open_uses: usize = 0,

    /// Only calls the checker does not read or values handed to memory it does not follow: zv-own prints them and still says `clean`.
    pub fn assumedOnly(c: Counted) bool {
        var rest = c;
        rest.unknown_calls = 0;
        rest.transfers = 0;
        return !c.isEmpty() and rest.isEmpty();
    }

    pub fn isEmpty(c: Counted) bool {
        inline for (@typeInfo(Counted).@"struct".field_names) |name| {
            if (@field(c, name) != 0) return false;
        }
        return true;
    }
};

pub const Own = struct {
    verdict: Verdict = .missing,
    counted: Counted = .{},
};

pub const Result = struct {
    program: gen.Program,
    tags: gen.TagSet,
    truth: Truth,
    detail: []const u8,
    own: [2]Own = .{ .{}, .{} },

    pub fn class(r: Result, mode: Mode) Class {
        if (r.truth == .invalid) return .invalid;
        const o = r.own[@backingInt(mode)];
        return switch (r.truth) {
            .fault => switch (o.verdict) {
                .findings => .true_finding,
                .counted => .counted_miss,
                .clean => if (o.counted.isEmpty()) .silent_miss else if (o.counted.assumedOnly()) .assumed_miss else .counted_miss,
                else => .unproven_fault,
            },
            else => switch (o.verdict) {
                .findings => .false_positive,
                .clean, .counted => .true_clean,
                else => .unproven_clean,
            },
        };
    }
};

pub const Config = struct {
    seed: u64,
    count: u32,
    modes: [2]bool,
    own: []const u8,
};

pub const Minimized = struct {
    id: u32,
    mode: Mode,
    signature: []const u8,
    programs: u32,
    source: []const u8,
    tags: gen.TagSet,
    also_other_mode: bool,
    fault: []const u8,
    merged: u32 = 0,
};

/// The motifs and the steps that are a mistake when they line up: what a program is about.
pub fn signature(arena: Allocator, tags: gen.TagSet) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var it = tags.iterator();
    while (it.next()) |t| {
        const name = @tagName(t);
        if (!std.mem.startsWith(u8, name, "m_") and !std.mem.startsWith(u8, name, "bug_")) continue;
        if (buf.items.len != 0) try buf.append(arena, '+');
        try buf.appendSlice(arena, name);
    }
    return buf.items;
}

const Tally = struct {
    n: [std.enums.values(Class).len]u32 = @splat(0),

    fn add(t: *Tally, c: Class) void {
        t.n[@backingInt(c)] += 1;
    }

    fn get(t: Tally, c: Class) u32 {
        return t.n[@backingInt(c)];
    }

    fn faulting(t: Tally) u32 {
        return t.get(.true_finding) + t.get(.silent_miss) + t.get(.counted_miss) + t.get(.assumed_miss) + t.get(.unproven_fault);
    }

    fn quiet(t: Tally) u32 {
        return t.get(.false_positive) + t.get(.true_clean) + t.get(.unproven_clean);
    }
};

const Row = struct {
    programs: u32 = 0,
    modes: [2]Tally = .{ .{}, .{} },
};

fn pct(w: *Io.Writer, num: u32, den: u32) Io.Writer.Error!void {
    if (den == 0) return w.writeAll("-");
    const tenths = (@as(u64, num) * 1000 + den / 2) / den;
    try w.print("{d}.{d}%", .{ tenths / 10, tenths % 10 });
}

fn rowOf(results: []const *Result, comptime pred: anytype, ctx: anytype) Row {
    var row: Row = .{};
    for (results) |r| {
        if (r.truth == .invalid or !pred(r, ctx)) continue;
        row.programs += 1;
        for (0..2) |m| row.modes[m].add(r.class(@fromBackingInt(@intCast(m))));
    }
    return row;
}

fn hasTag(r: *const Result, tag: gen.Tag) bool {
    return r.tags.contains(tag);
}

fn pureMotif(r: *const Result, tag: gen.Tag) bool {
    return r.program.groups() == 1 and r.tags.contains(tag);
}

fn all(_: *const Result, _: void) bool {
    return true;
}

fn tableHeader(w: *Io.Writer, cfg: Config, first: []const u8) !void {
    try w.print("| {s} | programs | faulting |", .{first});
    for (0..2) |m| {
        if (cfg.modes[m]) try w.print(" {t}: silent | counted | false pos | true |", .{@as(Mode, @fromBackingInt(@intCast(m)))});
    }
    try w.writeAll("\n|---|---:|---:|");
    for (0..2) |m| {
        if (cfg.modes[m]) try w.writeAll("---:|---:|---:|---:|");
    }
    try w.writeByte('\n');
}

fn tableRow(w: *Io.Writer, cfg: Config, label: []const u8, row: Row) !void {
    const f = row.modes[0].faulting();
    const q = row.modes[0].quiet();
    try w.print("| {s} | {d} | {d} |", .{ label, row.programs, f });
    for (0..2) |m| {
        if (!cfg.modes[m]) continue;
        const t = row.modes[m];
        try w.print(" {d} (", .{t.get(.silent_miss)});
        try pct(w, t.get(.silent_miss), f);
        try w.print(") | {d} ({d} assumed) | {d} (", .{ t.get(.counted_miss) + t.get(.assumed_miss), t.get(.assumed_miss), t.get(.false_positive) });
        try pct(w, t.get(.false_positive), q);
        try w.print(") | {d} |", .{t.get(.true_finding)});
    }
    try w.writeByte('\n');
}

const Group = enum { motif, construct, bug };

fn groupOf(name: []const u8) Group {
    if (std.mem.startsWith(u8, name, "m_")) return .motif;
    if (std.mem.startsWith(u8, name, "bug_")) return .bug;
    return .construct;
}

fn tagTable(w: *Io.Writer, cfg: Config, results: []const *Result, heading: []const u8, comptime group: Group, comptime pure: bool) !void {
    try w.print("\n### {s}\n\n", .{heading});
    try tableHeader(w, cfg, "construct");
    inline for (std.enums.values(gen.Tag)) |tag| {
        if (groupOf(@tagName(tag)) == group) {
            const row = if (pure) rowOf(results, pureMotif, tag) else rowOf(results, hasTag, tag);
            if (row.programs != 0) try tableRow(w, cfg, @tagName(tag), row);
        }
    }
}

pub fn writeMarkdown(w: *Io.Writer, data: ReportData) !void {
    const cfg = data.cfg;
    const results = data.results;
    var invalid: u32 = 0;
    var compile_bad: u32 = 0;
    for (results) |r| {
        if (r.truth != .invalid) continue;
        invalid += 1;
        if (std.mem.eql(u8, r.detail, "does not compile")) compile_bad += 1;
    }
    const overall = rowOf(results, all, {});
    try w.print("# zv-own differential oracle\n\nzv-own binary: `{s}`\n\nseed {d}, {d} programs generated; {d} dropped as invalid ({d} did not compile, {d} panicked for a reason that is not a memory error); {d} used.\n\n", .{ cfg.own, cfg.seed, cfg.count, invalid, compile_bad, invalid - compile_bad, overall.programs });
    try w.print("Ground truth: {d} programs fault, {d} do not.\n\n", .{ overall.modes[0].faulting(), overall.modes[0].quiet() });
    try w.writeAll("A silent miss is a program that faults in Debug while zv-own says `clean` and the function's footer counts nothing it did not decide. A counted miss is the same with something undecided (the COUNTED verdict, or for an older zv-own a footer count); an assumed-only miss is `clean` with only an assumption in the footer (a call through a function pointer or to code outside the packs, a linear value handed to memory it does not follow). Silent rate = silent / faulting; false-positive rate = false positives / non-faulting. `plain` is the pack of the project alone (std's containers from the table in src/own/spec.zig); `std` is the pack with the std bodies (ZV_AIR_STD=1).\n\n");
    try w.writeAll("## Overall\n\n| mode | faulting | true finding | silent miss | counted miss (COUNTED verdict or undecided) | assumed only (clean, but a call or a value it does not follow) | unproven (faulting) | non-faulting | false positive | true clean | unproven (clean) |\n|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n");
    for (0..2) |m| {
        if (!cfg.modes[m]) continue;
        const t = overall.modes[m];
        try w.print("| {t} | {d} | {d} | {d} (", .{ @as(Mode, @fromBackingInt(@intCast(m))), t.faulting(), t.get(.true_finding), t.get(.silent_miss) });
        try pct(w, t.get(.silent_miss), t.faulting());
        try w.print(") | {d} | {d} | {d} | {d} | {d} (", .{ t.get(.counted_miss), t.get(.assumed_miss), t.get(.unproven_fault), t.quiet(), t.get(.false_positive) });
        try pct(w, t.get(.false_positive), t.quiet());
        try w.print(") | {d} | {d} |\n", .{ t.get(.true_clean), t.get(.unproven_clean) });
    }
    try w.writeAll("\nA program counts toward every construct it contains, so a rate in the tables below is the rate of programs that use the construct, not of the construct alone; the single-motif table is the clean attribution.\n");
    try tagTable(w, cfg, results, "By motif, programs of exactly one motif", .motif, true);
    try tagTable(w, cfg, results, "By motif, any program containing it", .motif, false);
    try tagTable(w, cfg, results, "By construct", .construct, false);
    try tagTable(w, cfg, results, "By step that is a mistake when the paths line up (what the generator aimed at; the faulting column is what really faulted)", .bug, false);

    try w.writeAll("\n## Minimized silent misses\n\n");
    if (data.min.len == 0) try w.writeAll("None minimized.\n");
    for (data.min, 1..) |m, n| {
        try w.print("### {d}. {s} ({t}, {d} programs with this signature, {d} more minimizations reduced to the same function)\n\nGround truth: `{s}`. Also silent in the other mode: {s}.\n\n```zig\n{s}```\n\n", .{ n, m.signature, m.mode, m.programs, m.merged, m.fault, if (m.also_other_mode) "yes" else "no", m.source });
    }
}

pub const JsonlData = struct { results: []const *Result };
pub const ReportData = struct { results: []const *Result, min: []const Minimized, cfg: Config };

pub fn writeJsonl(w: *Io.Writer, data: JsonlData) !void {
    for (data.results) |r| {
        try w.print("{{\"id\":{d},\"truth\":\"{t}\",\"detail\":", .{ r.program.id, r.truth });
        try jsonString(w, r.detail);
        try w.print(",\"groups\":{d},\"plain\":\"{t}\",\"std\":\"{t}\",\"tags\":[", .{ r.program.groups(), r.class(.plain), r.class(.std) });
        var it = r.tags.iterator();
        var first = true;
        while (it.next()) |t| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("\"{t}\"", .{t});
        }
        try w.writeAll("]}\n");
    }
}

pub fn writeJson(w: *Io.Writer, data: ReportData) !void {
    const cfg = data.cfg;
    try w.print("{{\"seed\":{d},\"count\":{d},\"modes\":{{", .{ cfg.seed, cfg.count });
    var first_mode = true;
    for (0..2) |m| {
        if (!cfg.modes[m]) continue;
        if (!first_mode) try w.writeByte(',');
        first_mode = false;
        const mode: Mode = @fromBackingInt(@intCast(m));
        try w.print("\"{t}\":{{\"overall\":", .{mode});
        try jsonRow(w, rowOf(data.results, all, {}).modes[m]);
        try w.writeAll(",\"tags\":{");
        var first = true;
        inline for (std.enums.values(gen.Tag)) |tag| {
            const row = rowOf(data.results, hasTag, tag);
            if (row.programs != 0) {
                if (!first) try w.writeByte(',');
                first = false;
                try w.print("\"{s}\":{{\"programs\":{d},\"counts\":", .{ @tagName(tag), row.programs });
                try jsonRow(w, row.modes[m]);
                try w.writeByte('}');
            }
        }
        try w.writeAll("},\"motifs_alone\":{");
        first = true;
        inline for (std.enums.values(gen.Tag)) |tag| {
            if (groupOf(@tagName(tag)) == .motif) {
                const row = rowOf(data.results, pureMotif, tag);
                if (row.programs != 0) {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.print("\"{s}\":{{\"programs\":{d},\"counts\":", .{ @tagName(tag), row.programs });
                    try jsonRow(w, row.modes[m]);
                    try w.writeByte('}');
                }
            }
        }
        try w.writeAll("}}");
    }
    try w.writeAll("},\"minimized\":[");
    for (data.min, 0..) |m, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"id\":{d},\"mode\":\"{t}\",\"programs\":{d},\"also_other_mode\":{},\"signature\":", .{ m.id, m.mode, m.programs, m.also_other_mode });
        try jsonString(w, m.signature);
        try w.writeAll(",\"fault\":");
        try jsonString(w, m.fault);
        try w.writeAll(",\"source\":");
        try jsonString(w, m.source);
        try w.writeByte('}');
    }
    try w.writeAll("]}\n");
}

fn jsonRow(w: *Io.Writer, t: Tally) !void {
    try w.writeByte('{');
    inline for (std.enums.values(Class), 0..) |c, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("\"{s}\":{d}", .{ @tagName(c), t.n[i] });
    }
    try w.writeByte('}');
}

fn jsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => {},
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}
