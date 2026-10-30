# Ergonomics track

Zig is worth using because it is pleasant: plain code, no hidden control flow, comptime instead of macros. If zv makes verified Zig read like a different language, teams will not adopt it, and it will do nothing for multi-contributor safety. This track has the same priority as soundness. Each item is done when its acceptance line holds.

Where we stood (2026-10-30, before items 1 and 2): `examples/freelist.zig` was 304 lines with 29 `if (zv.ghost) x else {}` branches, `return null` had to be written as `const none: ?Block = null; return zv.ensures(none, ...)`, an index was `@truncate`d to `u3` to avoid an obligation, and the pool was capped at 8 blocks. Verifying needed a patched compiler, export scripts, packs, Z3 and sometimes WSL (item 3 removed all of that); `tools/run_zvc.sh` takes about 90 s.

## 1. Ghost code without noise (done, 0.17.26)

`zv.Ghost(T)` is `T` in ghost builds and a zero-size box otherwise, with every operation callable unconditionally. A field is `order: zv.Ghost([8]u32) = .{}`, a call is `self.order.put(n, i)`, a read is `p.order.at(k)`. The tokens (`PointsTo`, `BlockSet`, `Cell`) and `Int`/`Seq` are types in every build; without ghost code they have no fields and their operations do nothing, so `self.spare = parts.tail` needs no gate. Reading a ghost value in a build without ghost code returns zero and marks the contract that read it unchecked (`zv.holds`), so such a contract is proved by `zvc` and checked in ghost builds only; it never fails a production run. `zvc` and `zv-own` read the real types, so nothing in them changed for this.

API break, no shims: `zv.Ghost` used to be a capture helper and now is this type; token fields became accessors (`t.lo()`, `t.hi()`, `bs.id()`, `bs.mask()`, `bs.has(i)`, `Cell.slot()/value()`), and `BlockSet.bit(i)` is the mask of one block. `zmoltcp` uses its own copy of the dependency and is untouched (still `zvc: 7 proved`).

Zero cost: `tools/check_erasure.sh` compiles `tests/erasure/plain.zig`, the free list written with no ghost code, and `examples/freelist.zig` in ReleaseFast without ghost code, and requires the assembly of `alloc` and `free` to be identical (it is: 55 and 79 lines; only a block label number differs). It runs in CI. `@sizeOf` tests in the examples pin the layouts.

### Ghost lines per code line (`tools/ghost_lines.sh FILE STRUCT [REV]`)

Lines of the verified struct without tests and doc comments. `gate` is `if (zv.ghost)` and `else {}`: lines written to keep the proof out of the program.

| example | code | contract | spec | ghost | gate | proof per code, before | after |
|---|---|---|---|---|---|---|---|
| bump | 37 -> 33 | 18 -> 18 | 33 -> 33 | 6 -> 11 | 10 -> 0 | 1.81 | 1.88 |
| pool | 32 -> 23 | 12 -> 12 | 23 -> 26 | 5 -> 14 | 10 -> 0 | 1.56 | 2.26 |
| freelist | 43 -> 31 | 12 -> 12 | 31 -> 30 | 8 -> 20 | 21 -> 0 | 1.67 | 2.00 |

The honest reading: the amount of proof did not shrink, the noise did. The ratio went up because the code shrank; what is gone is the gating, the `const got: ?T` temporaries and the casts. File length: bump 289 -> 277, pool 250 -> 239, freelist 304 -> 267. Occurrences of `zv.ghost` in `examples/`: bump 18 -> 1, pool 18 -> 1, freelist 29 -> 0 (the one left in each of the first two is `zv.ghost or @sizeOf(...)` in a layout test; `ledger.zig` keeps a ghost counter test). Workaround grep (`zv.ghost`, `else {}`, `const got/none: ?`, `@truncate`, `@as(u3`): bump 22 -> 1, pool 24 -> 2, freelist 40 -> 0, search unchanged (its hits are `@as(u32, ...)` in tests, not workarounds).

