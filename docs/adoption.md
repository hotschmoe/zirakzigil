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
| `pub fn T(comptime ...) type` | `.T = zv.governed(T(u8))` | Its methods do not exist until instantiation, so it has no level. The *witness* instantiation is audited like any other type: it must carry its own `pub const assurance` (and gate itself with `comptime { zv.requireAssurance(@This(), floor); }`), and its methods count toward the module. Bare `.governed` is still accepted as an unchecked promise but is counted in the report's `unwitness` column so the gate can ratchet it to zero. Forgetting the entry is an error; giving it a level is an error. |
| `pub const X = struct { pub fn m() void {} }` (any container with pub fns) | `.X = .{ .m = <Level> }`, a nested manifest that mirrors the declaration | Methods are public runtime functions. Nesting follows decl nesting, so `pub const wire = struct { pub const Y = struct {...} }` is `.wire = .{ .Y = .{ ... } }`. |
| `pub const X = std.Random` or any foreign type | `.X = .external` | Not ours to classify, but the decision must be written down. Counted separately. |
| `pub const m = @import("m.zig")`, or an instance like `pub const Ring = zv.Ranged(0, 9)` | nothing | A type with its own `assurance` is checked against it, recursively, at the caller's floor. A root.zig that only re-exports gets `assurance = .{}` and a `requireAssurance` that walks every re-exported module. Aliases of an already-visited type are counted once. |
| `pub const n = 5`, `pub const E = error{...}`, field-only structs | nothing | Not runtime code. Listing a constant is an error. |

`laws` namespaces are not special: their functions are classified (`.laws = .{ .conservation = .tested }`). A law added without an entry fails like any other function.

Errors say what is wrong and what to write, for example: ``pub type `Seq` in app has pub functions but is not classified. Add `.Seq = .{ .method_name = .tested, ... }` ...``. The first problem is reported; `tests/compile_fail/cases.txt` has one case per rule.

The alternative considered for type constructors was exempting them. It is simpler but lets a new generic container with unclassified methods into the codebase, which is the exact failure the gate exists to stop.

## Measuring the gate

`zv.assuranceCounts(M)` returns `zv.Counts` (verified, checked, tested, trusted, governed, unwitnessed, external) for one module; `zv.manifest.audit(M, floor)` also returns the first problem instead of failing the build. `zv.report` prints the table and exits non-zero if a module has no manifest, an unclassified function, or a level under its floor. A consumer adds one line per module:

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

`zv.checkLaws(laws, .{ .iterations = 10_000, .seed = 7 })` is the deterministic CI gate: seeded, edge-biased (0, 1, min, max over-represented; for `Ranged`, min, max, min+1, max-1), same inputs every run. Every iteration seeds its own generator from `(seed, law, iteration)`, so any case can be regenerated alone. `zv.fuzzLaws(laws, corpus)` registers all laws as one `std.testing.fuzz` target; each input byte stream picks a law and derives its arguments (the same model). Call it from a single `test` block. Without `--fuzz` it replays `corpus` plus one empty input, so it also runs in plain `zig build test`.

Argument types: integers (`usize` included), `bool`, `?T` (null a quarter of the time), `[N]T` (`[N]u8` is often all `0x00` or all `0xff`), enums (non-exhaustive ones also get arbitrary backing values), `zv.Ranged` (its two ends and their neighbours are over-represented, like ints), structs of those, and `zv.Bytes(max)`. `Bytes(max)` is the argument type for parser laws: `input.slice()` is a byte string whose *length* is edge-biased (0, 1, `max`, `max-1`, 8, 20, 40) as well as its content, so "this parser never panics on any bytes" and parse/emit round-trips are one-line laws. Anything else is a `@compileError` that says what to use.

### Testing policy: laws and scenarios, regressions are pinned

The policy `zv` is built to make cheap: **laws are the specification, and the only tests are laws and end-to-end scenario tests.** There are no small unit tests, because a unit test pins one example while a law states the rule, and a regression is a *pinned law instance*, not a new test function.

- A property of a function or type goes in a `laws` namespace (`pub fn name(args...) bool`), gated by the manifest like any other code.
- A whole-system behaviour goes in a scenario test that drives the public API end to end.
- A bug found by a law, by the fuzzer, by a scenario or by a user becomes an entry in `pub const pinned` next to the law that should have caught it. Never a new `test` block.

Workflow, with `examples/regress.zig` as the worked example (the buggy version is `tests/should_panic/law_falsified.zig`):

