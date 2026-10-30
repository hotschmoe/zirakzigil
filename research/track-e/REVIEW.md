# Adversarial review of Track E

Branch `research/track-e` at `d4bab4c` (tracks `origin/research/track-e`). Question from `research/track-e/RESULTS.md`: does `tools/zv_gen.zig` emit a correct operand switch from the compiler, fail loudly on drift, and earn its size against a once-per-release hand port?

**Recommendation: park.** Keep the branch as a measurement and as an optional review diff. Do not merge the generator into the production decoder. Do not delete the experiment. The simple-prong transcription really does follow `Air/Liveness.zig` and matches the hand adapter. The safety claims and the 89% coverage claim are larger than the code supports, and under the pin-one-release policy the 0.16→0.17 port does not pay for ~600 lines of stringly AST plus 378 generated lines.

This review read `research/README.md`, `research/SYNTHESIS.md`, `research/REVIEW.md`, `research/track-e/RESULTS.md`, `tools/zv_gen.zig`, the generated `shapes.zig` / slim `adapter.zig`, `git diff origin/research/fork-flex...HEAD`, and the read-only trees `zig-0.16` and `zig-0.17` (`src/Air.zig`, `src/Air/Liveness.zig`, `src/Sema.zig`, plus `src/Air/print.zig` where the printer is the third witness). The generator was compiled from a copy and run against the live 0.17 tree and against mutated copies under `%TEMP%`. The repo and both Zig trees were not modified. zig-zv was not rebuilt, and the corpus / search / zmoltcp exports were not re-run. The "8 s type-check after one comment" measurement in RESULTS was not repeated; the tripwire that measurement hit is present in the committed `shapes.zig`.

Stock `--check` against the current `zig-0.17` tree exited 0 and printed:

```
tags 224: generated 200, manual 24; fields liveness 182 typeOf 154 sema 130; compared 173, conflicts 0
```

The committed `research/track-e/compiler/0.17/zv_air/shapes.zig` is byte-identical to that run, so its hashes (`Air.zig` `0xf7682f8345cc445a`, `Liveness.zig` `0xe01bbd69799c423c`) are the hashes of the files on disk.

---

## F1. "200 of 224 tags (89%) get generated operands" counts simple prongs

**Severity: high** (the headline coverage number).

**Evidence.** `RESULTS.md:35` says "coverage, tags with generated operands … 200 of 224 (89%)". The generator increments `generated` for every tag whose Liveness prong parses as `simple`, including prongs whose operand tuple is all `.none` (`tools/zv_gen.zig:564–566`, `tools/zv_gen.zig:210–213`, `tools/zv_gen.zig:510–512`). The live run reports `liveness_fields 182`. `200 − 182 = 18` simple tags have an empty arm and no data-field read. Those arms are `shapes.zig:116–132` (16 tags: `arg`, `alloc`, `ret_ptr`, `breakpoint`, `dbg_stmt`, `dbg_empty_stmt`, `ret_addr`, `frame_addr`, `wasm_memory_size`, `err_return_trace`, `save_err_return_trace_index`, `runtime_nav_ptr`, `c_va_start`, `work_item_id`, `work_group_size`, `work_group_id`) and `shapes.zig:136–138` (`trap`, `unreach`).

A second cut happens before `shapes.operands` is called. `adapter.zig:194–196` skips any tag whose name starts with `legalize_`, `wasm_`, or `work_`. Seven of the 200 never reach the generated arm: `legalize_vec_elem_val` (has refs), `legalize_vec_store_elem` (has refs), `wasm_memory_size` (empty), `wasm_memory_grow` (has the delta ref), `work_item_id`, `work_group_size`, `work_group_id` (empty). Exported tags whose arm is generated: 193. Of those, 14 arms emit no operands. Tags with at least one generated ref: about 179, which is 80% of 224.

The 72% instruction figure (`RESULTS.md:36`, 599,762 instructions) counts every instruction whose `shapes` arm returns `null`, including `dbg_stmt` (empty arm; line and column are the hand switch at `adapter.zig:283–287`) and the four `atomic_store_*` tags (refs generated, `order` hand-coded at `adapter.zig:292–294`). That percentage cannot be recomputed without an export. It is a count of "arm was not `Manual`", which is a real number and a weaker claim than "fully generated."

182 of 224 tags (81%) have a Liveness field or operand expression. That is the number that matches the sentence "operands come from Liveness."

**Recommendation.** Quote 182/224 for "Liveness supplied a field," and 179/224 for "an exported tag emits at least one generated ref." Keep 200/224 only with the label "simple prong vs `Manual`."

