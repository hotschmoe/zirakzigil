# Synthesis: a fork that survives Zig releases

The question, protocol and metrics are in [README.md](README.md). There are four tracks, each benchmarked on two upgrade paths: the historical replay 0.16.0 -> 0.17.0, and the live port 0.17.0 -> 0.18.0-dev.738+ae9a8acc7. Full reports:

- Track A (hook mechanism, Sonnet 5.5): `research/track-a/RESULTS.md` on `research/track-a`
- Track B (adapter, Sonnet 5.5): `research/track-b/RESULTS.md` on `research/track-b`
- Track C (landscape, Grok 4.7 high): `research/track-c/RESULTS.md` on `research/track-c`
- Track D (zero-patch, Sonnet 5.5): `research/track-d/RESULTS.md` on `research/track-d`

## Answer

Pinning to a release stays the operating model. What changes is how small the fork is and how loudly it breaks. The combined design:

| Layer | Today (master) | Proposed | Source |
| --- | --- | --- | --- |
| Hook | 12-line unified diff, 3 files | 2 lines in 2 files, inserted by `tools/zv_hook.zig` from `compiler/hook/rules.zon`. Each rule must match exactly once, and nothing is written unless every rule resolves | A |
| Options | `--zv-air-*` flags plus `Compilation` fields | `ZV_AIR_OUT` / `ZV_AIR_STD`, read lazily from `comp.environ_map` | A |
| Cache key | hash of the output directory (buggy, see below) | a nonce whenever export is on, so an exporting compile is never a cache hit | A |
| In-compiler adapter | 454-line hand decoder | comptime-reflection raw dump (`reflect.zig` + `shapes.zig`), with 15 per-tag overrides | B |
| Version knowledge | in the compiler; any change means an 8-minute rebuild | out of the compiler: `norm` (a Zig tool) plus `norm/<ver>.zon`. Editing a rule needs no rebuild | B |
| Tripwires | canary smoke test (1 function) | `shapes.snapshot` (comptime), `norm --strict`, a golden-corpus diff, and a coverage assertion (corpus: 27 functions, about 1083 instructions, 0 unsupported) | A, B |
| Independent oracle | none | a stock `-Dlog=debug` compiler plus `air_text` (Track D), run weekly in the canary and compared with the hook's JSON | D |

Every row is backed by a run. The 0.17 output of A's hook and of B's normalizer is byte-identical to today's exporter on the corpus and `examples/search.zig`. B also matched on all of zmoltcp: 6194 functions and 619,706 instructions. The Linux canary passed on both branches against the nightly.

## What the two upgrade paths measured

| | 0.16 -> 0.17 (replay) | 0.17 -> 0.18-dev (live) |
| --- | --- | --- |
| Original text diff | does not apply to 0.16 or 0.18-dev | fails (upstream deleted `verbose_air`, the diff's context) |
| Re-anchored diff | applies, with offsets up to 130 | applies |
| Rule inserter (2 lines) | 0 changes | 0 changes |
| Hand adapter | 40 lines, 9 type-check rounds | 0 |
| Reflection + normalizer | 97 mechanical lines (`@typeInfo` was reshaped), 2 type-check rounds; **0 edits for tag churn** (4 renamed, 2 removed, 16 added) | 0 |
| Stock debug dump + text parser | 9 lines of tag-rename table; post-legalize on 0.16/0.17 | 0 grammar changes, 6 lines of framing |

Two caveats:

1. **The live path did not tell the adapters apart.** Nothing in AIR changed between 0.17.0 and ae9a8acc7. The live path did prove the hook question: the old diff broke and the rules didn't.
2. **On the replay, reflection cost more lines than the hand adapter (97 vs 40).** Reflection's advantage isn't fewer lines on every release. It is that tag churn, the most frequent change, costs nothing; the remaining edits are mechanical and found in 2 rounds instead of 9; and it adds drift detection the hand adapter can't have.

## Silent drift is the real risk, and each design has different holes

| Upstream change | Re-anchored diff | Rules | Hand adapter | Reflection + normalizer |
| --- | --- | --- | --- | --- |
| Duplicate anchor near the old line | applies in the **wrong function**, silently | loud: matched 2 times (re-verified) | n/a | n/a |
| A second path into analysis bypasses the hook | silent | `verify` fails | n/a | n/a |
| Operand added to a payload | n/a | n/a | **silently dropped** | `--strict` fails, naming the field |
| A tag's doc comment changes while the code doesn't | n/a | n/a | immune | silent without the snapshot; `shapes.snapshot` stops the build |
| A tag moves to another union field in code only | n/a | n/a | **silent garbage** (untagged union) | follows the doc; silent only if the doc is also stale |

No single layer closes every hole. The combination is the point:
- rules catch hook misplacement;
- the snapshot and `--strict` catch payload drift;
- the golden corpus catches anything that changes output;
- the Track D oracle catches what the hook-side design can't see itself, because it is a separate code path (the compiler's own printer, with no patch).

