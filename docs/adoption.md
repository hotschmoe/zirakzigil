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

`zv` allocates nothing and needs no OS on the library path. `zig build freestanding` compiles a smoke object using contracts, `Ranged`, `Pool`, `Slots`, `Linear`, `PinCheck` and `requireAssurance` for `aarch64` and `riscv64` freestanding in Debug and ReleaseSafe, so an OS dependency cannot slip in. `zv.laws`, `zv.checkLaws`, `zv.fuzzLaws` and `zv.report` are test and host tooling (they print and use `std.testing`); they are analyzed only where used. Two properties to know about: runtime panics go through the root's `panic` handler (the stock freestanding one traps), and the `Linear` ledger is a 2 KB global that is not thread safe.

## Build matrix

Every optimize mode catches different bugs, so build them all. `zig build test` stays your fast single-mode loop; one more line gives you the full matrix. Add `zirakzigil` to `build.zig.zon` as above, then in `build.zig`:

```zig
const zirakzigil = @import("zirakzigil"); // the dependency's build.zig; the name is its key in build.zig.zon

pub fn build(b: *std.Build) void {
    _ = zirakzigil.addTestMatrix(b, .{
        .root_source_file = b.path("src/root.zig"),
        .ghost = true, // also run every mode with ghost code compiled in
        .cross = &.{ "aarch64-freestanding-none", "riscv64-freestanding-none" },
    });
}
```

`zig build matrix` then compiles and runs the tests of `root_source_file` in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall, each with ghost off and (with `.ghost = true`) on, all in parallel, and compile-checks each `.cross` target as an object in Debug and ReleaseSafe without running it. `zv` is imported into every cell for you, wired to that cell's ghost setting (each setting is its own instance of the dependency). Other options: `.imports` for extra modules (they must not import `zv` themselves, or they keep the ghost setting they were built with), `.target` for the runnable cells (default: the host), `.name` to tell several matrices apart. The cross check builds the root as an object, so it covers what the root exports or references; reference what you want checked.

What each mode is for:

| Mode | Contracts and safety checks | What a failure there means |
| --- | --- | --- |
| Debug | on | A panic with a location: a contract, overflow, bounds or stale handle. |
| ReleaseSafe | on | The same, in optimized code. |
| ReleaseFast | off | A wrong answer (a law returning false, a wrong value) or undefined behavior the checks were hiding. |
| ReleaseSmall | off | The same as ReleaseFast, under size-oriented optimization. |
| ghost=on | verification-only code runs | Ghost code that disagrees with the real code, and ghost code that no longer compiles. |

Each cell is named for what it ran, so the build summary reads as a table and a failure points at its mode:

```text
+- run test Debug ghost=off 3 pass (3 total) 68ms
+- run test ReleaseSafe ghost=on 3 pass (3 total) 29ms
+- run test ReleaseFast ghost=off 3 pass, 1 fail (4 total)
+- run test ReleaseSmall ghost=on 3 pass (3 total) 36ms
+- compile obj cross aarch64-freestanding-none ReleaseSafe safe aarch64-freestanding-none success
```

Use `zig build matrix --summary all` to see the passing cells too. `tests/consumer/build.zig` is a working example, and this repository's own `zig build matrix` uses the same machinery.

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

`zv.assuranceCounts(M)` returns `zv.Counts` (verified, checked, tested, trusted, governed, unwitnessed, external) for one module; `zv.manifest.audit(M, floor)` also returns the first problem and every classified function as a `Claim`. A manifest is a claim; the gate is the evidence for it.

### What `.tested` means

A function classified `.tested` (or above) must be **executed by a law or a scenario**. Unit tests do not count, the suites that do count are named in `build.zig`, and the build fails, listing the function, when a claim has no evidence:

```
module                    fns verified checked tested trusted      laws scenarios unproven  status
wire.tcp                   23        0       3     20       0        23        22        0  ok
rpl                        21        0       0     21       0        21         0        0  ok
...
unproven claims (write a law or scenario that runs them, or lower the claim to .trusted with a code owner):
  rpl.TrickleTimer.poll: classified .tested, executed by no suite
```