---

## F2. Simple-prong ref lists match Liveness and the hand adapter

**Severity: none.** This claim holds. Recorded so the rest of the review does not smear it.

**Evidence.** `--check` exited 0, so the committed switch is what this generator emits from the current tree. For a simple prong the emitter copies the `analyzeOperands` / `analyzeFuncEnd` tuple, drops `.none`, and applies `v1_order` (`zv_gen.zig:206–219`). The only permutation is `mul_add` with `&.{ 2, 0, 1 }` (`zv_gen.zig:14–16`). Liveness packs that prong as `.{ extra.lhs, extra.rhs, pl_op.operand }` (`Liveness.zig:699–702`). The generated arm emits `pl_op.operand, extra.lhs, extra.rhs` (`shapes.zig:328–333`). That is the hand adapter's schema-v1 order. The printer still prints Liveness order (`print.zig:507–515`, `writeMulAdd`). `select` is already `[operand, lhs, rhs]` on both sides, so it needs no perm. Ref fields of `Bin`, `StructField`, `UnionInit`, `FieldParentPtr`, `VectorCmp`, `Cmpxchg`, and `AtomicRmw` are present in the generated arms, and `.none` padding is dropped (compare `Liveness.zig:691–711` with `shapes.zig:320–345`).

`aggregate_init`'s sentinel is excluded by Liveness and by both adapters. `Type.arrayLen` is the same chain as `arrayLenIp`. The earlier review's worry on that pair is closed. `RESULTS.md` dead end 10 names `categorizeOperand`. That function is absent from `zig-0.16` and `zig-0.17` `src/Air/Liveness.zig`. The two real entry points are `analyzeOperands` (`Liveness.zig:806`) and `analyzeFuncEnd` (`Liveness.zig:869`).

**Recommendation.** Treat the simple-prong ref lists as correct against Liveness and against schema v1. The holes below are about data that is not a ref, and about tags the generator marks `Manual`.

---

## F3. Those lists are incomplete against `Air.Inst.Data`

**Severity: medium.** Shared with the hand adapter, so byte-identity still holds. The completeness claim against Air's data layout does not.

**Evidence.**

1. `save_err_return_trace_index` is exported with an empty arm (`shapes.zig:126`, grouped with the all-`.none` prong at `Liveness.zig:469–484`). Sema writes `ty_pl` twice, with the `StackTrace` type and the field index of `"index"` (`Sema.zig:6083–6088` and `Sema.zig:6284–6289`). The doc comment says the same (`Air.zig:953–955`). `typeOfIndex` returns `usize` and does not read `datas[]` (`Air.zig:1824–1827`). The printer drops it in `writeNoOp`. Schema v1 matches the hand adapter and drops a real payload. This is the hole `research/REVIEW.md` F2 already named for doc-comment reflection. The generator inherits it, and "0 conflicts" does not mention it (see F7).

2. `wasm_memory_size` is `pl_op` with `operand = .none` and `payload` = memory index (`Air.zig:917–921`, `Sema.zig:25055–25060`). `typeOfIndex` returns `usize` (`Air.zig:1830`). Liveness puts it in the empty group (`Liveness.zig:476`). `shapes.zig:124` emits `{}`. The printer prints the index (`print.zig:971–973`). The `wasm_` prefix skip means the export never sees it. `wasm_memory_grow` captures the delta ref and drops the memory index (`shapes.zig:363–366`, `Sema.zig:25082–25087`, printer `print.zig:976–979` prints both).

3. `work_item_id`, `work_group_size`, and `work_group_id` are `pl_op` with `operand = .none` and `payload` = dimension (`Air.zig:987–1001`, `Sema.zig:25404–25414`). `typeOfIndex` returns `u32` (`Air.zig:1870–1874`). Shapes emits `{}` (`shapes.zig:129–131`). The printer prints the integer (`print.zig:982–984`). The `work_` prefix skip hides the loss from export. The operand list is empty because the payload is not a `Ref`. The integer is still instruction data, and nothing in the generator flags a payload that Liveness ignores.

4. `prefetch` is `{ ptr, rw, locality, cache }` (`Air.zig:1331–1336`). Generated and hand adapters emit `ptr` and `locality` (`shapes.zig:264–267`, `adapter.zig:345`). The printer emits `rw`, `locality`, and `cache` (`print.zig:622–628`). The ref list is complete. The data layout is not. `Acc.extra` only fires for decls whose text contains the substring `extraData(` (`zv_gen.zig:524`), so a new non-ref field on `prefetch` (or on `Bin`, whose `extra` arm is empty at `adapter.zig:354`) is invisible.

