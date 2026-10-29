# Adversarial review of the fork-flex synthesis

Reviewed `research/SYNTHESIS.md` at `05320df` against the four track reports and their code (`origin/research/track-a` `a24ed25`, `track-b` `fee0d0b`, `track-c` `5163a35`, `track-d` `3fad679`), the upstream trees `zig-0.16`, `zig-0.17`, and `zig-0.18-dev`, and a stock `zig 0.17.0` cache timing under `research/review-probes/`. Nothing here was built with the patched compiler. The Windows linker still refuses a 0.17 `zig-zv` link (`compiler_rt.lib`, weak external 512), which is the same blocker Track A recorded.

Severity is High, then Medium. Each finding is the claim, the evidence, why it matters, and the fix.

## F1. High. The nonce is a salt. It disables whole-cache hits, skips incremental, and was not measured on the compilers this fork ships.

**Claim.** SYNTHESIS.md:18 and :77. The cache key is "a nonce whenever export is on, so an exporting compile is never a cache hit," and that nonce fixes the master bug where `rm -rf out && zig-zv build` exports nothing and reports success. Track A, RESULTS.md:109, adds that non-exporting compiles are unaffected.

**Evidence.**

`hashCache` always mixes the options into the manifest, then, when `ZV_AIR_OUT` is set, appends 8 bytes from `comp.io.random`:

```54:60:research/review-probes/export-a.zig
pub fn hashCache(comp: *const Compilation, hasher: anytype) void {
    const options = optionsOf(comp);
    options.hash(hasher);
    if (options.out_dir == null) return;
    var nonce: [8]u8 = undefined;
    comp.io.random(&nonce);
    hasher.addBytes(&nonce);
}
```

`options.hash` (export-a.zig:33-36) runs on every call, including `out_dir == null`. A patched compiler therefore has a different whole-cache digest from stock even when export is off. Track A's "unaffected" sentence covers only the nonce branch.

The call site is the first statement of `addNonIncrementalStuffToCacheManifest` (Track A RESULTS.md:14). In 0.18 that function runs only for `CacheMode.whole` (`src/Compilation.zig:2787-2794`). A hit returns at `Compilation.zig:2812-2828`, before Sema, so `exportFunc` never runs. That is why a content-free salt "works": it makes the hit impossible.

It does not run for the other two modes.

- `src/main.zig:3622-3627`: `output_to_cache == null` is `.none` (direct `-fno-emit-bin`); `incremental` is `.incremental`; everything else is `.whole`. The comment above that switch says incremental is expected to become the default.
- Incremental hashes inputs at `Compilation.create` (`Compilation.zig:2278-2317`). `hashCache` is not on that path. Deleting the output directory with no source change still skips analysis. Functions that are not re-analyzed are not re-exported. Stale JSON stays, because filenames embed a content hash and the output directory is not cleaned (export-a.zig:87-95).
- `--watch` sets `watch_flag` only (`lib/compiler/Maker.zig:516`). `-fincremental` is a separate flag (`Maker.zig:560-563`). `Compile.zig:48-55` keeps the compiler process only when incremental is on and watch (or the web server) is on. A default `zig build --watch` still uses whole-cache mode, so the nonce turns every watch rebuild into a full miss. `zig build --watch -fincremental` keeps the process, snapshots `environ_map` at spawn (`Maker/Step.zig:552-554`), and never consults the nonce.

The Maker child is given the full parent map (`Maker/Step.zig:552-554`), and the digest becomes the `o/<hex>` path of every generated file (`Compile.zig:67-78`). A new nonce therefore rebuilds the compile step and every step that consumes its outputs. `lib/std/Build/Cache.zig` has no prune. Each exporting build leaves a cache entry that can never hit again.

What was actually measured:

