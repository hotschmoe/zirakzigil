const std = @import("std");

const optimize_modes = [_]std.builtin.OptimizeMode{ .debug, .safe, .fast, .small };

/// The spelling people use for a mode (`ReleaseFast`), not the enum tag.
fn modeName(mode: std.builtin.OptimizeMode) []const u8 {
    return switch (mode) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    };
}

pub const TestMatrixOptions = struct {
    /// Root of the code under test; it is compiled once per matrix cell.
    root_source_file: std.Build.LazyPath,
    /// Extra imports for the root module. `zv` is added for you, wired to the
    /// cell's ghost setting. Other modules must not themselves import `zv`
    /// (they would keep the ghost setting they were built with).
    imports: []const std.Build.Module.Import = &.{},
    /// Also run every mode with ghost (verification-only) code compiled in.
    ghost: bool = false,
    /// Freestanding (or other non-runnable) target triples, compile-checked
    /// without running as an object in Debug and ReleaseSafe.
    cross: []const []const u8 = &.{},
    /// Target for the runnable cells.
    target: ?std.Build.ResolvedTarget = null,
    /// Distinguishes several matrices in one build (`run test <name> Debug ...`).
    name: []const u8 = "",
};

/// Adds the `matrix` step: the tests in every optimize mode, each with ghost
/// off and (when requested) on, plus compile-only checks for `options.cross`.
/// Debug and ReleaseSafe fire contracts and safety checks; ReleaseFast and
/// ReleaseSmall turn checks off, so they catch wrong answers and UB-sensitive
/// code. `zig build test` stays the fast single-mode loop.
pub fn addTestMatrix(b: *std.Build, options: TestMatrixOptions) *std.Build.Step {
    const step = b.step("matrix", "Run the tests in every optimize mode, with and without ghost code");
    addVariants(b, step, options, wireDependency);
    return step;
}

pub const AssuranceGateOptions = struct {
    /// The consumer's report executable (see `zv.report`); it receives the evidence as arguments.
    report: *std.Build.Step.Compile,
    /// Directory holding the library source, instrumented as a whole.
    src: std.Build.LazyPath,
    /// Root file of the library, relative to `src`.
    root: []const u8 = "root.zig",
    /// The name scenario files import the library by.
    lib_name: []const u8,
    /// Extra imports for the library (everything except `zv`, which is added).
    imports: []const std.Build.Module.Import = &.{},
    /// Test roots inside `src`, run as the `laws` suite.
    laws: []const []const u8 = &.{},
    /// Test roots outside `src` that drive the library end to end, run as the `scenarios` suite.
    scenarios: []const std.Build.LazyPath = &.{},
};

/// Adds the `assurance` step and makes the default `zig build` run it. A
/// generated copy of `src` has a `zv.cover` hit planted in every function; the
/// law and scenario roots run against that copy, and the report fails the build
/// if any function the manifest classifies above `.trusted` was never executed.
/// Unit tests in `src` are not evidence: only the roots named here are run.
pub fn addAssuranceGate(b: *std.Build, options: AssuranceGateOptions) *std.Build.Step {
    const dep = b.dependencyFromBuildZig(@This(), .{ .ghost = false });
    return gate(b, options, dep.module("zv"), dep.path("src/gate/instrument.zig"));
}

const zon = @import("build.zig.zon");

pub const Export = struct {
    /// The source file whose public functions are exported (and their callees), relative to the project root. Its
    /// name without extension names the pack, so two exports need two names.
    file: []const u8,
    /// Dotted paths of the containers to export, as the file sees them (`wire.tcp.SeqNumber`). Empty: the file.
    only: []const []const u8 = &.{},
    /// `NAME=FILE.zig`: another module of the project that the file imports by NAME. Every module sees `zv`.
    deps: []const []const u8 = &.{},
    /// Only the first level of the selection, not the containers and files below it.
    shallow: bool = false,
    /// Also export the std functions the project reaches, which the ownership checker reads instead of a table.
    std: bool = false,
};

