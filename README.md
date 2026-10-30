# Zirakzigil

**A formalization layer for multi-contributor Zig.** Contracts, refinement types, ownership backstops and an SMT verifier, stacked on top of the stock Zig compiler with no fork and no new syntax.

> *Zirakzigil* is the dwarven name for the Silvertine. Durin's Endless Stair climbs from the deepest level of Moria to the tower on its summit. This project is a stair of that kind, a stack of layers where each one checks what the layer below cannot.

## The problem

**In Rust, a weaker contributor does less damage than in Zig.** Rust's borrow checker and type system turn many ownership, aliasing and lifetime mistakes into compile errors at the line where they were made. A reviewer can approve a diff by reading the diff and the signatures it touches, because the compiler has already checked the rest. Bugs and slow drift away from the original design are stopped before merge, however many people touch the code.

Zig gives explicit *mechanics* (allocators, control flow, error handling) but not explicit *invariants*. Who frees this slice? Is this pointer still valid after `append`? Is it legal to copy this struct? Which handle belongs to which pool? In Zig those answers live in the original author's head. The language effectively assumes **one person who understands the whole program**, and it works well when that holds. It degrades when the code is shared among people who each understand only part of it.

**That is the situation we expect.** Projects will be worked on by many contributors, and many of them will be **agents**: some frontier LLMs, some small models running locally, with very different levels of skill. An agent that cannot hold the whole program in context is exactly the "contributor who only understands part of the code" that Zig handles badly. Experience so far with agent-driven development points the same way. Agents stay on track when a checker tells them, precisely and immediately, that they are wrong. Languages with strong static checking or formal verification keep agents in their lane; languages that rely on the author's discipline let them drift.

**Zirakzigil's goal** is to give Zig that guard rail without forking the language:

1. Move invariants out of authors' heads into **signatures, types and contracts** a machine checks at every call site.
2. Make every function's **level of assurance explicit**, and make it a compile error to lower it quietly.
3. Let the **least trusted contributor** (a junior, a small local model) satisfy a checker owned by the **most trusted** (the maintainers), with errors reported where the mistake was made.

## The stack

| Layer | What it catches | Status |
| --- | --- | --- |
| **A. Contracts** `zv.requires` / `ensures` / `invariant` | Broken pre/postconditions, blamed on the side that broke them | Built |
| **B. Refinement and brand types** `zv.Ranged`, `zv.Pool(..., struct {})` | Overflow in ranged arithmetic, out-of-range values, cross-pool handle mixups, unsafe narrowing | Built |
| **C. Runtime ownership backstops** `zv.Linear`, generational handles (`zv.Pool`, and `zv.Slots` over borrowed storage), `zv.PinCheck` | Double consume, use-after-free via stale handle, copied self-referential structs, leaks | Built |
| **D. Static ownership checker** `zv-own` (over AIR) | The bugs in C, at compile time, plus region escapes, pointer invalidation, pinned copies and aliasing writes | Phase 3 built; four adversarial reviews and an overseer review found silent misses each time, so since 0.17.22 every end and use has a counted outcome and a `clean` verdict means "nothing left open" **relative to the constructs the checker validated** (`docs/phase3.md`: what `clean` means, the counted classes, the known silent classes). 225 seeded mistakes in the first corpus: 211 found, 4 unproven, 7 missed; 0 findings on zmoltcp (986 functions, no allocator: it exercises little of the identity model); `--max-undecided` and `--baseline` gate how much a run leaves open |
| **E. Deductive verifier** `zvc` (Verus-style, Z3) | Functional correctness and absence of every safety panic | Phase 2 done: reads AIR packs, bit-precise, Z3 over a pipe; seven zmoltcp functions proved in its build |
| **F. C backend + CBMC** | Panic-freedom of bounded proof harnesses | C emission tested, checker not wired |
| **H. Governance** assurance manifest + laws | Silent erosion of guarantees by contributors | Built |

Every module declares how much assurance each public function carries, and the compiler enforces it:

```zig
pub const assurance = .{ .midpoint = .verified, .scale = .checked };
comptime { zv.requireAssurance(@This(), .checked); } // missing entry or downgrade = compile error

pub fn midpoint(lo: u32, hi: u32) u32 {
    zv.requires(lo <= hi);
    const mid = lo + (hi - lo) / 2;
    return zv.ensures(mid, lo <= mid and mid <= hi);
}
```