- Track A, RESULTS.md:100-103 and :132. The nonce probe is a one-object `build.zig` on the 0.16 binaries, five runs. "The 0.17 and 0.18 behaviour of the nonce/hash is by source reading only." RESULTS.md:141 lists design rule 4 (binaries identical to stock, `docs/design.md:326`) under "Things I did not verify."
- This review, stock `zig 0.17.0`, not the patched hook. `zig build -p research/review-probes/prefix-proj --summary all test` with both caches under `research/review-probes/zcache-proj`. Cold: five `compile test debug native` steps at about 2 s each, MaxRSS 274-318M. Warm: those steps `cached` at 21-25 ms, MaxRSS 18M; the test runs were cached; the consumer step dropped from 5 s to 112 ms. Both runs together 53.16 s, 19/19 steps, 41/41 tests. A one-file object (`research/review-probes/cachecost`) was 96 ms / 78M on a miss and 17 ms / 18M on a hit. That is the hit an exporting `zig build` gives up, on this repo, on the stock compiler. `-fno-emit-bin` is `cache_mode = .none` and does not exercise this path (Track A: 10/10 corpus runs still exported).

`io.random` is a CSPRNG (`lib/std/Io.zig` and `Io/Threaded.zig`). Consuming 8 bytes can change later temporary-directory names. Those names are paths. Nobody compared stock and patched object bytes, so rule 4 is open. The nonce does change cache identity on every exporting compile, and the options hash changes cache identity on every whole-cache compile.

Two option holes sit in the same function. `ZV_AIR_STD` is "key present" (export-a.zig:28), so `ZV_AIR_STD=0` enables std export; `docs/phase1.md` says `=1`. An empty `ZV_AIR_OUT` is non-null, so the nonce is added and the writer uses a degenerate path (export-a.zig:57, :80-84).

**Why it matters.** Step 2 of the adoption plan merges this as the fix for a real bug. On every `zig build` that exports, analysis, codegen, and link run from scratch, and the cache grows without bound. The mode the compiler comments say is coming (incremental) keeps the original silent-skip bug. The measurement that justified the nonce is a 0.16 one-object probe.

**Fix.** Do not merge the nonce. On a whole-cache miss, write the JSON into the cache artifact directory next to the object. On a hit, `Compilation.update` already has the artifact directory (`man.hitDigest()` at `Compilation.zig:2822`) and returns before Sema: copy the stored JSON out to `ZV_AIR_OUT`. Deleting the out directory and rebuilding then restores the JSON without a salt and without disabling the cache. Hash the options (path and the real include-std flag), not a random nonce, so two exports into different directories still miss, and a repeat into the same directory hits. Incremental needs its own answer: the digest at `Compilation.create` must include the export options, and a missing out directory must be refilled from the incremental artifact dir, including functions that were not re-analyzed. Then run the rule 4 byte compare of stock vs patched binaries on 0.18, with export off and on. Treat `ZV_AIR_STD` as a value, and treat an empty `ZV_AIR_OUT` as off.

## F2. High. Doc-comment shapes already disagree with Air.zig. The snapshot rubber-stamps the parser and misses the dialect the file actually uses.

**Claim.** SYNTHESIS.md:19 and :49-50. Shapes come from doc comments plus 15 overrides. A doc change stops the build via `shapes.snapshot`. A tag that moves to another `Data` field in code only "follows the doc" and is silent only if the doc is also stale. Byte-identity with today's exporter (SYNTHESIS.md:24) is the evidence that this dump is faithful.

**Evidence.** The parser (`research/review-probes/shapes.zig`, Track B) accepts one field dialect and one payload dialect:

- Field: the exact substring `Uses the \`` ... `` field` (shapes.zig:140). `Uses \`ty_op\` field.` and `Uses \`pl_op\`.` do not match.
- Payload: the exact substring `ayload is \`` ... `\`` (shapes.zig:163). `with payload \`X\`` and `with the \`X\` payload` do not match.
- Overrides return before any doc read (shapes.zig:137). A doc edit on those 15 tags does not change `derive()`.
- The snapshot (shapes.zig:187-201) compares `derive()` to the previous `derive()` for tags already listed. A new or removed tag is skipped (`!@hasField` continues). The compile error prints the parser's new answer and says to update the snapshot. Pasting that answer back in is a green build. Track B RESULTS.md:152: the canary (run 40805907968) was dispatched before the snapshot commit. The tripwire was a local type-check, not CI.

These tags are in the current 0.17 `src/Air.zig`. The same sentences are in 0.16 and in 0.18-dev. `git diff` of 0.17 `Air.zig` against 0.18-dev `Air.zig` is 12 lines; the tag-name lists match. The live path did not exercise any of this.