1. A law fails. `checkLaws` prints the case as a ready-to-paste entry, plus the replay call:

   ```
   zv: law `neverExceedsCapacity` falsified by random case (seed 11, iteration 7).
   zv: pin it: paste this into `pub const pinned` in the laws namespace (inside the existing `.neverExceedsCapacity` list if there is one):
       .neverExceedsCapacity = .{
           .{
               .{
                   .{ .kind = .pop, .weight = 0 },
                   .{ .kind = .push, .weight = 255 },
                   ... (one op per line, 12 in all)
               },
               2,
               1,
           },
       },
   zv: reproduce with zv.laws.replay(<laws>, "neverExceedsCapacity", 11, 7)
   ```

2. Paste it into the laws namespace and re-run: the pinned case now fails first, on every run, with no randomness involved.

   ```zig
   pub const laws = struct {
       pub fn neverExceedsCapacity(ops: [12]Op, cap: Cap, tag: ?u8) bool { ... }

       pub const pinned = .{
           .neverExceedsCapacity = .{
               .{ .{ ... 12 ops ... }, 2, 1 }, // one tuple per case, in argument order
           },
       };
   };
   ```

3. Fix the code. The pinned case turns green and stays in the suite for good. Changing a generator, the seed or the iteration count can never lose it, because `checkLaws` replays `pinned` before the first random iteration (even with `.iterations = 0`) and `fuzzLaws` seeds its corpus with it.

`pinned` is a `pub const`, not a function, so the manifest ignores it. It is also not a law: only `pub fn` declarations are. If the pinned case has a different reason to exist than "a law failed" (a protocol trace from a field report, say), write the tuple by hand; the spelling is the same.

### Pinned entries

`pub const pinned = .{ .lawName = .{ .{ arg0, arg1 }, .{ ... } } };` maps a law name to a list of cases, each a tuple of that law's arguments in order. It is checked at compile time (when `checkLaws` or `fuzzLaws` is instantiated): a name that is not a law, a case with the wrong number of arguments, an integer that does not fit, a `Ranged` value outside its range, a misspelled enum tag, a missing or unknown struct field are all compile errors that name the law, the case and the argument, and say what to write. Spelling by argument type:

| Argument | Pinned as |
| --- | --- |
| ints, `bool` | `5`, `-1`, `true` |
| enum | `.tag`; a non-exhaustive enum also takes an integer for an unnamed value |
| `?T` | `null` or a `T` |
| `[N]T` | `.{ a, b, ... }`; `[N]u8` also takes a string literal `"\x45\x00"` |
| `zv.Ranged` | the integer |
| `zv.Bytes(max)` | a string literal, or `.{ 0x45, 0x00 }` |
| struct | `.{ .field = value, ... }`; fields with defaults may be left out |

Any value of the argument's exact type is also accepted (`Pct.lit(5)`). Printed entries are the same syntax, multi-line when they would pass 96 columns: a law over `[32]Op` prints one op per line, and byte strings longer than 32 bytes are split into `"..." ++ "..."` chunks, so a pasted entry stays reviewable in a diff.

`fuzzLaws` encodes each pinned case back into the byte stream `std.testing.Smith` consumes (the law's index, then each argument exactly as the generator would read it) and prepends those to its corpus, so the coverage-guided fuzzer starts from every regression. This is simple because `Smith` reads each scalar as a little-endian `u64` and byte strings verbatim; `src/laws.zig` tests that every supported shape survives the round trip. A case whose encoding exceeds 32 KiB is not seeded (`checkLaws` still replays it). `fuzzLaws`'s `corpus` parameter is `comptime` so the two lists can be joined without an allocator; string and array literals work as before.

### When a law fails

A law that returns `false` prints the entry to pin, and, for a random case, the exact call to reproduce it (shown above). A pinned case that fails prints `zv: law X falsified by its pinned case N. Fix the code, not the pin:` and the entry.

`zv.laws.replay(Laws, "neverExceedsCapacity", 11, 7)` regenerates exactly that tuple, prints it as an entry and calls the law once (put it in a scratch `test` and run it under a debugger).

A law that **panics** (an unguarded `b[7]`, an overflow) aborts the test binary with the panic trace; Zig 0.17's test runner offers no hook, and a library cannot override the test root's `panic`, so the counterexample cannot be printed after the fact. Re-run with `.{ .trace = true }`: `checkLaws` prints `zv: law X seed S iteration I` to stderr before every call, and the last such line above the panic names the case. Feed it to `replay`. `tests/should_panic/law_oob.zig` demonstrates this and is part of `tools/run_negative.sh`.

Findings on 0.17.0: the API is `std.testing.fuzz(context, testOne, .{ .corpus = ... })` with `testOne(context, *std.testing.Smith)`. `zig build test --fuzz` is **not implemented on Windows** (`error: --fuzz not yet implemented for windows`; the fuzzer runtime does not compile there either). A fuzz-instrumented build of the examples does compile for `x86_64-linux`. Run `--fuzz` in Linux CI; keep `checkLaws` as the gate that works everywhere. The `--fuzz` run itself was not exercised in this environment (no Zig on the available WSL image).