5. A raw `pl_op.payload` integer is decoded only for the three hand-coded `dbg_var_*` tags (`adapter.zig:288–291`). A new tag that lands in that Liveness prong gets the operand and loses the name. `dbg_stmt`'s line and column are the hand switch (`adapter.zig:283–287`), not the generated arm (`shapes.zig:120`).

**Recommendation.** If the generator stays as a review diff, have it print every `Data` field and every `extraData` payload field that the operand tuple does not mention, per tag. An empty operand list plus a non-`no_op` write in Sema or a doc comment that names a field should be a generation failure, including for prefix-skipped tags.

---

## F4. Same-compile checks fail loudly for a narrower set than the drift table

**Severity: high.**

**Evidence.** Two clocks exist, and RESULTS blends them.

Same-compile, inside zig-zv, before anyone reruns the generator:

- Wyhash of the raw bytes of `../Air.zig` and `../Air/Liveness.zig` (`shapes.zig:8–18`, emitted at `zv_gen.zig:576–578`). Sema is not in the hash. `research/track-e/build.sh` never runs `zv_gen` (no match in that script). A Sema-only edit leaves a normal `build.sh` type-check green.
- Once `shapes.zig` mentions the new name: `Acc.field` switches on `std.meta.FieldEnum(Air.Inst.Data)` with no `else` (`adapter.zig:341–349`); `Acc.extra` `@compileError`s on an unknown payload type (`adapter.zig:365`); a new `Manual` enum value missing from `adapter.zig:198–279` fails exhaustiveness.
- The hash does not check operand lists. A generator bug that is regenerated into `shapes.zig` is blessed: the next compile hashes the same bytes the generator just hashed.

Loud only when `zv_gen` is rerun (exit 1 from `zv_gen.zig:588`): the data-field name conflict in `crossCheck` (`zv_gen.zig:441–452`).

Mutations, each on a copy of the 0.17 sources, stock `zv_gen`, exit code from the process:

| Change | Exit | What came out |
| --- | --- | --- |
| `addBinOp`'s written field `.bin_op` renamed to `.un_op` in the Sema copy only | 1 | `conflicts 20`. First printed line was `.sub_wrap: liveness=bin_op typeOf=bin_op`, citing `Air.zig:1614` and Sema sites. Summary still said `generated 200, manual 24; … compared 173, conflicts 20`. |
| Every `analyzeOperands` in the Liveness copy renamed to `analyzeOps2` (37 sites) | 0 | `generated 5, manual 219`. The five survivors are the `analyzeFuncEnd` prongs (`trap`, `unreach`, `ret`, `ret_safe`, `ret_load`). |
| `mul_add` tuple rewritten to the schema order `.{ pl_op.operand, extra.lhs, extra.rhs }` | 0 | Emitted `try a.ops(&.{ extra.rhs, pl_op.operand, extra.lhs })`. The perm ran on an already-permuted tuple. |
| `extraData` renamed to `readExtra` in both the Air copy and the Liveness copy | 0 | `a.extra(` count went from 10 in the committed shapes file to 0. `readExtra` appeared 10 times inside `const` decls. Field-index, cmpxchg order, atomic op/order, and vector-cmp op attrs all disappeared. |

RESULTS (`RESULTS.md:61–63`) calls the Sema `addBinOp` case loud and says "21+". Twenty is the count for this mutation. Variable-tag `addBinOp` sites are missed by the scanner (F6), so they do not add conflicts. The same-compile hash stays green for that mutation because Sema is not hashed and `build.sh` does not rerun the generator. "Loud" here means "loud if a person runs `zv_gen`."

The rename result matches RESULTS: the adapter would then fail exhaustiveness on 219 `Manual` kinds. That failure is loud and not local, and the generator itself has no floor (`zv_gen.zig:569–572` only checks that generated + manual equals the tag count). The `extraData` substring drop and the double permute are absent from the RESULTS table. Both exited 0.

The cosmetic-edit tripwire is real as a mechanism (`shapes.zig:16–17`). This review did not re-time it.

**Recommendation.** State the clock in the table: "fails the next zig-zv compile" versus "fails the next `zv_gen` run" versus "exits 0." Put Sema in the hash, or stop calling a Sema conflict a same-compile check. Reject a run whose `manual` count jumps. Apply `v1_order` only when the mined tuple equals the expected input order; otherwise exit 1. Key `a.extra` off the payload type in the AST, not off the substring `extraData(`.

---

## F5. The silent-drift list is missing cases that exit 0