| Tag | Doc (0.17 `src/Air.zig`) | What `derive()` does |
| --- | --- | --- |
| `block` :339 | `Uses the \`ty_pl\` field with payload \`Block\`.` | Payload dialect missed. `conventionPayload` finds decl `Block` (Air.zig:1378). The name in the doc is ignored. `loop` :347 uses `Payload is \`Block\``, which the parser does read. Same shape, two dialects, one of them parsed. |
| `call` :376 | `Uses the \`pl_op\` field with the \`Call\` payload.` | `with the \`Call\` payload` is not `ayload is \``. Saved by the `Call` decl (Air.zig:1389). |
| `slice_elem_ptr` :737, `ptr_elem_ptr` :746, `mul_add` :909, `select` :804 | `with payload \`Bin\`` or `and payload \`Bin\`` | Missed by the parser. Hardcoded in `overrides` (shapes.zig:41-44). A doc edit cannot trip the snapshot. |
| `legalize_vec_store_elem` :1011 | `Uses the \`pl_op\` field with payload \`Bin\`.` | Not an override. `LegalizeVecStoreElem` is not a decl. Payload stays `none`. The tag is on the normalizer's unsupported list (Track B RESULTS.md:95), so v1 drops it. Liveness still has an arm (`src/Air/Liveness.zig:777`). |
| `struct_field_ptr_index_0` :694 | `Uses \`ty_op\` field.` | Missing the word `the`. Override forces `ty_op` (shapes.zig:31). `_1` `_2` `_3` inherit that override by numeric suffix (shapes.zig:152-160). `typeOf` reads `ty_op.ty` (Air.zig:1762). |
| `dbg_var_ptr` :553 | `Uses \`pl_op\`.` | Not the parsed dialect. Override supplies `pl_op` plus a string (shapes.zig:38). |
| `save_err_return_trace_index` :953-955 | `Uses the \`ty_pl\` field.` | Field parse succeeds. There is no `SaveErrReturnTraceIndex` decl, so payload stays `none`. Sema writes a real `ty_pl`: the `StackTrace` type and the `index` field number stuffed into `payload` (`src/Sema.zig:6083-6088`). The printer emits no operands (`src/Air/print.zig:221`, `writeNoOp` at :372). `norm/0.17.zon:24` ignores `data.ty` and `data.payload` for a bare `ty_pl`. The raw dump had the type and the field index; the normalizer throws them away so the bytes match the hand adapter. |
| `work_item_id` :987-991 (and the two siblings) | `payload is the dimension...` with no backtick | Payload `none`. The dimension integer stays in `data` only because `keepsPayload` keeps it. The unsupported list then drops the tag. |
| `err_return_trace`, `set_err_return_trace` :944-947 | No `Uses` line | Overrides (shapes.zig:36-37) are the only reason these have a field. |

`reflect.zig:222-224` then does `const d = @field(data, fname)` on the bare `Air.Inst.Data` union. zig-zv is built `ReleaseFast` (`tools/build_zig_zv.sh:63`). A wrong field name is silent garbage in that mode. Case E in Track B RESULTS.md:113 is marked "not built". SYNTHESIS.md:50 states the reflection column as a fact.

Byte-identity does not audit this. Track B compared the normalizer to its own copy of `adapter.zig` in the same binary. `air_read.py` was not run (RESULTS.md:147). 99 of 224 tags never appear in corpus, search, or zmoltcp (RESULTS.md:148). The "158 of 159 printer groups agree" check used the printer as the authority. For `save_err_return_trace_index` the printer is the one that drops the operands Sema stored. Shared omissions pass.

The snapshot does fire when a non-override tag's parsed `Uses the \`X\` field` or `Payload is \`Y\`` string changes. Track B showed that on a mutated tree, one 10 s type-check (RESULTS.md:118). It does not fire on the dialect above, on the 15 overrides, on a new tag, or on a code-only field move whose doc is left alone.

**Why it matters.** This is the layer step 3 swaps in for the hand decoder, and then step 3 deletes that decoder once a golden corpus exists. The golden corpus is the same 27 functions. A doc edit in the dialect Air.zig already uses, or a Sema change under an override, stays green. The tripwire's repair instruction is to trust the parser that just changed its mind.