## 2. Natural code is accepted (done, 0.17.26)

What was asked for, a function-level `zv.contract(.{ ... })`, cannot be written in plain Zig: there are no closures, and a `ensures` clause must see the returned value, which does not exist at the top. The design that does work is `zv.requires(...)` first (now also after pure computation, and with obligations inside its arguments) and `return zv.ensures(value, cond)` for every shape of return: `null`, a struct, a plain value, and `zv.ensures({}, cond);` as the last statement of a `void` function. A contract is two lines, in the same place in every function.

Limits of `zvc` fixed instead of worked around, each pinned by a case that must verify:

| workaround removed | what `zvc` does now | pinned case |
|---|---|---|
| `const none: ?Block = null; return zv.ensures(none, ...)` | `zv.ensures(null, c)` matches a null optional return | `tests/zvc/lists.zig` `L.alloc`, `examples/freelist.zig` `alloc` |
| index `@truncate`d to `u3` so the bound is free | arrays are indexed by `u32`, the bound is an obligation the solver discharges; a zero-extended narrow value is folded against a large constant | `L.alloc`, `L.free`, `FreeList.free` |
| `+%`/`-%` in specs and `@as(u3, ...)` | plain `+`, `-` with the overflow obligations proved | `FreeList.sound`, `granted` |
| `if (zv.ghost) x else {}` around ghost calls | ghost types in every build | all of `examples/` |
| `!zv.ghost or ...` in specs | a spec may read ghost state; unchecked at run time without ghost code | `tests/zvc/features.zig`, `soundness*.zig` |
| `zv.Ghost(usize)` captures of `id` and mask | plain `const id = self.spare.id()` | `FreeList.alloc` |
| `zv.requires` before any obligation ("an obligation inside a requires argument blocks verification") | allowed until the function changes something (`mutated` in `vc.zig`: a store to a by-value copy or to a `*Self` pointee, or a call with pointer effects); error text "zv.requires must come before the function changes anything" | `tests/zvc/features.zig` (`requiresAfterCompute`, `requiresObligation`, `nullPlain`, `indexPlain`, with `indexUnguarded` refuted) |
| default `.{}` ghost field | an undefined struct with no token is a fresh symbolic struct | `FreeList.init` |
| `owns` hid a missing `idx < 64` behind `@truncate` | the spec now says it (`blk.idx < 64` in `tests/zvc/pools.zig`): a real gap in the old spec | `pools.zig` |

Every pinned verdict still holds: refuted stays refuted for the same reason (`tools/run_zvc.sh` and `tools/run_own.sh` exit 0; the only differences are the two intentional negative-gate lines, `soundness2.useAssume` and `assumeCheat`).

### Before and after

```zig
// before (freelist.alloc)
const none: ?Block = null;
if (self.nfree == 0) return zv.ensures(none, unchanged(old, self.*) and old.nfree == 0);
const idx = self.head;
const parts = if (zv.ghost) self.spare.cut(@as(u64, 1) << @truncate(idx)) else {};
self.spare = if (zv.ghost) parts.tail else {};
// after
if (self.nfree == 0) return zv.ensures(null, unchanged(old, self.*) and old.nfree == 0);
const idx = self.head;
const parts = self.spare.cut(zv.BlockSet.bit(idx));
self.spare = parts.tail;
```

### Cost and caveats

- Solver time grew with natural arithmetic, because the overflow and bound obligations are now real: freelist `alloc` has 119 obligations (about 6.5 s), `free` 80 (5.6 s), `init` 9.8 s, `reuse` 26 s with the relied-on contracts; bump `alloc` 10.8 s, `pair` 8.9 s. `run_zvc.sh` is slower overall.
- `zv.Cell` instances print as one type name (`zv.Cell__struct`) in diagnostics.
- `zv-own` does not track `BlockSet` and `Cell` as linear; `bump` reports 5 unproven for the known whole-struct `old = self.*` read, pinned in `tests/own/tokens.zig` as `advWholeStructRead`.
- Contracts that read ghost state are not checked in non-ghost Debug builds.