**Severity: high.**

**Evidence.** RESULTS `RESULTS.md:56–70` lists Bin-gains-`mask` without a Liveness update, a new tag that needs an attr, Liveness-only tags, operand order, and CRLF. The following also exit 0, and several of them change the export:

1. **Sema edits on a normal build.** Covered in F4. The drift table's "loud" Sema row does not fire during `build.sh`.

2. **`v1_order` is unconditional for the tag name.** `zv_gen.zig:215–219` permutes whenever the prong's only tag is `mul_add` and the tuple has at least `perm.len` elements. There is no check that element 0 is `extra.lhs`. The mutation in F4 produced a silently wrong order `[rhs, operand, lhs]`. A future Liveness cleanup that stores schema order would be emitted backwards, and `--check` would update the hash to match.

3. **`extraData(` substring.** Inlining the call into the operand tuple, or renaming the method in both files, keeps the refs and drops every `a.extra` (`zv_gen.zig:524`). Exit 0. A new payload type never reaches `@compileError` if no decl contains that substring.

4. **Prefix rule replaces exhaustiveness.** The hand adapter failed the compile on a new tag. `adapter.zig:194–196` turns a new `legalize_` / `wasm_` / `work_` tag into `skip` before the generated switch. A new ordinary tag that falls into an existing simple prong compiles, exports Liveness refs, and hits `else => {}` for attrs (`adapter.zig:296`). RESULTS mentions the attr hole (`RESULTS.md:68`) and also presents the prefix rule as a feature (`RESULTS.md:17`). The feature is the hole: the hand switch used to be the canary for those names.

5. **No floor on the manual count.** The rename mutation is in the RESULTS table. Restated because it composes with (1): a Liveness refactor that renames `analyzeOperands` and is regenerated (the hash forces regen) produces a green generator and a wall of adapter errors, or, if someone adds `else => return .manual_unknown`, a silent dump of every tag into the hand path.

6. **`Legalize.zig` is not an input.** `main` loads `Air/Liveness.zig`, `Air.zig`, and `Sema.zig` only (`zv_gen.zig:549–551`). Tags that exist only after legalize are cross-checked against nothing except Liveness. `known_conflicts` is an empty suppression list (`zv_gen.zig:19`, consulted at `zv_gen.zig:448`). One added name turns a real disagreement into a pass.

7. **Integer payloads.** F3 items 1–3. Liveness records `.none` and the generator treats that as "no data." Sema and the printer disagree, and the generator does not look at the printer.

8. **`--check` reports the wrong path.** On a mismatch it prints `args[2]`, which is `VERSION`, not `args[3]`, the out path (`zv_gen.zig:591–595`). The exit code is still 1. The message will say `0.17.0 is stale`.

9. **A generator logic bug is self-sealing.** Regen rewrites `shapes.zig`, including the hashes. The following zig-zv compile proves the embedded files match the tree the generator just read. It does not prove the operand lists are right. There is no runtime oracle: Liveness stores death bits per slot, not the refs (`RESULTS.md:82` is correct on that point).

**Recommendation.** Extend the drift table with rows 2, 3, 4, and 7, and label row 1's existing Sema case "generation time, and only for enum-literal tags." Fail `--check` when the permuted tuple's text is not the expected source order. Scan `Legalize.zig` or stop claiming tag coverage past what Sema emits.

---

## F6. The Sema scanner misses the tags a second witness is for

**Severity: high.**

**Evidence.** `semaWrites` records a tag from a struct init only when it can see an enum literal (`zv_gen.zig:333–345`). The token walk skips a `.ident` whose previous token is `.identifier`, `.r_paren`, `.r_bracket`, `.r_brace`, or `.period` (`zv_gen.zig:341–343`). Helper calls record a tag only when the tag argument is itself an enum literal (`zv_gen.zig:387–392`). A tag stored in a variable, or passed as a parameter that is not an enum literal at the call, is invisible.

An instrumented copy of `crossCheck` (prints a tag when Liveness abstains and another source speaks, and when Liveness speaks and both other sources abstain) exited 0 with conflicts still 0. It printed 40 `ABSTAIN` lines and 21 `LIVEONLY` lines. The ones that show the filter, confirmed against Sema:

- `Sema.zig:17821` is `.tag = if (is_cold) .try_cold else .@"try"`. The dump has `@"try"` with `sema=pl_op` and `try_cold` with `sema` empty (`typeOf=pl_op`). `.try_cold` follows `)`. The same split hits `try_ptr` (`sema=ty_pl`) versus `try_ptr_cold` (`sema` empty, `typeOf=ty_pl`).
- Calls are `.tag = call_tag` after a switch into a variable (`Sema.zig:7071–7090`). No `.ident` token inside the tag expression. All four call tags have `typeOf=pl_op` and `sema` empty. They are `Manual`, so they are outside the operand generator entirely, and they are also outside the 173 (F7).
- `ret_safe` is `LIVEONLY` (`un_op`). `Sema.zig:18372–18373` is `const ret_tag = if (block.wantSafety()) .ret_safe else .ret; addUnOp(ret_tag, operand)`. `.ret` is a literal in a different site and is found. `.ret_safe` is the true branch of `if` and is dropped.
- All four `atomic_store_*` tags are `LIVEONLY` (`bin_op`). `storePtr2` writes them with `addBinOp(air_tag, ptr, operand)` (`Sema.zig:29961–29964`). The variable tag is skipped. `.store` on the other side of that `if` is a literal and is found. The addBinOp mutation in F4 therefore cannot see a Sema-only change of the atomic-store data field, even on regen.

Current operands for these tags happen to match Liveness, which is why `--check` is green. The cross-check did not verify them. A Sema-only change of the call payload field, of `try_cold`, of `try_ptr_cold`, of `ret_safe`, or of any `atomic_store_*` field stays silent on regen: Liveness still names its field, Sema names nothing, `views.items.len` stays 1 (`zv_gen.zig:447`).

`RESULTS.md:74` says "only 130 of 224 tags have a literal `.tag` or helper call." The live run's `sema 130` matches that sentence. The sentence undersells the mechanism: the missing 94 are not only "tags passed through variables." The scanner also drops the true arm of `if (cond) .tag_a else .tag_b`.

**Recommendation.** Record every `.ident` token in a tag expression, including those after `)`. When the tag expression is a variable, follow it to the switch that defines it and record each arm, or fail the run for that tag and say the witness abstained. Do not count an abstention toward "compared."

---

## F7. "173 compared, 0 conflicts" treats abstention as agreement

**Severity: high.**

**Evidence.** `crossCheck` adds a tag to `compared` when at least two of {Liveness field, typeOf field, Sema field set} are non-empty (`zv_gen.zig:445–446`). It counts a conflict only when the distinct field names number more than one (`zv_gen.zig:447–449`). A source that does not read `data` abstains. Abstention is not a vote for "no field."

`182 − 21 LIVEONLY = 161` tags have a Liveness field and at least one agreeing partner. The other `173 − 161 = 12` compared tags have no Liveness vote. The dump shows typeOf and Sema naming the same field for: `alloc`, `ret_ptr`, `assembly`, `block`, `@"try"`, `try_ptr`, `shuffle_one`, `shuffle_two`, `aggregate_init`, `err_return_trace`, `runtime_nav_ptr`, `c_va_start`. Several of those are `Manual`. The cross-check on them is "both sources name `ty_pl`" (or `ty`, `pl_op`, `ty_nav`). It does not check the hand arm's operand list.

`save_err_return_trace_index` is the live example of a disagreement the counter hides. Sema says `ty_pl` (`Sema.zig:6084`). Liveness has no field. `typeOfIndex` does not read `data`. `n_sources` is 1. It is absent from the 173, and it is exported empty (F3).

The 21 `LIVEONLY` tags, one witness, excluded from the 173: `cmp_lt_optimized`, `cmp_lte_optimized`, `cmp_eq_optimized`, `cmp_gte_optimized`, `cmp_gt`, `cmp_gt_optimized`, `cmp_neq_optimized`, `dbg_var_ptr`, `dbg_var_val`, `is_null`, `is_null_ptr`, `is_err`, `is_err_ptr`, `ret_safe`, `memset_safe`, `memmove`, `atomic_store_unordered`, `atomic_store_monotonic`, `atomic_store_release`, `atomic_store_seq_cst`, `legalize_vec_store_elem`. RESULTS names this class with the examples `ret_load` and `dbg_stmt` (`RESULTS.md:69`). The atomic stores and `ret_safe` are in it because the scanner missed a real Sema write, which is a different fact from "Sema never writes this tag."

`trap`, `breakpoint`, `ret_addr`, `frame_addr`, `dbg_empty_stmt`, and `unreach` abstain with `sema=no_op`. That is an empty payload, not a disagreement.