**Fix.** Keep `adapter.zig`. It fails at compile time when a tag is renamed, which is the property Track A measured (RESULTS.md:64). If a generator is still wanted, generate the switch from the code that writes and reads the union (`Sema` `addInst` sites, `Air.zig` `typeOf`, `Air/Liveness.zig` operand arms), and check the generator's output against those switches in the same compile. Stop embedding `Air.zig` and matching comment dialects. A snapshot that is updated by pasting `derive()` back into itself is not a second source. Case E has to be built in Debug or ReleaseSafe, where the bad `@field` is illegal, before anyone claims the doc path is safer than the hand switch.

## F3. High. The Track D "oracle" does not look at the hook. A weekly debug compiler on ubuntu-latest is tight, and the job as specified fails its own RSS check.

**Claim.** SYNTHESIS.md:22 and :56, adoption step 4. A stock `-Dlog=debug` compiler plus `air_text`, "run weekly in the canary and compared with the hook's JSON," catches what the hook cannot see, "because it is a separate code path (the compiler's own printer, with no patch)."

**Evidence.** Track D RESULTS.md:108: `golden.sh` runs the compiler and the parser and byte-compares against committed golden JSON. That JSON is a snapshot of the parser's own earlier output (`golden/0.18.0-dev/`, RESULTS.md:84). A hook that emits nothing still leaves `golden.sh` green.

`compare.py` does diff against hook JSON, and Track D used it. The adoption plan names `golden.sh`, not `compare.py`. Where Track D did compare, full JSON equality is already red on a correct compiler: corpus 24 of 27 functions (RESULTS.md:95); `examples/search.zig` 5 of 13 functions and 589 of 749 instructions (RESULTS.md:100). Permanent gaps Track D lists: 0.16/0.17 dumps are post-legalize while the hook is pre-legalize (`casts` is the corpus witness, RESULTS.md:55); result types the printer omits; generic member lines; `std` callee names. Track D's own recommendation (RESULTS.md:159) is a divergence in tag set, instruction count, or `loc`. SYNTHESIS.md:22 upgrades that to "compared with the hook's JSON."

The printer and the hook do not share a decode function. `reflect.zig` / `adapter.zig` read `Data`; `air_text` parses text from `Air/print.zig`. A wrong union field in the hook does not change printer text for operands the printer actually prints. They fail together where the printer omits data and the adapter omits it too (`save_err_return_trace_index` above; result types; file, line, module, return type). Track D RESULTS.md:80: the parser "mimics the hook's traversal so that the `types` table order matches." The type-table order was tuned to the hook.

CI. Track D RESULTS.md:17-19: the 0.18 `-Dlog=debug` build took 440 s and peaked at 10.45 GB RSS on a 32 GB Windows machine, and the build exits non-zero because that exceeds the declared 8 GB bound. `tools/build_zig_zv.sh:57-71` swallows exactly that error. `golden.sh` does not build the compiler, and the canary (`.github/workflows/canary.yml:17-18`) is one `ubuntu-latest` job with a 60 minute timeout. It builds the hook compiler, not a second debug-log compiler.

GitHub's hosted-runner table, fetched 2026-10-28 from the "Choosing the runner for a job" docs: public `ubuntu-latest` is 4 CPU, 16 GB RAM, 14 GB SSD. Private `ubuntu-latest` is 2 CPU, 8 GB RAM, 14 GB SSD. This repo is public, so the 16 GB row is the one the weekly job would get. 16 minus 10.45 leaves about 5.5 GB if the Windows peak transfers to Linux, which was not measured. Two overlapping compiler builds do not fit, which is the caveat Track D already wrote. The 14 GB SSD for two compiler trees plus the runner image was not measured. A second sequential 440 s build plus the existing canary (Track B run 40805907968, about 14 minutes) fits inside 60 minutes only if nothing else slips and the RSS failure is ignored the way `build_zig_zv.sh` ignores it. Nobody ran this job on `ubuntu-latest`.

**Why it matters.** Step 4 is the layer the synthesis says watches the other layers. Wired as specified, it watches the printer's parser against yesterday's parse of the printer. The hook can be wrong every week and the check stays green. The debug build is a second full compiler, in a job whose disk and RSS limits were not tried.