How the evidence is produced, and why it cannot be written by hand:

1. `zirakzigil.addAssuranceGate` runs `src/gate/instrument.zig` over your source directory. It writes a copy into the build cache in which **every function body starts with a `zv.cover.hit(id)` call and every `test` block is removed**, except in the evidence files you name. The repository is never modified, and the tool rejects source that mentions the hit function, so a contributor cannot forge a hit.
2. The evidence roots are built against that copy and run: `.laws` are files inside the source directory (they keep their `test` blocks), `.scenarios` are files outside it that import the library by name and drive it end to end (`examples/`, for instance). Their stdout is captured; a law or scenario that fails fails the build with its own message.
3. `zv.report.run` walks the manifest from your root module, so a module cannot dodge the gate by not being listed, joins every claim to the instrumented function of the same qualified name (`wire.tcp.Repr.parse`), and fails when a `.tested`, `.checked` or `.verified` claim names a function that no suite executed or that does not exist. `.trusted` claims are exempt, counted, and still need a code owner.

A unit test that exercises a function therefore cannot raise its level; a law or scenario that runs it can, and that is the point: the owner decides what counts as evidence by choosing the roots. Execution is evidence that a law *reaches* the function, not that it *judges* the result. Keep laws as specifications (RFC and reference semantics), and use mutation spot checks to see they bite; `docs/phase0.md` records one.

Wiring, in the consumer's `build.zig`:

```zig
const report = b.addExecutable(.{ .name = "assurance", .root_module = b.createModule(.{
    .root_source_file = b.path("tools/assurance.zig"),
    .target = b.graph.host,
    .imports = &.{ .{ .name = "zv", .module = zv }, .{ .name = "mylib", .module = lib } },
}) });
_ = zirakzigil.addAssuranceGate(b, .{
    .report = report,
    .src = b.path("src"),            // instrumented as a whole
    .lib_name = "mylib",             // what scenario files import
    .laws = &.{"laws.zig"},          // evidence roots inside src; their tests are kept
    .scenarios = &.{b.path("examples/echo.zig")}, // evidence roots outside src
});
```

```zig
// tools/assurance.zig
pub fn main(init: std.process.Init) !void {
    try zv.report.run(init, @import("mylib"), .tested);
}
```

