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

This paragraph has been corrected after review (REVIEW.md F4), so that each claim names its run:

- **Track A:** the 0.17 export is byte-identical to today's exporter on the corpus (27 functions). On `examples/search.zig` only 2 functions were compared, via `zig-zv test`.
- **Track B:** byte-identical on the corpus, on `search.zig` (9 functions, all pub functions reached through `tools/air_all.zig`), and on zmoltcp (6194 functions, 619,706 instructions).
- **Track D:** its parser matches the hook on 24 of 27 corpus functions, and on only 5 of 13 `search.zig` files (std callees included).
- **Canary:** the Linux runs passed on both branches against the nightly.
- **Not measured:** case E, design rule 4 (binaries identical to stock), the nonce under 0.17/0.18 `zig build`, and the snapshot in CI.

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
4. **Upstream is closed:** one header line in `Air.Print` (file, declaration line, module, return type) would make the stock dump nearly enough, but Zig's Strict No LLM / No AI Policy rules out an AI-assisted contribution (see the review outcome).
5. **Local tree hygiene:** `C:\Users\hotschmoe\zr\zig-0.18-dev` is a partial clone with a possibly damaged pack. Re-clone it fully before using it again.

## Review outcome (REVIEW.md, Grok 4.7, adversarial)

I verified the load-bearing findings myself before accepting them.

| Finding | Severity | Accepted | Consequence |
| --- | --- | --- | --- |
| F1. The nonce is a salt. Every exporting `zig build` misses the whole cache, incremental mode never calls it, and it hashes options even when export is off | High | yes (verified in `export.zig`: `options.hash` runs before the `out_dir` check) | Replace it with **restore-on-hit**: store the JSON in the cache artifact directory and copy it out on a hit. Measure on 0.18 `zig build`, `--watch` and `-fincremental`, including deleting the out dir |
| F2. Doc-comment shapes already disagree with the code (`save_err_return_trace_index`: Sema writes `ty_pl` at Sema.zig:6084, `typeOf` ignores `data` at Air.zig:1826), and the snapshot repair step copies the parser's output back into itself | High | yes | **Reflection is shelved.** The hand adapter stays as the production decoder. Its compile errors on renames are the loud failure we want |
| F3. The Track D "oracle" never looks at the hook: `golden.sh` compares the parser with its own earlier output | High | yes (verified) | Wire a real comparison of hook JSON against the parsed dump on the same file (tag set, instruction count, `loc`, with an allowlist). The weekly debug build comes only after one measured `ubuntu-latest` run of RSS and disk |
| F4. Overclaims in this file | Medium | yes | corrected above |
| F5. Pin-and-port with the hand adapter was cheaper on the one real AIR break (40 lines vs 97). Upstreaming is closed | Medium | yes | Zig's README (0.18-dev, lines 487-493) has a **Strict No LLM / No AI Policy**: no LLMs for issues, patches or bug-tracker comments. We will not contribute to Zig upstream, and we will not suggest it |
| F6. The riskiest adoption step was merging the nonce first | High | yes | resequenced below |

The review could not break:
- `ZV_AIR_OUT` passing through `zig build` (no environment whitelist);
- the printer and the hook being separate decoders;
- both anchors typechecking on the nightly;
- "no AIR tag changes between 0.17.0 and ae9a8acc7";
- `-fno-emit-bin` bypassing the cache.

## Revised adoption plan

1. **Measure before any merge.** Prototype restore-on-hit. Then:
   - run it on 0.18 `zig build`, `--watch` and `-fincremental`, including the delete-and-rebuild case;
   - run the rule 4 comparison (stock vs patched binaries, export off and on);
   - make hook hashing a no-op when export is off.
2. **Merge Track A's mechanism**: `zv_hook` rules, environment-only options, the 2 anchors, plus restore-on-hit. These parts of A weren't contested.
3. **Canary gets the coverage assertion** (corpus: 27 functions, about 1083 instructions, 0 unsupported) and the real hook-vs-dump comparison, run on the hook compiler it already builds.
4. **Keep `adapter.zig` and the pin.** Port per release, assisted by the canary.
5. **Next research item:** a generator that emits an explicit adapter switch from Sema `addInst` sites, `Air.typeOf` and the Liveness operand arms. Its output is checked against those switches in the same compile, so the result is the hand adapter, regenerated. Reflection over doc comments is recorded as a dead end for production use.
6. **Update the fork policy in docs/design.md only after steps 1-3 have run.** Rule 4 stays.