**Fix.** Put a real compare in the canary: same source file, hook JSON versus parsed dump, and fail on tag-set, instruction-count, or `loc` divergence, with an explicit allowlist for the permanent gaps (legalize, omitted result types). Do not byte-compare the two JSON trees. Run that compare on the hook compiler the canary already builds. Add the `-Dlog=debug` stock build only after one measured run on `ubuntu-latest` that records peak RSS and disk, in its own job, with the same max_rss tolerance `build_zig_zv.sh` already has. Until that run exists, the weekly oracle is the coverage assertion Track A asked for (27 functions, about 1083 instructions, 0 unsupported), which the canary also does not run yet (Track A RESULTS.md:123).

## F4. Medium. SYNTHESIS.md reports reasoned and partial results as measured, and it merges three different `search.zig` runs into one sentence.

**Claim.** SYNTHESIS.md:24. "Every row is backed by a run." The 0.17 output of A's hook and of B's normalizer is byte-identical to today's exporter on the corpus and `examples/search.zig`. B matched zmoltcp at 6194 functions and 619,706 instructions. "The Linux canary passed on both branches." The upgrade table (SYNTHESIS.md:34-35) gives reflection "0 edits for tag churn" and the text parser "9 lines of tag-rename table" and "6 lines of framing." SYNTHESIS.md:73: the port "is now measured in lines, not days."

**Evidence.** Rows and sentences the runs do not support:

- Case E, "a tag moves to another union field in code only." Track B RESULTS.md:113 says "not built". SYNTHESIS.md:50 states the reflection behavior as a table fact.
- Tripwires, SYNTHESIS.md:21. `shapes.snapshot` was not in the canary (Track B RESULTS.md:152). `norm --strict` on the canary compared the corpus only: the log of run 40805907968 says `norm: 27 functions, 0 failed`. The coverage assertion "the canary builds but does not do this yet" (Track A RESULTS.md:123). The golden v1 corpus is "the next step" (adoption step 3).
- "Linux canary passed on both branches." Runs 40801016206 and 40802266828 (Track A) and 40805907968 (Track B) succeeded. Track D ran no canary. The sentence is true for A and B and false if read as all four tracks. The synthesis says "both branches," which matches A and B. The table row that cites "D" for the weekly oracle was not run in CI.
- `examples/search.zig` is three measurements. Track A RESULTS.md:40 says byte-identical, and RESULTS.md:142 says the six-function root was not verified: `zig-zv test` on the file produced 2 functions. Track B RESULTS.md:23, via `tools/air_all.zig`: 9 functions, 429 instructions. Track D RESULTS.md:100: 13 functions, 749 instructions, 5 of 13 byte-identical. SYNTHESIS.md:24 treats these as one result.
- zmoltcp 6194 / 619,706 is Track B on 0.17. On 0.18 it matched only after a script parenthesized 17 `a << b | c` sites (Track B RESULTS.md:25 and :150). SYNTHESIS.md:78 records the compile break and does not attach it to the byte-identity sentence. The 0.17 number is real. "0 unsupported" on that run is 111 tags (RESULTS.md:64), not the 224-tag enum.
- Track A RESULTS.md:58. "Of the 27 corpus functions, 21 are identical to 0.17 output modulo `zig_version`; the other 4 differ only in InternPool function numbers." 21 + 4 = 25. Two functions are unaccounted for. The synthesis does not repeat the arithmetic. The track report does not add up.
- "0 edits for tag churn" (SYNTHESIS.md:34) is the tag-name list inside the hand adapter. The reflection port on the only upgrade that changed the compiler was 97 lines in `reflect.zig` plus 2 in `shapes.zig` (Track B RESULTS.md:42), because `@typeInfo` moved, found in 2 type-check rounds against the hand adapter's 40 lines and 9 rounds. Track A's 0.16 shim of that same adapter is "19 lines changed" (RESULTS.md:64), a third count of the same port. The live path is 0 for both designs because the instruction set did not change. That part of SYNTHESIS.md:39 is fair.
- "9 lines of tag-rename table" and "6 lines of framing" (SYNTHESIS.md:35). Track D RESULTS.md:104: 9 lines of tag renames plus 9 plumbing lines for 0.16, and the 6 lines of 0.18 framing were "written after reading the 0.18 header, not after a failing run" ("6 lines, planned").
- "verify fails" for a second analysis path (SYNTHESIS.md:47). Track A RESULTS.md:121-123: `verify` fails when a second call site's text still contains `analyzeFuncBodyInner`. A bypass whose identifier was renamed, or a call moved into a shared helper, is not seen. Track A calls that the honest residue.
- Rule 4, binary identity. Listed by Track A as not verified (RESULTS.md:141). The synthesis does not say it was verified. Adoption step 2 merges the hook anyway. Called out here because SYNTHESIS.md:24's "every row is backed by a run" sits two paragraphs above a design that includes that hook.