Calls, `cond_br`, `switch_br`, `loop_switch_br`, `br`, `loop`, `repeat`, `switch_dispatch`, and `dbg_inline_block` are outside the 173 or are in it only as a field-name agreement. The helpers that actually read their fields (`analyzeInstCondBr`, `analyzeInstSwitchBr`, `analyzeInstBr`, `analyzeInstLoop`) are never parsed. The reject list (`zv_gen.zig:21`) sends any prong mentioning `inst`, `a`, `ip`, `pass`, or `zcu` to `Manual`. That part of RESULTS dead end 4 is accurate, and it means the 28% of instructions RESULTS flags as hand-written are also the instructions the cross-check does not look at.

**Recommendation.** Print the abstain list and the single-witness list in the generator's report. Require two non-abstaining sources for any tag that is exported. A Sema `ty_pl` (or `pl_op`) against a Liveness empty arm should be a conflict, which would turn `save_err_return_trace_index` into exit 1 today.

---

## F8. Byte-identity is plausible, and `diff -r` cannot see the shared omissions

**Severity: medium** (claim strength). The structural reading supports identical output. This review did not re-run the exports.

**Evidence.** `git diff` between `research/track-e/baseline/0.17/zv_air/export.zig` and `research/track-e/compiler/0.17/zv_air/export.zig` is empty. The writer is the same schema-v1 printer. For every simple group, `shapes.zig` emits the same ref order and the same `a.field` / `a.extra` calls as the 0.17 hand switch, after the `mul_add` permutation already in the committed file. `Manual` arms in `adapter.zig:198–279` are the hand decoder (bodies, callee names, `aggregate_init` length via `arrayLen`). The prefix set matches the hand "unsupported" bucket. `a.field` on `bin_op` / `un_op` / `ty_op` / `ty_pl` / `pl_op` is a no-op (`adapter.zig:343`), and `a.extra(Air.Bin)` is a no-op (`adapter.zig:354`), so those calls cannot change JSON.

Shared omissions are identical on both sides: prefetch `rw` and `cache` (F3), the `save_err_return_trace_index` payload (F3), wasm and work integer payloads (prefix-skipped on both). `diff -r` over the output directory does not observe them. Byte-identity is evidence that the generator reproduced the hand adapter, including the hand adapter's drops.

The corpus counts (0.17: 27 functions / 1083 instructions; 0.16: 27 / 1082) differ by one instruction, which is the right shape for a version difference in one file. Search at 9 functions / 429 instructions matches the Track B `tools/air_all.zig` setup. zmoltcp at 5974 / 599,762 with 111 tags and 0 unsupported is internally consistent with phase 1's 111-tag set (`docs/phase1-report.md:43`). None of those directories were rebuilt here.

The "4 type-check rounds versus 9" line (`RESULTS.md:31`) has no log in the branch. RESULTS already says the 0.16 hand part was derived from the 0.17 adapter (`RESULTS.md:38`), so those four rounds are a back-port of API renames, not a first port. They are not evidence that the generator is cheaper to carry onto a new Zig release.

**Recommendation.** Keep the byte-identity claim for the 5974-function set, with the sentence "identical to the hand adapter, including shared omissions." Drop the 4-vs-9 rounds from any cost argument until a log exists. Re-run `diff -r` only if the branch is proposed for merge; this review did not.

---

## F9. Under the pin-once policy the generator is the expensive artifact

**Severity: high** for the adopt decision.

**Evidence.** After `research/REVIEW.md`, the project policy is to pin one Zig release and port the hand adapter by hand once per release. SYNTHESIS step 5 asked for a generator as the next research item. Track E's own verdict is already "partial" and "adopt only if tag churn dominates" (`RESULTS.md:5–7`).

Measured with `git diff --numstat` on the Track E trees (raw line counts are `(Get-Content).Count`; `Measure-Object -Line` drops blanks):

| File | 0.16 → 0.17 |
| --- | --- |
| `shapes.zig` | 20 insertions, 10 deletions (diffstat 30). 0.16 file is 368 lines, 0.17 file is 378. |
| generated `adapter.zig` | 11 insertions, 13 deletions. Every hunk is API drift: `pt`→`zcu`, `@intFromEnum`→`@backingInt`, `arg.ty.toType()`→`arg.ty`, `ty.fmt(pt)`→`ty.fmt(zcu)`, `arrayLen` receiver, `@enumFromInt`→`@fromBackingInt`. No tag-list edits. |
| baseline hand `adapter.zig` | 19 insertions, 21 deletions (40). 0.16 is 456 lines, 0.17 is 454. |
| `export.zig` | 1 insertion, 1 deletion (`pt` in the `view` call), both trees. |