The same function is compiled normally, checked at runtime in safe builds (contracts vanish in `ReleaseFast`), and proved statically by `zvc`. The naive `(lo + hi) / 2` passes every small unit test; `zvc` rejects it with the counterexample `lo=1, hi=4294967295`.

The full rationale, the survey of prior art (Verus, Bend 2, SPARK, CN, Kani) and the detailed roadmap are in [`docs/design.md`](docs/design.md).

## Does it catch anything plain Zig misses?

Each negative test has a plain-Zig **control** in `tests/baseline/`: the same bug written without `zv`, run on the stock compiler. `./tools/run_baseline.sh` checks that each control behaves as documented below.

| Bug | Plain Zig 0.17 (Debug / ReleaseSafe / ReleaseFast) | With `zv` |
| --- | --- | --- |
| Copied withdrawal token deposited twice | silent / silent / silent: `total=160`, started with 100 | **panic** in safe builds |
| Stale handle after the slot is reused | silent / silent / silent: debits the new owner | **panic** in safe builds |
| Self-referential struct copied by value | silent / silent / silent: writes go to the original | **panic** in safe builds |
| Handle from one pool used on another | silent / silent / silent | **compile error** |
| Out-of-range value (`pct = 101`) | silent / silent / silent | **compile error** |
| Index type wider than the array | panic / panic / undefined behavior, and only on paths a test runs | **compile error** |
| Narrowing a value that may not fit | panic / panic / undefined behavior, via `@intCast` | **compile error** |
| `(lo + hi) / 2` midpoint overflow | panic / panic / undefined behavior, only if a test uses a huge input; small-input unit tests pass | **proved buggy** by `zvc`, with a counterexample and no test needed |
| Caller violates a documented precondition | panic / panic / undefined behavior; the panic points inside the callee | Same panic, but it **blames the caller** |
| Public function with no assurance level, or a downgraded one | not expressible | **compile error** |

To be clear about the weak spots: the runtime backstops (layer C) are switched off in `ReleaseFast`, exactly like Zig's own safety checks, so they only catch what tests and fuzzing actually run in a safe build. Moving those catches to compile time is the job of `zv-own` (Phase 3).

## Layout

| Path | What it is |
| --- | --- |
| `src/zv.zig` | The library root: contracts, `Ranged` integers, branded generational `Pool`, `Linear(T)`, `PinCheck`; re-exports the rest |
| `src/slots.zig` | `Slots(T, Brand)` and `Handle(Brand)`: generational handles over caller-provided slot slices, `error.StaleHandle` instead of a panic |
| `src/manifest.zig` | Assurance manifests: `requireAssurance`, `assuranceCounts`, `audit` |
| `src/laws.zig` | Executable laws: seeded `checkLaws` (with `replay`), fuzzer-driven `fuzzLaws`, `Bytes(max)`, pinned counterexamples replayed first |
| `src/pinned.zig` | The `pub const pinned` corpus: literal-to-argument coercion with compile errors, paste-ready entry printer, fuzz-input encoder |
| `src/report.zig` | `zv.report`: the Phase 0 gate. Walks a root module's manifests, joins every claim to the coverage evidence and fails the build on a claim no law or scenario executed |
| `src/cover.zig` | `zv.cover.hit`, the execution probe the gate plants in a generated copy of the source (never written by hand) |
| `src/gate/instrument.zig` | The build-time tool that makes that copy: a hit in every function body, every unit test removed except in the evidence files |
| `examples/search.zig` | Functions with contracts. Two contain planted bugs (`midpointNaive`, `withdrawNaive`) |
| `examples/ledger.zig` | Accounts in a branded pool, money as linear tokens, laws checked as properties |
| `examples/regress.zig` | The regression workflow: a failed law's printed entry pinned, bug fixed, case kept forever |
| `examples/queries.zig` | zmoltcp's DNS query-table pattern on `zv.Slots`, with a model-based law and one scenario test |
| `examples/assurance.zig` | The report entry point for the examples: one root, the walk finds the modules |
| `tests/consumer/` | A downstream project depending on this package by path; built by `zig build test`, including its own assurance gate |
| `tests/gate_fail/` | A library whose manifest claims a function no law runs: `zig build test` requires its gate to fail and name it |
| `tests/freestanding/` | Smoke object cross-compiled for aarch64 and riscv64 freestanding |
| `tests/should_panic/` | Contributor mistakes that must panic in safe builds |
| `tests/compile_fail/cases.txt` | Contributor mistakes that must be rejected at compile time |
| `tests/baseline/` | The same mistakes in plain Zig, showing what the stock compiler does with them |
| `src/own/` | The ownership checker: reads AIR packs, follows `zv.Linear` tokens (and, from M2, owners of memory) over the structured control flow (`docs/phase3.md`) |
| `src/zvc/` | The verifier: reads AIR packs (`zv_air`), derives verification conditions, discharges them with Z3 over a pipe (`docs/phase2.md`) |
| `tools/zvc_export.sh`, `tools/run_zvc.sh`, `tools/install_z3.sh` | Export a file's AIR pack (with `ZV_AIR_STD=1`, also the std functions it reaches, cut by `zv-air slice`), run the zvc suite (`tests/zvc/`: pinned packs and verdicts), install the pinned Z3 |
| `tools/run_own.sh`, `tools/own_repin.sh` | Run the zv-own suite (`tests/own/`: pinned packs and verdicts); export its packs again |
| `tools/run_negative.sh` | Runs the should-panic and compile-fail suites |
| `tools/run_baseline.sh` | Runs the plain-Zig controls in three build modes |
| `docs/design.md` | Design document |
| `docs/adoption.md` | Consumer guide: dependency lines, manifest rules, report, laws, fuzzing, the testing policy (laws + scenarios, regressions are pinned entries) and borrowed slots |