The step is `zig build assurance`, and it is attached to the default step, so a plain `zig build` reports the gate and fails on a gap. Claims that come from other packages (a dependency's `Slots` handle reached through your re-export, for example) are listed as foreign: their own package gates them. `tests/gate_fail/` is the negative test: a claim no law runs must fail the build and be named.

## Proving `.verified` functions

`.verified` means `zvc` proves the function's contracts and the absence of every safety panic ([phase2.md](phase2.md)). Write the contracts with `zv.requires`, `zv.ensures`, `zv.invariant` and `zv.decreases` (specifications that must not wrap use `zv.Int` behind `zv.ghost`), set the function to `.verified` in the manifest, and:

1. Export its AIR with a zig-zv compiler, in Debug and with ghost code on: `tools/zvc_export.sh verify/ src/root.zig --only wire.checksum --only wire.tcp.SeqNumber`. Each `--only` names a container, as the root sees it, whose pub functions are exported.
2. Check the pack in with the sources it came from: `verify/PINS` has one `SHA256  PATH` line per source file.
3. Add the gate to `build.zig` and run it:

```zig
_ = zirakzigil.addVerifyGate(b, .{
    .packs = &.{"verify/zmoltcp.zvp"},
    .pins = "verify/PINS",
    .src = "src",
});
```

`zig build verify` builds `zvc` from this package, finds Z3 (`-Dz3=PATH`, `ZV_Z3` or `PATH`; `tools/install_z3.sh DEST` installs the pinned release) and fails when a `.verified` function is refuted, unproven, or missing from the pack, or when a pinned source changed since the export: a claim cannot outlive the code it was proved of, and a pack is cheap to regenerate but never trusted stale. Stock Zig runs the gate; only exporting needs the patched compiler.

## Borrowed slots: `zv.Slots`

`zv.Pool` owns comptime-capacity storage and panics on a stale handle, which is right when a stale handle is a bug in the application. A *library* socket has the other contract: the caller hands it a slice of slots (`queries: []QuerySlot`), the capacity is a runtime value, and a stale handle is a normal outcome (the user cancelled, or read the result twice) that must come back as an error. `zv.Slots(T, Brand)` is that building block; `Pool` is unchanged.

```zig
const Table = zv.Slots(QueryState, struct {});      // brand: a unique type per table
pub const QuerySlot = Table.Slot;                   // what callers declare storage of
pub const QueryHandle = Table.Handle;               // plain data: {index: u32, generation: u32}

var storage: [4]QuerySlot = @splat(.empty);         // caller-owned
var queries: Table = .init(&storage);               // borrows; frees every slot, keeps generations

const h = try queries.insert(state);                // error.NoFreeSlot when full
const s = try queries.get(h);                       // *QueryState, error.StaleHandle if freed or reused
const owned = try queries.take(h);                  // move out and free
try queries.free(h);                                // error.StaleHandle if already freed
var it = queries.iterator();                        // live entries: .handle and .value (*T)
while (it.next()) |e| e.value.* = ...;
```

A slot's generation counts how often it has been filled (0 means never used, so a zeroed handle is never live) and survives freeing, so a reused slot never honours an old handle. Handles of different brands are different types and so are their slots: passing a socket's handle to a query table, or the wrong storage to `init`, is a compile error (`tests/compile_fail/cases.txt`: `slots_brand_mix`, `slots_storage_mix`). Two tables of the *same* brand (two instances of one socket type) are told apart only by generation; if that matters, give each its own brand (its own type). `insert` is a linear scan, as `findFreeSlot` is today, which suits tables of a handful of entries. The error names are chosen so a caller's own error set can include them and `try` straight through: `NoFreeSlot`, `StaleHandle`.

The mapping from `zmoltcp/src/socket/dns.zig`, worked out in `examples/queries.zig` (a compact socket with a model-based law and one scenario test):

| `dns.zig` today | with `zv.Slots` |
| --- | --- |
| `pub const QueryHandle = struct { index: usize, generation: u32 }` | `pub const QueryHandle = Table.Handle` |
| `pub const QuerySlot = struct { state: ?QueryState = null, generation: u32 = 0 }` | `pub const QuerySlot = Table.Slot` (`value: ?QueryState`, `generation`; users write `@splat(.empty)`) |
| `queries: []QuerySlot` | `queries: Table`, built by `Table.init(slots)` |
| `findFreeSlot()` then `state = .{ .pending = pq }` and `generation = handle.generation` | `try self.queries.insert(.{ .pending = pq })` |
| `liveSlot(handle) orelse return error.StaleHandle` | `try self.queries.get(handle)` |
| `slot.state = null` after a completed or failed result | `self.queries.take(handle)` (or `free`) |
| `cancelQuery`: `if (self.liveSlot(h)) \|slot\| slot.state = null` | `self.queries.free(h) catch {}` |
| `for (self.queries) \|*slot\| { const state = slot.state orelse continue; ... }` in `process`, `dispatch`, `pollAt` | `var it = self.queries.iterator(); while (it.next()) \|e\| ...` (`e.value` is `*QueryState`, so `.pending` can be updated in place) |
| tests peeking at `s.queries[h.index].state` | `try s.queries.get(h)` |

`findFreeSlot`, `liveSlot`, the `generation` bookkeeping in `startQueryRaw` and the two `generation`/`state == null` checks go away. One observable difference: `QuerySlot.state` is `QuerySlot.value`, which only matters to code that reaches into the slice directly.

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
