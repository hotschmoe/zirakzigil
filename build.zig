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

    const examples = [_][]const u8{ "search", "ledger", "regress", "queries" };
    const has_fuzz_targets = [_]bool{ false, true, true, false };
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
        .laws = &.{ "search.zig", "ledger.zig", "regress.zig", "queries.zig" },
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
}