**Why it matters.** The adoption plan treats the table as measured. The live nightly did not separate the adapter designs. The historical replay separated them in the other direction on line count (97 vs 40), and the synthesis states that in caveat 2, then still recommends reflection. The `search.zig` collapse hides that the zero-patch path already disagrees with the hook on that file.

**Fix.** Rewrite the "every row" paragraph so each number names the track, the version, the input, and whether it was a run or a source reading. Split `search.zig` into the three runs. Mark case E, rule 4, the 0.17/0.18 `zig build` nonce, and the snapshot-in-CI as unmeasured. Publish the two missing corpus functions from the 21 + 4 split, or drop the split.

## F5. Medium. The alternatives the tracks set aside match the evidence better than the combined design. Upstream will not take an LLM-authored hook.

**Claim.** The synthesis picks comptime reflection, a nonce, and a weekly debug oracle. Three alternatives were in the review brief. A fourth (restore-on-hit) falls out of F1.

**Pin to an upstream commit and port in small steps.** This is already the operating model (`docs/design.md:323`, the canary, SYNTHESIS.md:11). The one measured AIR break, 0.16 to 0.17, cost the hand adapter 40 lines and 9 type-check rounds, and cost reflection 97 lines and 2 rounds, because the metaprogramming surface moved (Track B RESULTS.md:42-46). Tag churn was free only for reflection, and it was free because the parser ignores the tags it does not understand and the normalizer drops 12 names. The live nightly cost both designs 0 lines of AIR knowledge. Kani, Verus, Creusot, and Charon pin and port; Track C and SYNTHESIS.md:73 cite them as the reference class, then treat "lines, not days" as a property of the new design. A full compiler rebuild is still required when the compiler copy changes (Track B: 419 s and 442 s; the canary is about 14 minutes) even when the adapter diff is empty. Continuous ports of the 454-line hand decoder spread the 40-line break across the canary. They do not carry a 550-line doc parser (`shapes.zig` plus `reflect.zig`) whose failure mode is a stale comment.

**Generate the adapter from `Air.zig` with a script at build time.** Nobody tried this. Track B recorded "generic reflection over `InternPool.Key`" as not tried (RESULTS.md:141) and tried doc comments instead. A script that reads `typeOf`, the liveness operand arms, and the `unwrap*` helpers would re-run in seconds on all three trees and would not break when `@typeInfo` is reshaped, which is the only break reflection paid for. No single upstream switch is a complete map: `typeOf` returns `usize` for `save_err_return_trace_index` without reading `data` (Air.zig:1826), while Sema writes `ty_pl`. Generating from the printer would match Track D by construction and would remove the independence F3 asks for. Generating an explicit switch, and failing the build when a tag or a field is renamed, is the hand adapter regenerated. That failure mode is the one Track A measured as loud (RESULTS.md:64).

**Upstream a one-line hook.** The policy in the 0.18-dev tree is a ban. `README.md:487-493`, quoted in full:

> ### Strict No LLM / No AI Policy
>
> No LLMs for issues.
>
> No LLMs for patches / pull requests.
>
> No LLMs for comments on the bug tracker, including translation.

There is no `CONTRIBUTING.md` exception. The track commits are required to end with `Co-Authored-By: Claude`. The design under review was written by those models. A human would have to write any upstream patch with no LLM in the issue, the patch, or the comments. Separately, upstream commit `f08a8f0fc` (Jacob Young, 8 Oct 2026) deleted `--verbose-air` and replaced it with `--debug-log illegal-air`, which is stripped unless `-Dlog=debug` (Track C, and Track D RESULTS.md). An upstream hook behind that flag does not remove the fork for a ReleaseFast zig-zv. SYNTHESIS.md:84 says the policy "needs checking before anyone drafts it." The check is done. The policy forbids the draft these tracks could submit.

**Restore the JSON from the cache artifact.** Described in F1. It keeps whole-cache hits, fixes the delete-and-rebuild bug for `.whole`, and does not salt the manifest. It was not in any track.