## Running it

Requires **Zig 0.17.0** (pinned in `build.zig.zon`), and Z3 for the verifier (`tools/install_z3.sh DEST` installs the pinned release; `zvc` finds it through `ZV_Z3` or `PATH`).

```sh
zig build test                          # unit, example and law tests, freestanding cross-compile, tests/consumer
zig build test -Doptimize=ReleaseFast   # contracts compile out
zig build test -Dghost=true             # ghost (verification-only) code compiled in
zig build matrix                        # every optimize mode x ghost off/on, plus freestanding and tests/consumer (what CI runs)
zig build assurance                     # the Phase 0 gate on the examples: every classified function must be executed by a law or scenario
zig build freestanding                  # zv for aarch64 / riscv64 freestanding, Debug and ReleaseSafe
zig build test --fuzz                   # laws under the real fuzzer (Linux/macOS only; not implemented on Windows)
zig build test --fuzz=100K              # the same, stopping after 100K iterations (what CI runs)
./tools/run_negative.sh                 # 6 must-fail + 36 must-not-compile cases
./tools/run_baseline.sh                 # the same bugs in plain Zig (about 1.5 min)
tools/run_zvc.sh                        # the verifier against its pinned AIR packs and verdicts (needs Z3)
tools/run_own.sh                         # the ownership checker against its pinned AIR packs and verdicts (no solver)
```

To use `zv` from another project see [`docs/adoption.md`](docs/adoption.md): `b.dependency("zirakzigil", .{ .ghost = ghost }).module("zv")`, `zirakzigil.addAssuranceGate` for the Phase 0 gate (a root module and the names of your law and scenario files). Your own `zig build matrix` is one call to `zirakzigil.addTestMatrix`; see "Build matrix" there.

## Results (Zig 0.17.0, 2026-10-28)

| Check | Result |
| --- | --- |
| `zig build test` | 48/48 (unit, examples, consumer project, freestanding cross-compile) in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall, each with and without `-Dghost=true` |
| Must panic: double consume, stale handle, pinned copy, violated precondition, parser law with an unguarded read, a falsified stateful law (must print a pasteable pinned entry) | 6/6 |
| Must not compile: the original 6 plus 15 manifest rules (type constructors, methods, re-exports, foreign types, witnesses, typos, stale entries), 13 malformed `pinned` entries and 2 slot-brand mixups | 36/36 |
| Plain-Zig controls | 9/9 behave as documented: 5 silent in every mode, 4 caught only at runtime in safe builds |
| `tools/run_zvc.sh` | `examples/search.zig` from AIR in 0.8 s: 4 proved, 2 planted bugs refuted with counterexamples; 32 pinned cases of the verifier itself |

