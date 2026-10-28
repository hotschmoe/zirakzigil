# Adopting zv in a library (Phase 0)

This is the consumer's guide: how a codebase such as zmoltcp (freestanding, no allocator) takes on the comptime and runtime layers, and what the manifest rules are. `tests/consumer/` is a working miniature of everything below and is built by `zig build test`.

## Depending on zv

```zig
// build.zig.zon
.dependencies = .{
    .zirakzigil = .{ .path = "../zirakzigil" }, // or .url/.hash
},
```

```zig
// build.zig
const ghost = b.option(bool, "ghost", "Compile zv ghost code") orelse false;
const zv = b.dependency("zirakzigil", .{ .ghost = ghost }).module("zv");
// then: .imports = &.{.{ .name = "zv", .module = zv }}
```

The exported module carries no target or optimize mode, so it is compiled for whatever the importing artifact targets (freestanding included). Only `ghost` travels through the dependency arguments.

`zv` allocates nothing and needs no OS on the library path. `zig build freestanding` compiles a smoke object using contracts, `Ranged`, `Pool`, `Linear`, `PinCheck` and `requireAssurance` for `aarch64` and `riscv64` freestanding in Debug and ReleaseSafe, so an OS dependency cannot slip in. `zv.laws`, `zv.checkLaws`, `zv.fuzzLaws` and `zv.report` are test and host tooling (they print and use `std.testing`); they are analyzed only where used. Two properties to know about: runtime panics go through the root's `panic` handler (the stock freestanding one traps), and the `Linear` ledger is a 2 KB global that is not thread safe.

## Manifest rules

Each module has `pub const assurance = .{ ... }` and `comptime { zv.requireAssurance(@This(), floor); }`. The gate is strict by default: **every public runtime declaration must be classified, and nothing is exempt by name**.

| Public declaration | Classification | Why |
| --- | --- | --- |
| `pub fn f(...)`, including generic fns with `comptime` params or `anytype` | `.f = <Level>` at or above the floor | It is runtime code whatever its parameters are. |
| `pub fn T(comptime ...) type` | `.T = .governed` | Its methods do not exist until instantiation, so it has no level. `.governed` promises that the returned type has its own `pub const assurance` and gates itself with `comptime { zv.requireAssurance(@This(), floor); }`. Forgetting the entry is an error; giving it a level is an error. Reviewers can grep `.governed`. |
| `pub const X = struct { pub fn m() void {} }` (any container with pub fns) | `.X = .{ .m = <Level> }`, a nested manifest that mirrors the declaration | Methods are public runtime functions. Nesting follows decl nesting, so `pub const wire = struct { pub const Y = struct {...} }` is `.wire = .{ .Y = .{ ... } }`. |
| `pub const X = std.Random` or any foreign type | `.X = .external` | Not ours to classify, but the decision must be written down. Counted separately. |
| `pub const m = @import("m.zig")`, or an instance like `pub const Ring = zv.Ranged(0, 9)` | nothing | A type with its own `assurance` is checked against it, recursively, at the caller's floor. A root.zig that only re-exports gets `assurance = .{}` and a `requireAssurance` that walks every re-exported module. Aliases of an already-visited type are counted once. |
| `pub const n = 5`, `pub const E = error{...}`, field-only structs | nothing | Not runtime code. Listing a constant is an error. |

`laws` namespaces are not special: their functions are classified (`.laws = .{ .conservation = .tested }`). A law added without an entry fails like any other function.

Errors say what is wrong and what to write, for example: ``pub type `Seq` in app has pub functions but is not classified. Add `.Seq = .{ .method_name = .tested, ... }` ...``. The first problem is reported; `tests/compile_fail/cases.txt` has one case per rule.

The alternative considered for type constructors was exempting them. It is simpler but lets a new generic container with unclassified methods into the codebase, which is the exact failure the gate exists to stop.

## Measuring the gate

`zv.assuranceCounts(M)` returns `zv.Counts` (verified, checked, tested, trusted, governed, external) for one module; `zv.manifest.audit(M, floor)` also returns the first problem instead of failing the build. `zv.report` prints the table and exits non-zero if a module has no manifest, an unclassified function, or a level under its floor. A consumer adds one line per module:

```zig
// tools/assurance.zig
pub fn main(init: std.process.Init) !void {
    try zv.report.run(init.io, .{
        .{ "ring_buffer", lib.storage.ring_buffer },
        .{ "tcp", lib.wire.tcp, .checked }, // optional per-module floor
    }, .tested);
}
```

```zig
// build.zig
const report = b.addExecutable(.{ .name = "assurance", .root_module = b.createModule(.{
    .root_source_file = b.path("tools/assurance.zig"),
    .target = b.graph.host,
    .imports = &.{ .{ .name = "zv", .module = zv }, .{ .name = "mylib", .module = lib } },
}) });
b.step("assurance", "Per-module assurance table").dependOn(&b.addRunArtifact(report).step);
```

Do not list a re-exporting root next to its children: the table would count them twice. The root's own `requireAssurance` already gates the whole tree.

## Laws, two ways

`zv.checkLaws(laws, iterations, seed)` is the deterministic CI gate: seeded, edge-biased (0, 1, min, max over-represented), same inputs every run. `zv.fuzzLaws(laws, corpus)` registers all laws as one `std.testing.fuzz` target; each input byte stream picks a law and derives its arguments (the same edge bias, `Ranged` values inside their range). Call it from a single `test` block. Without `--fuzz` it replays `corpus` plus one empty input, so it also runs in plain `zig build test`.

Argument types: integers (`usize` included), `bool`, `zv.Ranged`, and structs of those.

Findings on 0.17.0: the API is `std.testing.fuzz(context, testOne, .{ .corpus = ... })` with `testOne(context, *std.testing.Smith)`. `zig build test --fuzz` is **not implemented on Windows** (`error: --fuzz not yet implemented for windows`; the fuzzer runtime does not compile there either). A fuzz-instrumented build of the examples does compile for `x86_64-linux`. Run `--fuzz` in Linux CI; keep `checkLaws` as the gate that works everywhere. The `--fuzz` run itself was not exercised in this environment (no Zig on the available WSL image).