pub const OwnOptions = struct {
    /// Check only functions declared in files whose module-relative path starts with one of these. Empty: every
    /// function the packs hold except `zv` itself.
    files: []const []const u8 = &.{},
    /// Pinned verdicts, one `NAME clean|error|unproven` per line. Without it every checked function must be clean.
    expect: ?[]const u8 = null,
    /// Fail when more than this many functions are unproven (outside the checker's supported fragment).
    max_unproven: ?u32 = null,
    /// Fail when the functions leave more than this many ends and uses undecided (counted, not reported): `clean` is
    /// relative to what the checker validated, and this is how much it did not decide. See `docs/phase3.md`.
    max_undecided: ?u32 = null,
    /// Pinned undecided counts, one `NAME N` per line (`zv-own --write-baseline` writes it). Counts may only go down.
    baseline: ?[]const u8 = null,
    /// Fail when more than this many functions are declared `.trusted` in an `ownership` manifest.
    max_trusted: ?u32 = null,
    /// Where a module other than `src` (a dependency, `zv`) keeps its sources: `NAME=DIR` relative to the project root.
    modules: []const []const u8 = &.{},
};

pub const VerifyOptions = struct {
    exports: []const Export,
    /// Where the packs' module-relative source paths resolve, relative to the project root.
    src: []const u8 = "src",
    /// Refuse a loop that states no `zv.decreases`.
    total: bool = false,
    /// Fail when the proofs take more than this many distinct `.trusted` functions on faith. Listed in every run.
    max_trusted: ?u32 = null,
    /// Fail when the proofs rest on more than this many distinct `zv.assume` calls. Listed in every run.
    max_assume: ?u32 = null,
    /// Solver time per obligation.
    timeout_ms: u32 = 10_000,
    /// The ownership checker; null skips it.
    own: ?OwnOptions = .{},
};

