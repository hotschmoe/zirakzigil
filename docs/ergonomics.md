# Ergonomics track

Zig is worth using because it is pleasant: plain code, no hidden control flow, comptime instead of macros. If zv makes verified Zig read like a different language, teams will not adopt it, and it will do nothing for multi-contributor safety. This track has the same priority as soundness. Each item is done when its acceptance line holds.

Where we stand (2026-10-30): `examples/freelist.zig` is 304 lines with 29 `if (zv.ghost) x else {}` branches, `return null` has to be written as `const none: ?Block = null; return zv.ensures(none, ...)`, an index is `@truncate`d to `u3` to avoid an obligation, and the pool is capped at 8 blocks. Verifying needed a patched compiler, export scripts, packs, Z3 and sometimes WSL (item 3 removed all of that); `tools/run_zvc.sh` takes about 90 s.

## 1. Ghost code without noise

A `zv.Ghost(T)` type that is `T` in ghost builds and `void` otherwise, with its operations callable unconditionally, so a field is `spare: zv.Ghost(BlockSet)` and a call is `self.spare.cut(i)`.

Acceptance: no `if (zv.ghost)` in `examples/`; ghost lines per code line measured and published for each example.

## 2. Natural code is accepted

Contracts declared once at the top of a function (`zv.contract(.{ .requires = ..., .ensures = ... })` or equivalent), so `return null`, `return x`, plain loops and ordinary integer types verify without temporaries, wrapping returns or casts written for the verifier.

Acceptance: the examples contain no construct whose only purpose is to satisfy `zvc`; each workaround removed is pinned as a case that must verify.

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