The prototype was first built on Zig 0.16.0. Porting it to 0.17 took four mechanical changes: `**` array repetition became `@splat`, `StaticBitSet.initEmpty()` became `.empty`, `@typeInfo(T).@"struct"` exposes `decl_names` / `field_names` / `field_types` in place of `decls` / `fields`, and `@intFromEnum` became `@backingInt`. None of them touched the design. Only layers that read compiler internals (AIR) will need real rework per release.

### What `zvc` understands today

Integers of any width, bool, slices and arrays of integers, optionals, structs by value, locals in memory cells, `if`, `while` and `for` (loops are cut at `zv.invariant`), arithmetic, bit and shift operations, casts, and the safety checks Zig inserts (overflow, bounds, division, unwrap, `unreachable`, `@panic`). Anything else is reported **UNPROVEN** with its position and the reason, never silently accepted. Pointer-to-struct parameters (`*Self`) are in/out: the caller learns exactly the fields the callee may have changed. Calls between `.verified` functions go through their contracts; loops can state a measure with `zv.decreases` and ghost `zv.Int` and `zv.Seq` write specifications that cannot wrap. A `zv.PointsTo` permission token is linear to `zvc`: forging, copying or reusing one is refused ([`docs/phase4.md`](docs/phase4.md)).  Details in [`docs/phase2.md`](docs/phase2.md).

## Limits, honestly

- `zvc` covers a fragment of AIR: pointers other than to locals, floats, enums, unions and recursion are reported UNPROVEN. A loop with no `zv.decreases` is proved only for partial correctness (`--total` refuses it), and a counterexample that passes through a loop cut by its invariant may not be a real execution.
- Ownership is enforced at run time by layer C and, for what the abstraction follows, at compile time by `zv-own` (`docs/phase3.md` says which is which).
- The `Linear` ledger is a fixed 16K-slot global with no thread safety. It is fine for tests, not for production.

## Roadmap

Each phase ships value before the next one starts. Phases are ordered by dependency, not dated; each gate is the evidence that the next phase is worth building.

![Roadmap: Phase 0 to Phase 4 with exit gates, plus parallel track F](docs/img/roadmap.png)

| Phase | Scope | Exit gate |
| --- | --- | --- |
| **0. Adopt the comptime and runtime layers** (no fork) | `zv` contracts, `Ranged`, `Pool`, `Linear`; manifests; laws and fuzzing in CI | Every module has a manifest at floor `.tested` or higher, where `.tested` is measured: a law or scenario executes the function. **Met on the pilot** (zmoltcp 0.5.0: 549 of 549 classified functions evidenced; 185 had no evidence before); see [`docs/phase0-report.md`](docs/phase0-report.md) |
| **1. AIR exporter** | One small compiler patch: per-function AIR as a versioned binary pack (JSON on request) | Every function in a pilot codebase exports and round-trips |
| **2. `zvc` on AIR** | Port the spike: modular calls, structs, termination, ghost `Int` and `Seq` | Spike results reproduce from AIR, plus one real kernel verified |
| **3. `zv-own`** | Linearity, allocator regions, pointer invalidation, pinned types | Catches seeded ownership bugs at a false-positive rate the team accepts. **Done** (0.17.11), hardened after review 1 (0.17.13), rebuilt by identity after review 2 (0.17.15), tags and review 3 (0.17.18) |
| **4. Verified core** | `PointsTo` permission tokens, a verified allocator, proof agents in CI | The core is `.verified` and the `.trusted` count is falling. **M1 done** (0.17.17): `zv.PointsTo`, a bump allocator proved in bounds, aligned and disjoint, 23 pinned soundness verdicts. **M2 done** (0.17.19): `*Self` parameters in `zvc`, the allocator as methods, tokens checked by `zv-own`. **M3 done** (0.17.21): a pool of blocks on `zv.BlockSet`; see [`docs/phase4.md`](docs/phase4.md) |
| **Parallel track F** | C backend plus CBMC proof harnesses | Needs no fork, so it can start any time |

Phase 1 is the one decision that commits the project to maintaining a pinned compiler patch.

## License

Public domain, via [The Unlicense](LICENSE). Do whatever you want with it.