/// Adds `zig build verify`, with `prove` (the `.verified` functions) and `own` (ownership) as its parts.
///
/// Everything needed is fetched or built for you, once: the zig-zv compiler for the pinned Zig tag (a prebuilt asset of
/// this package's release, checksummed in its build.zig.zon, else built from source with a message), and the pinned Z3
/// release. The sources are exported to AIR packs on every run, `zvc` proves every function the assurance manifests
/// mark `.verified`, and `zv-own` checks ownership. A verdict is cached per function, keyed by its AIR and its
/// callees', so an edit re-proves only what it can change.
///
/// Overrides: `-Dzig-zv=PATH`, `-Dzv-from-source`, `-Dz3=PATH` or `ZV_Z3`.
pub fn addVerify(b: *std.Build, options: VerifyOptions) *std.Build.Step {
    const dep = b.dependencyFromBuildZig(@This(), .{ .ghost = false });
    const zig_zv_path = b.option([]const u8, "zig-zv", "Use this zig-zv executable instead of the pinned release");
    const from_source = b.option(bool, "zv-from-source", "Build zig-zv from source instead of fetching the prebuilt release") orelse false;
    const z3_path = b.option([]const u8, "z3", "Use this Z3 executable instead of the pinned release");
    b.graph.poisonCache();
    const z3_env = b.graph.environ_map.get("ZV_Z3");
    const windows = b.graph.host.result.os.tag == .windows;

    const sources = b.createModule(.{
        .root_source_file = dep.path("src/zvc/sources.zig"),
        .imports = &.{.{ .name = "zv_air", .module = dep.module("zv_air") }},
    });
    const tool = b.addExecutable(.{ .name = "zv-verify", .root_module = b.createModule(.{
        .root_source_file = dep.path("src/verify/main.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "zv_air", .module = dep.module("zv_air") },
            .{ .name = "zv_sources", .module = sources },
        },
    }) });
    const zvc = b.addExecutable(.{ .name = "zvc", .root_module = b.createModule(.{
        .root_source_file = dep.path("src/zvc/main.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "zv_air", .module = dep.module("zv_air") }},
    }) });

    const cache: std.Build.LazyPath = .cache_root;
    const packs = cache.path(b, "zv/packs");

    const exporter = b.addRunArtifact(tool);
    exporter.setCwd(b.path("."));
    exporter.has_side_effects = true;
    exporter.addArg("export");
    const prebuilt: Pin = if (zig_zv_path != null or from_source) .absent else pin(dep, "zig_zv");
    if (zig_zv_path) |path| {
        exporter.addArgs(&.{ "--zig-zv", path });
    } else switch (prebuilt) {
        .available => |asset| {
            exporter.addArg("--zig-zv");
            exporter.addFileArg(asset.path(if (windows) "zig-zv.exe" else "zig-zv"));
        },
        .fetching => {},
        .absent => {
            exporter.addArg("--ensure");
            exporter.addFileArg(dep.path("tools/ensure_zig_zv.sh"));
            exporter.addArg("--work");
            exporter.addFileArg(b.graph.path(.global_cache, "zv"));
        },
    }
    exporter.addArg("--zig");
    exporter.addFileArg(.zig_exe);
    exporter.addArg("--lib");
    exporter.addFileArg(.zig_lib);
    exporter.addArg("--zv-src");
    exporter.addFileArg(dep.path("src/zv.zig"));
    exporter.addArg("--roots");
    exporter.addFileArg(dep.path("src/verify"));
    exporter.addArg("--out");
    exporter.addFileArg(packs);
    for (options.exports) |e| {
        exporter.addArgs(&.{ "--file", e.file });
        for (e.only) |path| exporter.addArgs(&.{ "--only", path });
        for (e.deps) |d| exporter.addArgs(&.{ "--dep", d });
        if (e.shallow) exporter.addArg("--shallow");
        if (e.std) exporter.addArg("--std");
    }

    const z3: ?std.Build.LazyPath = if (z3_path) |path| b.graph.cwdRelativePath(path) else if (z3_env != null) null else switch (pin(dep, "z3")) {
        .available => |asset| asset.path(if (windows) "bin/z3.exe" else "bin/z3"),
        .fetching, .absent => null,
    };

    const prove = b.addRunArtifact(tool);
    prove.setCwd(b.path("."));
    prove.has_side_effects = true;
    prove.addArg("check");
    prove.addArg("--zvc");
    prove.addArtifactArg(zvc);
    prove.addArg("--cache");
    prove.addFileArg(cache.path(b, "zv/verdicts"));
    if (z3) |path| {
        prove.addArg("--z3");
        prove.addFileArg(path);
    }
    prove.addArgs(&.{ "--src", options.src, "--timeout", b.fmt("{d}", .{options.timeout_ms}) });
    if (options.total) prove.addArg("--total");
    if (options.max_trusted) |limit| prove.addArgs(&.{ "--max-trusted", b.fmt("{d}", .{limit}) });
    if (options.max_assume) |limit| prove.addArgs(&.{ "--max-assume", b.fmt("{d}", .{limit}) });
    for (options.exports) |e| prove.addFileArg(packs.path(b, b.fmt("{s}.zvp", .{std.fs.path.stem(e.file)})));
    prove.step.dependOn(&exporter.step);
    const prove_step = b.step("prove", "Prove every .verified function from freshly exported AIR (verdicts are cached per function)");
    prove_step.dependOn(&prove.step);

    const verify = b.step("verify", "Export AIR, prove the .verified functions, check ownership");
    verify.dependOn(prove_step);

    if (options.own) |own_options| {
        const own = b.addExecutable(.{ .name = "zv-own", .root_module = ownModule(b, dep.path("src"), dep.module("zv_air"), b.graph.host, .ReleaseSafe) });
        const run = b.addRunArtifact(own);
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        run.addArgs(&.{ "--src", options.src });
        for (own_options.files) |prefix| run.addArgs(&.{ "--files", prefix });
        if (own_options.expect) |path| run.addArgs(&.{ "--expect", path });
        if (own_options.max_unproven) |limit| run.addArgs(&.{ "--max-unproven", b.fmt("{d}", .{limit}) });
        if (own_options.max_trusted) |limit| run.addArgs(&.{ "--max-trusted", b.fmt("{d}", .{limit}) });
        if (own_options.max_undecided) |limit| run.addArgs(&.{ "--max-undecided", b.fmt("{d}", .{limit}) });
        if (own_options.baseline) |path| run.addArgs(&.{ "--baseline", path });
        for (own_options.modules) |m| run.addArgs(&.{ "--module", m });
        run.addArg("--module");
        run.addPrefixedDirectoryArg("zv=", dep.path("src"));
        for (options.exports) |e| run.addFileArg(packs.path(b, b.fmt("{s}.zvp", .{std.fs.path.stem(e.file)})));
        run.step.dependOn(&exporter.step);
        const own_step = b.step("own", "Check the ownership of the functions in freshly exported AIR");
        own_step.dependOn(&run.step);
        verify.dependOn(own_step);
    }
    return verify;
}

const Pin = union(enum) {
    /// Nothing is pinned for this host.
    absent,
    /// Pinned and being fetched: the configure phase is rerun once it is there.
    fetching,
    available: *std.Build.Dependency,
};

/// The lazy dependency of this package's build.zig.zon named `PREFIX_ARCH_OS` for the host.
fn pin(dep: *std.Build.Dependency, comptime prefix: []const u8) Pin {
    const host = dep.builder.graph.host.result;
    const want = dep.builder.fmt("{s}_{t}_{t}", .{ prefix, host.cpu.arch, host.os.tag });
    inline for (@typeInfo(@TypeOf(zon.dependencies)).@"struct".field_names) |name| {
        if (std.mem.eql(u8, name, want)) {
            return if (dep.builder.lazyDependency(name, .{})) |asset| .{ .available = asset } else .fetching;
        }
    }
    return .absent;
}

fn gate(b: *std.Build, options: AssuranceGateOptions, zv: *std.Build.Module, instrument_source: std.Build.LazyPath) *std.Build.Step {
    const instrument = b.addExecutable(.{ .name = "zv-instrument", .root_module = b.createModule(.{
        .root_source_file = instrument_source,
        .target = b.graph.host,
    }) });
    const plant = b.addRunArtifact(instrument);
    plant.addDirectoryArg(options.src);
    const tree = plant.addOutputDirectoryArg("src");
    const map = plant.addOutputFileArg("cover.map");
    _ = plant.addDepFileOutputArg("cover.d");
    for (options.laws) |path| plant.addArg(path);

    const lib = b.createModule(.{
        .root_source_file = tree.path(b, options.root),
        .target = b.graph.host,
        .imports = options.imports,
    });
    lib.addImport("zv", zv);

    const check = b.addRunArtifact(options.report);
    check.addArg("--map");
    check.addFileArg(map);
    for (options.laws) |path| {
        const root = b.createModule(.{ .root_source_file = tree.path(b, path), .target = b.graph.host, .imports = options.imports });
        root.addImport("zv", zv);
        addSuite(b, check, "laws", root);
    }
    for (options.scenarios) |path| {
        const root = b.createModule(.{ .root_source_file = path, .target = b.graph.host });
        root.addImport(options.lib_name, lib);
        root.addImport("zv", zv);
        addSuite(b, check, "scenarios", root);
    }

    const step = b.step("assurance", "Check every classified function was executed by a law or scenario");
    step.dependOn(&check.step);
    b.getInstallStep().dependOn(step);
    return step;
}

fn addSuite(b: *std.Build, check: *std.Build.Step.Run, name: []const u8, root: *std.Build.Module) void {
    const tests = b.addTest(.{ .name = name, .root_module = root });
    const run = b.addRunArtifact(tests);
    run.stdio = .infer_from_args;
    run.expectExitCode(0); // hits go to stdout; a failing test keeps its stderr
    run.addCheck(.{ .expect_stderr_match = "passed" });
    check.addArg("--suite");
    check.addArg(name);
    check.addFileArg(run.captureStdOut(.{}));
}

const Wire = *const fn (b: *std.Build, root: *std.Build.Module, ghost: bool) void;

/// Each ghost setting is a distinct dependency instance, so its `zv` module
/// carries the matching `zv_options`.
fn wireDependency(b: *std.Build, root: *std.Build.Module, ghost: bool) void {
    const dep = b.dependencyFromBuildZig(@This(), .{ .ghost = ghost });
    root.addImport("zv", dep.module("zv"));
}

/// For this package's own examples: `zv` built from this checkout.
fn wireLocalImport(b: *std.Build, root: *std.Build.Module, ghost: bool) void {
    const zv = b.createModule(.{ .root_source_file = b.path("src/zv.zig") });
    zv.addOptions("zv_options", ghostOptions(b, ghost));
    root.addImport("zv", zv);
}

/// For zv's own unit tests, where the root module is zv itself.
fn wireLocalRoot(b: *std.Build, root: *std.Build.Module, ghost: bool) void {
    root.addOptions("zv_options", ghostOptions(b, ghost));
}

fn ghostOptions(b: *std.Build, ghost: bool) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, "ghost", ghost);
    return options;
}