**Why it matters.** The combined design adds three mechanisms (nonce, doc reflection, weekly debug parser) on top of a pin-and-port loop that already exists. The historical replay, which is the only upgrade that changed AIR, was cheaper to port by hand than by reflection, and the reflection port's cheapness on tags is the parser's blindness from F2.

**Fix.** Stay on the hand adapter and the pin. Add the coverage assertion to the canary that already builds. Replace the nonce with restore-on-hit and measure it. Revisit a generator only as a producer of an explicit switch, checked against liveness and Sema, with a human as the author if any line of it is proposed upstream.

## F6. High. The riskiest adoption step is step 2. The cache-artifact test and the binary compare come before any merge.

**Claim.** SYNTHESIS.md:87-94 orders the work as: this review, merge A (rules, 2-line hook, nonce, coverage assertion), merge B and then retire `adapter.zig`, add D's `golden.sh` to the weekly canary, rewrite the fork policy.

**Evidence.** Step 2 is the first code merge. It lands the salt in F1, which disables whole-cache hits for every exporting `zig build`, does nothing for incremental, changes the digest even when export is off, and was measured on 0.16 only. Rule 4 is still unchecked. Step 3 then replaces the hand decoder with the doc parser in F2 and deletes the hand decoder once a 27-function corpus exists. Step 4 adds a self-check of the printer (F3) and calls it a compare against the hook. Step 5 writes those three mechanisms into `docs/design.md` as policy.

The rules inserter itself is in better shape than the nonce. Both Linux canaries compiled the patched 0.18 compiler. The call anchor and the cache-key anchor typecheck. That is a reason to keep the inserter, not a reason to merge `hashCache` as written.

**Why it matters.** After step 2, every exporting build pays the full compile, and the policy file still says binaries match stock. After step 3, the only decoder that reads the union by hand is gone, and the tripwire that replaced it updates itself.

**Fix.** Before any merge: implement restore-on-hit, and run it on 0.18 `zig build`, `zig build --watch`, and `zig build -fincremental`, including `rm -rf` of the out directory with no source change. Run the rule 4 byte compare. Add the coverage assertion (27 / ~1083 / 0 unsupported) to the existing canary. Keep `adapter.zig`. Do not land `shapes.zig` until the parser is replaced by a check against liveness and Sema, and do not add the debug-log job until one `ubuntu-latest` run has recorded RSS and disk. Update `docs/design.md` only after those runs, and leave rule 4 in place.

## What I could not break

- Ordinary `zig build` does pass `ZV_AIR_OUT` through. The 0.18 Maker spawns the compiler child with `environ_map = &graph.environ_map` (`lib/compiler/Maker/Step.zig:552-554`). There is no whitelist on that path. Windows `Environ.Map` lookup is case-insensitive (`lib/std/process/Environ.zig:105-140`). I found no writer of that map during Sema, so I am not claiming a data race on the lazy read.
- The printer and the hook do not share a decoder. A wrong `Data` field in `reflect.zig` does not change printer text for an operand the printer prints. The hole is the operands the printer omits, not a shared function.
- The export anchor and the cache-key anchor typecheck on the nightly. Canary runs 40801016206, 40802266828, and 40805907968 built the patched compilers on `ubuntu-latest`.
- Between 0.17.0 and 0.18-dev `ae9a8acc7` the AIR tag set did not change. The `Air.zig` diff is 12 lines: `print.zig` renamed to `Print.zig`, and one parenthesization of the same `<<` / `|` class that broke zmoltcp. "Nothing in AIR changed" is fair for the instruction set.
- `-fno-emit-bin` uses `cache_mode = .none` (`src/main.zig:3625`) and does not consult `hashCache`. Track A's 10/10 corpus re-runs still exported. A direct test is a bad probe of the cache bug, and it is a fine probe of the exporter.
- `aggregate_init`'s doc says the sentinel is not in the element list, and `reflect.zig:237-239` uses `ty.arrayLen`. Liveness uses `arrayLenIp` for that tag (`src/Air/Liveness.zig:662-666`). I did not find an out-of-bounds read there.
- `shapes.snapshot` does stop the build when a non-override tag's parsed `Uses the \`X\` field` or `Payload is \`Y\`` string changes. Track B demonstrated that locally. The defect is the set of edits that do not change the parsed string, and the repair step that copies the parser's output back into the snapshot.