The shapes diffstat of 30 is real. RESULTS splits it as "6 header/hash lines, 24 tag lines" (`RESULTS.md:26`). The header hunk is 8 lines of the 30: version, the compared-count `162`→`173`, and both hashes, each appearing once on each side. The other 22 lines are tag edits: removed `bool_and` and `bool_or`; renames `bitcast`→`bit_cast`, `intcast`→`int_cast`, `intcast_safe`→`int_cast_safe`, `struct_field_val`→`agg_field_val`; added `div_ceil`, `div_ceil_optimized`, `bit_cast_safe`, `ptr_cast`, `ptr_from_int`, `int_from_ptr`, `error_cast`, `error_from_int`, `int_from_error`, `union_from_enum`, `array_to_vector`, `spirv_runtime_array_len`. Net tag count 214→224, which matches "162 of 214" and "173 of 224." The partition is loose. The tag list is right, and it is small.

`tools/zv_gen.zig` is 600 lines. RESULTS says 599 (`RESULTS.md:11`). Commit `e9fef67` replaced `arena.dupeZ` with `allocSentinel` plus `@memcpy` because `dupeZ` is gone in 0.17. That is the "1 line to compile on the 0.17 host," and it accounts for 600 versus 599. The 0.17-built binary cannot parse the 0.16 sources: `--check` against `zig-0.16` exited 1 with `error.ParseFailed` while loading `Air/Liveness.zig` (`zv_gen.zig:549`). RESULTS dead end 7 is confirmed. Port direction is old-host-parses-new-source, and the 0.17→0.18 direction was not tried.

What the generator removes from a port is the tag-list portion of the hand adapter, about 16 lines in this one release. What it leaves is the 24 lines of API drift, which are exactly the lines a person still types, plus a 600-line program that itself broke once (`dupeZ`) between these two releases. The generated switch is 378 lines that must be reviewed on every regen, and F4–F7 are the reasons that review cannot be "the compile stayed green."

The zmoltcp 0.18 break cited in the research notes is 17 `a << b | c` sites. That is source syntax, not AIR tag churn. It does not move the cost comparison.

**Recommendation.** Park. The next Zig pin should port the hand adapter (the 40-line class of edit) and use `zv_gen` only as a diff to read beside that port. Adopt only after the silent rows in F4–F7 fail the generator, and after a release whose tag churn is measured in more than the ~22 tag lines seen here.

---

## F10. The 6194 vs 5974 function counts

**Severity: medium** (the byte-identity sample is the later number; the cause is a hypothesis).

**Evidence.** Numbers already on disk:

| Run | Functions | Instructions | Bytes | Tags |
| --- | --- | --- | --- | --- |
| phase 1, direct `zig-zv test -fno-emit-bin` on `src/root.zig` | 6186 (1020 generic) | 617,881 | 83 MB | 111 |
| phase 1, `zig build test` | 6188 | ~618k | | 111 |
| Track B, and Track E's first generated run | 6194 | 619,706 (Track B) | ~86 MB | |
| Track E later, baseline and generated | 5974 | 599,762 | 71.5 MB | 111 |

Delta from 6194 to 5974: 220 functions, 19,944 instructions, about 14.5 MB. 14.5 MB / 220 is about 67 KB per missing file, against about 12 KB average for the 5974-file set. The missing files are about 5.5× fatter, which is what generic instances look like. phase 1's 83 MB / 6186 sits in the same band as 86 MB / 6194. The 5974 / 71.5 MB pair is the outlier. Both later binaries agree with each other, and later runs of each agree with themselves. The 111-tag count is the same on the small set and in phase 1, so the missing functions did not have to contain a new tag.

Ruled out by reading:

- `ZV_AIR_STD`. `export.zig:27` sets `include_std` from key presence, and `export.zig:42` returns before writing when the function's module is toolchain and the key is unset. Phase 1 and the 6194 runs are the no-std band. Turning std on adds functions. It does not land on 5974.
- Generator or adapter nondeterminism. The count is the number of successful `exportFunc` writes after the toolchain filter. Both later binaries, hand and generated, report 5974.
- Drift in `src/zv.zig` between the zmoltcp pin and HEAD. `zmoltcp/build.zig.zon` pins zirakzigil `d07e08cb596800426027f441b0c316d7b9ff9582`. That commit is an ancestor of HEAD, and `git diff d07e08c HEAD -- src/zv.zig` is empty. `run.sh:17` overrides the dependency with the repo's `src/zv.zig` and `research/track-e/zv_options.zig` (`ghost = false`). `build.zig` differs from the pin by 10 lines. Phase 1's `zig build test` versus direct gap was 2 functions (`docs/phase1-report.md:40–41`), so the runner difference is not 220. zmoltcp unit tests are `single_threaded = true`.