fn addVariants(b: *std.Build, step: *std.Build.Step, options: TestMatrixOptions, wire: Wire) void {
    const target = options.target orelse b.graph.host;
    const ghosts: []const bool = if (options.ghost) &.{ false, true } else &.{false};
    for (optimize_modes) |mode| for (ghosts) |ghost| {
        const root = b.createModule(.{
            .root_source_file = options.root_source_file,
            .target = target,
            .optimize = mode,
            .imports = options.imports,
        });
        wire(b, root, ghost);
        const label = b.fmt("{s}{s}{s} ghost={s}", .{
            options.name,
            if (options.name.len == 0) "" else " ",
            modeName(mode),
            if (ghost) "on" else "off",
        });
        const tests = b.addTest(.{ .name = label, .root_module = root });
        step.dependOn(&b.addRunArtifact(tests).step);
    };

    for (options.cross) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch |err|
            std.debug.panic("bad cross target '{s}': {t}", .{ triple, err });
        for ([_]std.builtin.OptimizeMode{ .debug, .safe }) |mode| {
            const root = b.createModule(.{
                .root_source_file = options.root_source_file,
                .target = b.resolveTargetQuery(query),
                .optimize = mode,
                .imports = options.imports,
            });
            wire(b, root, false);
            const obj = b.addObject(.{ .name = b.fmt("cross {s} {s}", .{ triple, modeName(mode) }), .root_module = root });
            step.dependOn(&obj.step);
        }
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ghost = b.option(bool, "ghost", "Compile ghost (verification-only) code") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "ghost", ghost);

    // The module dependents import. It carries no target or optimize mode, so
    // it is compiled for whatever the importing artifact targets.
    const zv = b.addModule("zv", .{ .root_source_file = b.path("src/zv.zig") });
    zv.addOptions("zv_options", options);

    // Same source, pinned to this build's target: used by everything below.
    const local = b.createModule(.{ .root_source_file = b.path("src/zv.zig"), .target = target, .optimize = optimize });
    local.addOptions("zv_options", options);

    const test_step = b.step("test", "Run unit tests, example tests and the downstream-consumer check");

    const zv_tests = b.addTest(.{ .root_module = local });
    test_step.dependOn(&b.addRunArtifact(zv_tests).step);

    // `zig build fuzz --fuzz=<n>`: only the test binaries that contain fuzz
    // targets. Zig 0.17's fuzz report aborts on a binary without coverage
    // points ("pcs_len was zero"), so the whole `test` step cannot be fuzzed.
    const fuzz_step = b.step("fuzz", "Fuzz the laws; pass --fuzz=<n> (Linux only on Zig 0.17)");
    fuzz_step.dependOn(&b.addRunArtifact(zv_tests).step);

    const examples = [_][]const u8{ "search", "ledger", "regress", "queries", "bump", "pool", "freelist" };
    const has_fuzz_targets = [_]bool{ false, true, true, false, false, false, false };
    var example_modules: [examples.len]*std.Build.Module = undefined;
    for (examples, has_fuzz_targets, &example_modules) |name, fuzzed, *module| {
        module.* = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zv", .module = local }},
        });
        const t = b.addTest(.{ .root_module = module.* });
        test_step.dependOn(&b.addRunArtifact(t).step);
        if (fuzzed) fuzz_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Programs that must PANIC at runtime (run by tools/run_negative.sh).
    const neg = b.step("negative", "Build should-panic programs");
    for ([_][]const u8{ "double_consume", "stale_handle", "pin_copy", "precondition", "law_oob", "law_falsified" }) |name| {
        const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/should_panic/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zv", .module = local },
                .{ .name = "ledger", .module = example_modules[1] },
            },
        }) });
        neg.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    // The Phase 0 gate on the examples: their laws and scenario tests are the evidence.
    const report = b.addExecutable(.{ .name = "assurance", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/assurance.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "zv", .module = local }},
    }) });
    _ = gate(b, .{
        .report = report,
        .src = b.path("examples"),
        .lib_name = "examples",
        .laws = &.{ "search.zig", "ledger.zig", "regress.zig", "queries.zig", "bump.zig", "pool.zig", "freelist.zig" },
    }, zv, b.path("src/gate/instrument.zig"));

    // Freestanding gate: zv must not grow an OS dependency.
    const freestanding = b.step("freestanding", "Cross-compile zv for freestanding aarch64 and riscv64");
    for ([_][]const u8{ "aarch64-freestanding-none", "riscv64-freestanding-none" }) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable;
        for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe }) |mode| {
            const obj = b.addObject(.{ .name = "freestanding_smoke", .root_module = b.createModule(.{
                .root_source_file = b.path("tests/freestanding/smoke.zig"),
                .target = b.resolveTargetQuery(query),
                .optimize = mode,
                .imports = &.{.{ .name = "zv", .module = zv }},
            }) });
            freestanding.dependOn(&obj.step);
        }
    }
    test_step.dependOn(freestanding);

    // The gate must reject a claim no law or scenario executes, and say which one.
    const gate_fail = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "assurance" });
    gate_fail.setName("gate rejects an unexecuted claim");
    gate_fail.setCwd(b.path("tests/gate_fail"));
    gate_fail.has_side_effects = true;
    gate_fail.addCheck(.{ .expect_term = .{ .exited = 1 } });
    gate_fail.addCheck(.{ .expect_stdout_match = "root.forgotten: classified .tested, executed by no suite" });
    gate_fail.addCheck(.{ .expect_stderr_match = "Build Summary" });
    test_step.dependOn(&gate_fail.step);

    // Downstream-consumer check: a separate project that depends on this one by path.
    const consumer = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test", "assurance", b.fmt("-Dghost={}", .{ghost}), b.fmt("-Doptimize={t}", .{optimize}) });
    consumer.setCwd(b.path("tests/consumer"));
    consumer.has_side_effects = true;
    const consumer_step = b.step("consumer", "Build and test tests/consumer against this package");
    consumer_step.dependOn(&consumer.step);
    test_step.dependOn(consumer_step);

    // Every optimize mode, ghost on and off: this package's own tests, the
    // freestanding gate, and the consumer project doing the same through
    // `addTestMatrix` from outside.
    const matrix = b.step("matrix", "Run the tests in every optimize mode, with and without ghost code");
    addVariants(b, matrix, .{ .name = "zv", .root_source_file = b.path("src/zv.zig"), .ghost = true, .target = target }, wireLocalRoot);
    for (examples) |name| {
        addVariants(b, matrix, .{ .name = name, .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})), .ghost = true, .target = target }, wireLocalImport);
    }
    matrix.dependOn(freestanding);
    const consumer_matrix = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "matrix" });
    consumer_matrix.setName("consumer matrix");
    consumer_matrix.setCwd(b.path("tests/consumer"));
    consumer_matrix.has_side_effects = true;
    matrix.dependOn(&consumer_matrix.step);

    // The reader for zig-zv AIR packs (schema v2): a library for tools, and a command line for people.
    const air = b.addModule("zv_air", .{ .root_source_file = b.path("src/air/air.zig") });
    const air_cli = b.addExecutable(.{ .name = "zv-air", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/zv_air_cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zv_air", .module = air }},
    }) });
    b.step("zv-air", "Install the pack reader tool").dependOn(&b.addInstallArtifact(air_cli, .{}).step);

    // The verifier: reads AIR packs through `zv_air`, proves with Z3 over a pipe. Never links compiler code.
    const zvc = b.addExecutable(.{ .name = "zvc", .root_module = b.createModule(.{
        .root_source_file = b.path("src/zvc/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zv_air", .module = air }},
    }) });
    b.step("zvc", "Install the verifier").dependOn(&b.addInstallArtifact(zvc, .{}).step);

    // The ownership checker: the same packs, no solver.
    const own = b.addExecutable(.{ .name = "zv-own", .root_module = ownModule(b, b.path("src"), air, target, optimize) });
    b.step("zv-own", "Install the ownership checker").dependOn(&b.addInstallArtifact(own, .{}).step);
}

/// The module `zv-own` is built from; consumers build it from this package's sources with `addVerify`.
fn ownModule(b: *std.Build, src: std.Build.LazyPath, air: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const sources = b.createModule(.{
        .root_source_file = src.path(b, "zvc/sources.zig"),
        .imports = &.{.{ .name = "zv_air", .module = air }},
    });
    return b.createModule(.{
        .root_source_file = src.path(b, "own/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zv_air", .module = air },
            .{ .name = "zv_sources", .module = sources },
        },
    });
}
