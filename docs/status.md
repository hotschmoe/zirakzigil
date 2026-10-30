# Status: where we are and what's next

Parked on 2026-10-30 at **v0.17.30** (Zig 0.17.0). Everything is on `master`; there are no other branches. Old experiment branches are kept as `archive/*` tags. Read this first, then the doc each row points to.

## Where we are

| Part | State | Read |
| --- | --- | --- |
| Phase 0: comptime contracts, `Ranged`, `Linear`, `Pool`, laws with pinned regressions, manifests | Done. zmoltcp is the pilot. | [adoption.md](adoption.md), [phase0-report.md](phase0-report.md) |
| Phase 1: thin compiler fork exporting AIR packs | Done. Three hook lines, byte-identical output, packs exported in CI (none committed), prebuilt `zig-zv` assets on releases. | [phase1.md](phase1.md), [design.md](design.md) "Fork policy" |
| Phase 2: `zvc`, SMT verification over AIR | Done. Three soundness review rounds; 7 zmoltcp functions proved. | [phase2.md](phase2.md), [reviews/zvc-soundness-*](reviews/) |
| Phase 3: `zv-own`, static ownership checker | Working, gate **not met**. Verdicts: clean, COUNTED, FINDINGS, UNPROVEN. One choke point decides every end. On five external projects (zls, ziggy, libvaxis, webzocket, rich_zig) 13 reported, 8 real, 5 false positives. 0 silent misses on the differential oracle since 0.17.30 (one known silent class remains, see `phase3.md`); `clean` now means nothing left open or assumed. | [phase3.md](phase3.md), [reviews/own-*.md](reviews/), [reviews/oracle-1.md](reviews/oracle-1.md) |
| Phase 4: verified core | Partway. Permission tokens (`PointsTo`, `BlockSet`, `Cell`), ghost code via `zv.Ghost(T)`; bump, pool and intrusive free-list allocators `.verified` with 0 trusted. Quantifiers are unrolled (the free list has 8 blocks). | [phase4.md](phase4.md) |
| Ergonomics track | Items 1 to 3 done (ghost code without gates, natural code, `zig build verify`: first green ~75 s, re-check after an edit ~1 s). Items 4 to 10 written with acceptance lines, not started. | [ergonomics.md](ergonomics.md) |
| Differential oracle | Done. 6000 generated programs vs Debug runs; nightly workflow `oracle.yml`. | [reviews/oracle-1.md](reviews/oracle-1.md), `tools/oracle/` |

## Numbers (last measured)

- Oracle, 6000 programs, seed 1, plain packs: silent misses 19.5% (0.17.21) -> 3.6% (0.17.22) -> 0 (0.17.30); findings 2211 -> 2334; false positives 128 (4.7%) unchanged. Independent check at seed 7 (600 programs): 0 silent, 2.8% false positives. One silent class is known and listed in `phase3.md`: a direct call outside the packs with no pointer argument or result.
- External projects: 60 -> 20 -> 13 functions reported; false positives 55 -> 14 -> 5 (0.17.13 -> 0.17.15 -> 0.17.18 onward).
- zmoltcp: 7 functions proved by `zvc`; `zv-own` 0 findings (890 clean, 96 COUNTED for assumed calls since 0.17.30).
- External projects at 0.17.30: COUNTED is high on real code (zls 456 clean, 590 COUNTED); ownership declarations are the planned way down.

## Decisions already made (do not re-litigate)

- Pin one Zig release (0.17.0); version is 0.17.x; port per release, no nightly. The fork stays thin.
- Packs are binary by default, JSON behind a flag; never committed.
- `zv-own` moves to explicit ownership declarations (`.owns` / `.borrows` per pointer parameter in the manifest): required on `.verified` / `.checked` code, opt-in elsewhere; inference stays a best-effort linter.
- `zvc` goes deep (Verus-like): real quantifiers, sequences, stores into blocks, toward hash maps.
- Ergonomics has the same priority as soundness. A precision rule is never worth a silent miss.
- Tests: laws, end-to-end, and pinned regression cases only; no unit tests.

## What's next, in order

1. **Phase 3 gate.** The oracle is at 0 silent misses (0.17.30). Close the last known silent class (direct calls outside the packs), widen the oracle's generator with new motifs, then run one fresh adversarial review round on 0.17.30 that must find no silent miss. Only then call Phase 3 done.
2. **Ownership declarations** (ergonomics item 5): design in `phase3.md`, manifest syntax, two-sided checks, gate requires them on `.verified` / `.checked`. This is what brings COUNTED down without new inference rules.
3. **Cheap wins from libghostty** (ergonomics items 7 to 10): `zv.tripwire` errdefer fault injection, `verifyIntegrity` convention shared by run-time checks, laws and `zvc`, `errdefer comptime unreachable` as a boundary, `zv.checkAll`.
4. **Diagnostics** (item 4): Zig-compiler-style one-line errors with fix hints; footers behind `--verbose`.
5. **Phase 4 depth:** real quantifiers with triggers, stores into block bytes (links inside free blocks), then M4b ring buffer, M5 region epochs, M5b typed offset regions with generations (the libghostty page/pin bug class).
6. **Measure and dogfood** (item 6): ghost-lines ratio, time to green, a small game allocator in `examples/`.
7. **Positioning:** make "start light, ratchet up" the default path in `README.md` and `adoption.md` (light tier on day one: laws, `Ranged`/`Linear` where they fit, `checkAll`, `zv-own` as a non-blocking CI lane; `zvc` and declarations only for a settled core).

## Open decisions for the owner

- zmoltcp: adopt `addVerify` (replaces `addVerifyGate` / `addOwnershipGate`, removed in 0.17.28); `own/seeded.expect` needs `okQueryRoundTrip counted`; since 0.17.30 its functions with assumed calls are COUNTED, so any ownership baseline must be rewritten.
- Report the real bugs found in other projects upstream? (zls `Server.loop`, `Workspace.refreshBuildOnSave`, `TrigramStore.init`; libvaxis ListView/ScrollView `drawBuilder`, `MouseHandler.updateMouse`; lsp-kit saved scanner; zigimg `OctTreeQuantizer.init`; ziggy `cli.lsp.logic.schemaForDoc` frees a pointer 7 bytes into an allocation, harmless with its arena. Reports and reproducers are outside the repo in `C:\Users\hotschmoe\zr\ext\REPORT-*.md` and `ext\repro\`.) Check each project's LLM policy first; never contribute to ziglang/zig.
- webzocket: finish the permessage-deflate send side.

## How to pick it up

- Build and run everything: `sh tools/check.sh` (builds `zig-zv` when its sources changed, exports all packs, runs `tools/run_zvc.sh` and `tools/run_own.sh`; needs Z3 or `ZV_Z3`).
- `zig build` does **not** install `zv-own` or `zvc`; use `zig build zv-own` / `zig build zvc` before checking a verdict by hand.
- Oracle: `zig build oracle` (builds `zv-own` from the tree under test).
- Adopting project: `zirakzigil.addVerify(b, .{ ... })`, then `zig build verify` ([adoption.md](adoption.md)).
- Release: tag `v0.17.N` on master, `gh release create`; `release.yml` attaches `zig-zv` assets; if the patch queue changed, run `tools/pin_assets.sh v0.17.N` and commit the pins.
- Reviews have been the best defence: every precision round so far opened a silent class that an independent reviewer or the oracle found. Keep running both after each `zv-own` change.