**Leading hypothesis: a dirty output directory.** `run.sh:10` now deletes `"$out/v1"` before the run. `export.zig:61–69` names a file from an 80-character sanitized stem plus a 16-hex hash of the content, and identical content overwrites. A first count that did not clean, into a directory that already held Track B's 6194-file export, reports 6194 if the new compile wrote 5974 files whose names are a subset: the overlap overwrites, and 220 stale names remain. Later clean runs of both binaries report 5974 and 71.5 MB. The arithmetic is exact, and it requires the overlap to be filename-identical, which fits "both binaries identical at 5974" plus "the first number is exactly Track B's number." Byte-identity was demonstrated on the 5974 set. It says nothing about those 220 names. This review did not find the original output directory, so this stays a hypothesis that fits every number that was written down.

**Second, weaker: the zmoltcp tree moved.** Local `git log` (no fetch) shows commits on 2026-10-28, including the v0.4.1 merge and a shift-parenthesization change of the kind that fixes `a << b | c` parsing. A reachability change can move the generic-instance count. It does not, by itself, explain a first count that lands on Track B's 6194 and a later pair of compilers that drop by the same 220 after a clean. Interop-test commits in that log would tend to add functions.

**Third, weaker: silent write drops.** `export.zig:57–58` logs `writeFile` errors and continues, so the compile succeeds and the function is absent from the directory. A stable 220-file hole, with both binaries still identical, is what that looks like. Fat generics fit long names better than a random slice. Classic `MAX_PATH` 260 is the wrong mechanism: the Windows writer uses `NtCreateFile` through `sliceToPrefixedFileW` into a `WindowsPathSpace` of `PATH_MAX_WIDE` (32767). A sharing violation that survives the retry, or a path that overflows the wide buffer, could still drop files. The unchanged 111-tag count means the hole is functions, not a tag the adapter started skipping.

**Recommendation.** On the next export, record `find "$out/v1" -name '*.json' | wc -l` after a clean, and also the count of `log.err` lines from `exportFunc`. If a dirty tree is still around, `comm` the 6194-name set against the 5974-name set; the hypothesis predicts 220 names present only in the old tree and zero names present only in the new one. Until that `comm` exists, quote 5974 as the compared set and quote 6194 as an unreproduced earlier count.

---

## Smaller claim errors

**Severity: low.** Each is a false sentence in RESULTS. None of them rescue the coverage or the drift table.

- `zv_gen.zig` is 600 lines, not 599 (`RESULTS.md:11`). The extra line is the `dupeZ` replacement in `e9fef67`.
- The Sema `addBinOp` mutation produces 20 conflicts, not "21+" (`RESULTS.md:61`).
- The shapes diff is 8 header lines and 22 tag lines of a 30-line diffstat, not "6 header/hash + 24 tag" (`RESULTS.md:26`). The tag inventory in that sentence matches the diff.
- `categorizeOperand` is not in either Liveness file (`RESULTS.md:84`).
- `--check` prints the version string on staleness (`zv_gen.zig:594`).

---

## What held up

The simple-prong path is a real transcription of `analyzeInst`, not a second copy of the doc comments that REVIEW F2 threw out. `--check` against the current 0.17 tree passes, and the committed `shapes.zig` matches it. Where two sources name a union field and the scanner sees both, they agree: the live conflict count is 0. The hand-adapter port from 0.16 to 0.17 really is about 40 lines, about 24 of them API renames the generator cannot see, and the shapes tag churn for that same jump is a few dozen diff lines. Track E already says the win is narrow. That part of the verdict is the part this review agrees with.

## Recommendation

**Park.**

Do not merge `tools/zv_gen.zig` or the generated `shapes.zig` onto the production decoder. The pin-one-release, port-by-hand policy makes the 0.16→0.17 savings about 16 lines of tag-list edits, against 600 lines of generator and 378 lines of generated switch, with Sema outside the hash, abstention counted as agreement, a scanner that drops the true arm of `if` and every variable tag, and three exit-0 ways to emit a wrong or thinner switch (`v1_order`, the `extraData(` substring, the prefix skip). Those are the properties that make "rerun the generator and review the diff" fail open.

Do not drop the branch. The Liveness transcription is the first approach in this research that reproduces the hand ref lists, and a regen diff is a useful second pair of eyes on the next hand port. The adopt condition is concrete: the F4–F7 cases exit 1 with a tag name, and a later release shows tag churn large enough that the 24 lines of API drift are no longer the dominant edit. The 0.16→0.17 numbers are not that release.