## Dead ends, with evidence in the track reports

| Route | Why it's dead | Track |
| --- | --- | --- |
| Compiler as a library, importing upstream `src/` from our build | `src/Air/print.zig:5` needs `build_options`; there is no plugin point | C |
| Exporter as a custom backend | it sees post-legalize AIR, and adding a backend edits more upstream files than the hook | C |
| `--verbose-air` on release compilers | 0.16/0.17 accept it and print nothing (exit 0); 0.18 rejects it | C |
| `ast-check -t` (typed ZIR) | rejected on every release binary | C |
| LLVM IR or C as the primary source | ReleaseFast deletes overflow checks and still exits 0; one Debug function is about 250K lines of C; LLVM verifiers are pinned to LLVM 5-18 while Zig 0.18 needs 23 | C |
| Reusing the compiler's AIR printer for schema v1 | its writer is private and the text has no result types | B, D |
| Fuzzy patching (`patch -F3`) | hunks "succeed" with no anchor at all | the earlier canary incident |
| Reading the active union field by reflection | bare unions have no tag type, so the shape must come from doc comments plus a snapshot | B |
| Hashing only the output directory into the cache key | deleting and reusing the directory means a silent cache hit with no export | A |
| Upstream accepting a plugin or a stable dump | no such proposal; the last change moved the dump into a stripped debug log | C |

The reference class is Kani, Verus, Creusot and Charon on rustc. All of them pin a toolchain and port per release, and a single-nightly bump has needed codegen edits. A per-release port budget is normal for this class of tool. Ours is now measured in lines, not days.

## Side findings to act on

1. **A real bug on master:** the cache key hashes only the output directory, so `rm -rf out && zig-zv build` exports nothing and reports success. Fixed by A's nonce.
2. **zmoltcp doesn't compile on 0.18-dev:** 17 sites of `a << b | c` are now an "ambiguous operator precedence" error. That is a free, cheap heads-up before 0.18 ships; parenthesize them now.
3. **Schema v2 candidates (B):**
   - order the `types` table deterministically;
   - add a structured form next to printer-formatted `val` strings;
   - expose `branch_hints` and flags;
   - stop embedding InternPool ids in generated names (A saw `__func_828` vs `__func_831`).
4. **Possible upstream contribution (D):** one header line in `Air.Print` (file, declaration line, module, return type) would make the stock debug dump nearly enough on its own. Any upstream PR must follow Zig's contribution policy, which needs checking before anyone drafts it. A human should own that decision.
5. **Local tree hygiene:** `C:\Users\hotschmoe\zr\zig-0.18-dev` is a partial clone with a possibly damaged pack. Re-clone it fully before using it again.

## Adoption plan (pending review)

1. Adversarial review of this design by a different model family.
2. Merge A (rules, 2-line hook, nonce) into master, plus the coverage assertion in the canary.
3. Merge B (reflection dump and normalizer). Keep `adapter.zig` as the CI oracle until a golden v1 corpus is committed, then retire it.
4. Add D's `air_text` plus `golden.sh` to the weekly canary as the independent oracle.
5. Update the fork policy in docs/design.md: rules instead of a diff, version knowledge outside the compiler, and the four tripwires.
