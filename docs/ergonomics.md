# Ergonomics track

Zig is worth using because it is pleasant: plain code, no hidden control flow, comptime instead of macros. If zv makes verified Zig read like a different language, teams will not adopt it, and it will do nothing for multi-contributor safety. This track has the same priority as soundness. Each item is done when its acceptance line holds.

Where we stand (2026-10-30): `examples/freelist.zig` is 304 lines with 29 `if (zv.ghost) x else {}` branches, `return null` has to be written as `const none: ?Block = null; return zv.ensures(none, ...)`, an index is `@truncate`d to `u3` to avoid an obligation, and the pool is capped at 8 blocks. Verifying needs a patched compiler, export scripts, packs, Z3 and sometimes WSL; `tools/run_zvc.sh` takes about 90 s.

## 1. Ghost code without noise

A `zv.Ghost(T)` type that is `T` in ghost builds and `void` otherwise, with its operations callable unconditionally, so a field is `spare: zv.Ghost(BlockSet)` and a call is `self.spare.cut(i)`.

Acceptance: no `if (zv.ghost)` in `examples/`; ghost lines per code line measured and published for each example.

## 2. Natural code is accepted

Contracts declared once at the top of a function (`zv.contract(.{ .requires = ..., .ensures = ... })` or equivalent), so `return null`, `return x`, plain loops and ordinary integer types verify without temporaries, wrapping returns or casts written for the verifier.

Acceptance: the examples contain no construct whose only purpose is to satisfy `zvc`; each workaround removed is pinned as a case that must verify.

## 3. One command, no setup

`zig build verify` fetches a prebuilt zig-zv and Z3 for Windows and Linux (checksummed, pinned to the Zig tag), exports, caches verdicts per function, and runs `zvc` and `zv-own`. No WSL, no manual exporter, Windows links.

Acceptance: from a fresh clone on Windows and on Linux, the first green check in under 5 minutes; after a one-function edit, a re-check in seconds.

## 4. Diagnostics like the Zig compiler

One line per problem: `file:line:col: error: <short reason>`, the source line with a caret, and a one-line fix hint. Footers, counts and assumptions only with `--verbose`; a final one-line summary.

Acceptance: every diagnostic in the pinned suites fits the format; an LLM given only the diagnostic fixes a seeded mistake in a scripted trial.

## 5. Ownership declarations live in the manifest

Per pointer parameter `.owns` / `.borrows` (see the decision in `docs/phase3.md` once written): required for `.verified` and `.checked` functions, opt-in elsewhere, declared in the module's ownership manifest rather than in function bodies, and checked from both sides.

Acceptance: a `.verified` module declares ownership without any new syntax in its function bodies.

## 6. Measure how it feels

Track ghost lines per code line, time from fresh clone to first green, re-check time, and diagnostics per seeded mistake. Dogfood on a small, fun program (an allocator for a toy game) and file each point of friction as a bug.

Acceptance: the numbers are in this file and updated with each release; the dogfood program exists in `examples/` and verifies.