## 3. One command, no setup

`zig build verify` fetches a prebuilt zig-zv and Z3 for Windows and Linux (checksummed, pinned to the Zig tag), exports, caches verdicts per function, and runs `zvc` and `zv-own`. No WSL, no manual exporter, Windows links.

Acceptance: from a fresh clone on Windows and on Linux, the first green check in under 5 minutes; after a one-function edit, a re-check in seconds.

Status (0.17.27): done, with one pending step per release (below). A project writes one call, `zirakzigil.addVerify(b, .{ .exports = ... })` (docs/adoption.md), and runs `zig build verify`. Nothing is installed or exported by hand and WSL is not involved.

How it works:

- **zig-zv** is a lazy dependency of zirakzigil's `build.zig.zon` per host, `zig-zv-<zig tag>-<patch queue hash>-<arch>-<os>.tar.gz` from the release assets (x86_64 Windows and Linux), so the Zig package manager downloads and content-hashes it. The name carries the Zig tag and a hash of everything zig-zv is built from (`tools/queue_hash.sh`); CI refuses a pin that belongs to another queue. Without a pin for the host, or with `-Dzv-from-source`, `tools/ensure_zig_zv.sh` builds it once per queue hash into the global Zig cache and says so.
- **Z3** 4.16.0 is a lazy dependency on the upstream release (Windows and Linux x86_64), content-hashed the same way. `ZV_Z3` or `-Dz3=PATH` override it. It is not mirrored on our releases: the pin is by hash, and upstream's tags are permanent.
- **Export** runs on every `zig build verify`: `zig-zv test -fno-emit-bin` on the named files (a second or two for the consumer), written to `.zig-cache/zv/packs`. It never links.
- **Verdict cache**: `zv-verify check` (src/verify/main.zig) proves each `.verified` function in its own `zvc` process, unless `.zig-cache/zv/verdicts` holds a proof under the key sha256(AIR ids of the function and of everything it calls, their manifest levels, the timeout, the bytes of `zvc`, the version of Z3). Only proofs are cached; a refuted or unproven function is proved again. A manifest entry that names a function missing from the packs still fails.
- **Windows linking**: `zig-zv` cannot link executables on Windows. Built without LLVM it uses the self-hosted COFF linker, which cannot read the `compiler_rt.lib` it wrote (`invalid value 608 for weak external symbol 0x630`); a stock compiler built without LLVM does the same, so it is a defect of that linker in 0.17.0, not of the patch queue. The flow does not depend on it: export is a `-fno-emit-bin` compile, and the checkers are built by the stock compiler. Not fixed.

Pending per release: the assets exist only after a tag is pushed (`.github/workflows/release.yml`), and their hashes can only be written into `build.zig.zon` afterwards (`tools/pin_assets.sh TAG`, then commit). Until the first pin, consumers get the from-source fallback (about 8 minutes, 9 GB). Releases must include the assets (docs/phase1.md, "Prebuilt zig-zv and Z3 for consumers").

Measured (`tools/consumer_flow.sh`: a fresh project made from `tests/consumer`, three `.verified` functions and one ownership module; zig-zv packaged and pinned the way a release is and served from a local server; Z3 downloaded from github.com; Zig global cache empty; CI runs it on both systems):

| | Windows 11 (x86_64) | Linux (WSL2 Ubuntu 24.04, x86_64) |
| --- | --- | --- |
| first green `zig build verify`, cold | 74 s and 83 s (two runs) | 100 s |
| second run, nothing changed | 1 s | under 1 s |
| after editing one function | about 1 s (0.7 s measured with `time`) | 1 s |

Cold is dominated by downloading Z3 (67 MB) and compiling `zv-verify`, `zvc` and `zv-own` in ReleaseSafe; the proofs themselves take 0.9 s. The zig-zv asset (7.6 MB on Windows, 30 MB on Linux, whose binary is not stripped) came from a local server in these runs; from github.com it adds seconds. Building zig-zv from source instead (`-Dzv-from-source`, the fallback) took 10 minutes on Linux (619 s, 24 cores, including the first run). The edit run re-proves only the edited function (`2 from the cache`) and exports again. A seeded mistake (`(lo + hi) / 2`) fails the build with `REFUTED  bounds.midpoint` and the counterexample.

## 4. Diagnostics like the Zig compiler

One line per problem: `file:line:col: error: <short reason>`, the source line with a caret, and a one-line fix hint. Footers, counts and assumptions only with `--verbose`; a final one-line summary.

Acceptance: every diagnostic in the pinned suites fits the format; an LLM given only the diagnostic fixes a seeded mistake in a scripted trial.

## 5. Ownership declarations live in the manifest

Per pointer parameter `.owns` / `.borrows` (see the decision in `docs/phase3.md` once written): required for `.verified` and `.checked` functions, opt-in elsewhere, declared in the module's ownership manifest rather than in function bodies, and checked from both sides.

Acceptance: a `.verified` module declares ownership without any new syntax in its function bodies.

## 6. Measure how it feels

Track ghost lines per code line, time from fresh clone to first green, re-check time, and diagnostics per seeded mistake. Dogfood on a small, fun program (an allocator for a toy game) and file each point of friction as a bug.

Acceptance: the numbers are in this file and updated with each release; the dogfood program exists in `examples/` and verifies.

## Copied from libghostty

Four practices from ghostty's terminal core (`C:\Users\hotschmoe\zr\ext\REPORT-ghostty.md`, commit `ca91d0a`), chosen because they are cheap, need no compiler fork and already pay off in a large Zig codebase with many contributors. They belong to the lightest tier of zv: a project can use them without `zvc` or `zv-own`.

## 7. Fault injection for `errdefer`

Ghostty's `src/tripwire.zig` ("Improper `errdefer` is one of the highest sources of bugs in Zig code"): named fail points in a function (`tw.check(.alloc_rows)`), a test that arms each point in turn, and an `end(.reset)` that fails if an armed point was never reached. `zv` gets the same as a library type plus a law helper that runs a function once per fail point under `DebugAllocator`.

Acceptance: `zv.tripwire` exists with no cost in release builds; an e2e case finds an OOM-only double free of the #12811 shape that ordinary tests miss; `docs/adoption.md` recommends it for every function with more than one `errdefer`.

## 8. `verifyIntegrity` as the run-time half of invariants

A type exposes `verifyIntegrity(self) IntegrityError!void` with a named error per invariant, and an inline `assertIntegrity()` that runs it, called through `defer` at the top of each mutating method, with a nesting pause for multi-step updates and a written list of invariants deliberately not checked. Ghostty gates it to Debug only; `zv` gates it separately for Debug and ReleaseSafe. `zv.invariant` and laws reuse the same function, so one invariant serves the run-time check, the laws and (where it is in the fragment) `zvc`.

Acceptance: `examples/` has one container written this way; its laws call `verifyIntegrity`; the same predicate is the `zvc` invariant of a `.verified` method.

## 9. `errdefer comptime unreachable` as a commit point

Ghostty marks the point after which a multi-step update cannot fail with `errdefer comptime unreachable` (27 uses): the compiler rejects any later `try`. `zv-own` and `zvc` treat it as a boundary: no error exit past it, so error-path states after it are not explored, and `docs/adoption.md` recommends it.

Acceptance: a pinned case where the marker removes a COUNTED or UNPROVEN that came only from an impossible error path.

## 10. Compile every `pub` declaration

Zig analyses only what is referenced, so unreferenced `pub` code rots unnoticed (forced analysis found six declarations in ghostty that no longer compile on 0.17). `zv.checkAll(root)` is a test-time helper (stock Zig, no fork) that references every `pub` declaration of a module tree, with a skip list.

Acceptance: `zig build test` in the consumer project runs it; it reports a seeded dead declaration that does not compile.
