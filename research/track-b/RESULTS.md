# Track B: adapter design (what we export, where version knowledge lives)

Branch `research/track-b`. All numbers below were measured on this machine (Windows 11, 24 cores, builds through the shared lock) unless marked unverified. Upstream: 0.16.0 (`24fdd5b7`), 0.17.0 (`7647adab`), 0.18.0-dev.738+ae9a8acc7 (the full checkout at `C:\Users\hotschmoe\zr\zig-0.18-dev`; the src-only master tree was used only for the first read of print.zig).

## Recommendation

Replace the 454-line hand decoder with a **reflection dump in the compiler plus an out-of-compiler normalizer**, and keep the schema v1 output byte-identical.

1. In the compiler: `reflect.zig` + `shapes.zig` (about 550 lines, no per-tag code) emit a raw, near-AIR dump. The only per-tag knowledge is 15 override entries in `shapes.zig`; everything else is read from Air.zig itself (doc comments, `Unwrapped*` helpers, `extraData` payload structs).
2. Outside the compiler: `norm/norm.zig` (Zig, 488 lines, reads rules at run time) + `norm/<ver>.zon` (85 lines). Rules are keyed by *shape* (`bin_op`, `ty_pl/StructField`, ...), not by tag name, so tag renames and new tags need no rule edit. Porting a release is a rules edit that takes seconds and no compiler rebuild; building the normalizer itself takes 11 s and running it over all of zmoltcp takes 3 s.
3. Three cheap tripwires, all implemented and demonstrated below: `shapes.snapshot` (comptime, loud), `norm --strict` (unconsumed raw field is an error), and a golden-corpus diff in the canary (done by comparing against the hand adapter during the transition; afterwards against a checked-in golden).
4. Keep `adapter.zig` as the CI oracle until a golden v1 corpus is checked in, then delete it.

Be honest about what the evidence says. On 0.17 -> 0.18-dev **nothing changed in any design** (Air.zig changed only cosmetically), so that path does not separate the designs. On 0.16 -> 0.17 the reflection code needed *more* changed lines in the compiler (97 vs 40) because `@typeInfo` was reshaped in 0.17, but all of them were mechanical API plumbing, found in two 10-second type-check rounds, and none touched tag knowledge; the tag-level churn (14 renamed/removed/added names at 11 sites in the adapter) cost the new design 0 edits. The design's own weak point is silent drift through stale doc comments (adversarial case C); the snapshot tripwire closes it.

## Gate (task 3): byte-identical schema v1

`raw dump + norm` against the hand adapter's output, same compiler binary, `diff -r` on the whole output directory (file names embed a content hash, so equal names imply equal bytes), normalizer run with `--strict`:

| Zig | input | functions | instructions | bytes | result |
| --- | --- | --- | --- | --- | --- |
| 0.17.0 | `research/corpus/corpus.zig` | 27 | 1083 | 116,594 | identical |
| 0.17.0 | `examples/search.zig` (via `tools/air_all.zig`) | 9 | 429 | 45,932 | identical |
| 0.17.0 | zmoltcp `src/root.zig` direct check | 6194 | 619,706 | 73,870,935 | identical |
| 0.18-dev | corpus / search / zmoltcp | 27 / 9 / 6194 | 1083 / 429 / 619,706 | same | identical, rules file copied unchanged from 0.17 |
| 0.16.0 | corpus (reference = hand adapter ported to 0.16) | 27 | 1082 | n/a | identical |
| master (CI, Linux, same commit as 0.18-dev) | corpus | 27 | n/a | n/a | identical (canary run 40805907968, 14 min total) |

Notes: zmoltcp does not compile on 0.18-dev (17 sites of `a << b | c`, "ambiguous operator precedence"), so the 0.18 run used a copy under `b-work/zm18` with those sites parenthesized by `zmoltcp-fixprec.pl` (one site by hand). The original repo was not touched. zmoltcp on 0.16 and `search` on 0.16 were not attempted (they need 0.17 language features). Byte-identity was achievable for every field; see "Schema v2" for the two places where it is the wrong goal.

## Metrics

Port columns count lines changed (removed + added, from `diff`) in our files. "Hook" is `compiler/hook.patch`: 12 lines in 3 files; `git apply` and the build accepted the *same* patch on 0.16.0, 0.17.0 and 0.18-dev (port diff 0 for every design).

### Path 1: 0.16.0 -> 0.17.0 (replay)

| Metric | A. hand adapter | B. reflection dump + normalizer | C. compiler printer text |
| --- | --- | --- | --- |
| compiler-side code | 454 lines (`adapter.zig`) | 341 (`reflect.zig`) + 211 (`shapes.zig`, of which 29 are the tripwire) + 223-line `shapes.snapshot` | 3 lines (`air.write` call) + build flag |
| out-of-compiler code | 0 | 488 (`norm.zig`) + 85 (rules) | not built (analysis tool `txtcmp.zig`, 148 lines) |
| hook lines / port | 12 / 0 | 12 / 0 | 12 / 0 |
| port diff, in-compiler adapter | 40 (21 removed, 19 added): tag-list edits on about 9 lines (the 0.16 -> 0.17 renames `bitcast`, `intcast`, `intcast_safe`, `struct_field_val`; removed `bool_and`, `bool_or`; 16 new tags), `pt` vs `zcu` for `Type.fmt`/`fmtValue`, `@intFromEnum` -> `@backingInt`, `Ref` vs `Type` in `arg.ty` and `arrayLen` | 97 in `reflect.zig` (51 removed, 46 added) + 2 in `shapes.zig`: all `@typeInfo` reshape (`.fields` -> `field_names`/`field_types`, `.decls` -> `decl_names`, `.params` -> `param_types`), `pt` -> `zcu`, `@backingInt`, `.toType()`; 0 edits for tags | 1 (`write(pt)` -> `write(zcu)`) |
| port diff, out-of-compiler | 0 | rules: 1 functional line (`param_ty_path`, 0.16 stores `arg.ty` as a Ref, which needed a 5-line `as_type` addition in `reflect.zig` while building for 0.16); `norm.zig`: 0 | n/a |
| port diff, shared `export.zig` | 6 | 6 | 6 |
| compiler rebuilds for the port | 1 full build (390 s) after 9 type-check rounds | 1 full build (419 s) after 2 type-check rounds | 1 |
| type-check rounds (`-Dno-bin`, 9 to 26 s each) | 9, one error per round (switch items are reported one at a time) | 2 (3 errors, then clean) | 1 |
| failure quality | loud and local: `adapter.zig:194:50: enum 'Air.Inst.Tag' has no member named 'div_ceil'`; `switch must handle all possibilities` with the unhandled tag listed | compiler errors loud and local (`reflect.zig:223:55: no field named 'fields' in struct 'lang.Type.Union'`). Normalizer errors are runtime and loud but one was badly attributed (`norm: missing i`, no tag or function; strict mode names tag, field and rule) | build-time assertion if the flag is missing |
| coverage (0.17, 3 inputs) | 125 of 224 tags exercised, 0 unsupported | same 125 exercised; 224 of 224 tags resolve to a shape (163 from doc comments, 35 inherited via "Same as `X`", 10 by naming convention, 15 overrides, 1 other); 0 unresolved, 0 `shape:null` in any input | tags, ids and operand refs only |
| coverage (0.16) | 98 tags in corpus, 0 unsupported | same; 214 tags resolve | n/a |
| wall time of the port | dominated by lock queue plus one 390 s build; edit effort about 10 minutes of type-check rounds | same build, 2 short rounds, then rules edit in seconds | n/a |

The normalizer claim, measured: editing a rules file needs no rebuild of anything; the 0.16 -> 0.17 rules edit was one line. Rebuilding `norm.zig` (needed only if its code changes) is 11 s; running it over zmoltcp (6194 files, 119 MB raw -> 74 MB v1) is 3.0 s.

### Path 2: 0.17.0 -> 0.18.0-dev.738+ae9a8acc7 (live, no known answer)

| Metric | A. hand adapter | B. reflection + normalizer | C. printer text |
| --- | --- | --- | --- |
| hook lines / port | 12 / 0 | 12 / 0 | 12 / 0 |
| port diff (adapter / reflect / shapes / export / rules / norm.zig) | 0 / n/a / n/a / 0 / n/a / n/a | n/a / 0 / 0 / 0 / 0 / 0 | 0 (the `Air.write` alias survives) |
| rebuilds | 1 (442 s, needed to get a binary) | same binary | same binary |
| type-check rounds | 1, clean in 18 s | same | same |
| failure quality | nothing failed | nothing failed | nothing failed |
| silent-drift check | hand adapter output on 0.18 is identical to B's | identical | tags/ids/operand refs identical |
| coverage | 6194 fns, 619,706 insts, 0 unsupported, 111 tags (zmoltcp) | same | same |

Hindsight check: the 0.18 rules file, `reflect.zig`, `shapes.zig`, `adapter.zig` and the normalizer were all frozen from the 0.17 work before 0.18 was first built; the first 0.18 run was the result shown. I had read the Air.zig and print.zig diff (about 80 lines, cosmetic: `print.zig` renamed to `Print.zig`, `fminq` -> `fminf128`) beforehand. Since A also costs 0, this path is a non-event for all designs. `norm.zig` also compiles unchanged on the 0.18-dev host std.

## Task 1: comptime-reflection raw dump

Can a generic dumper walk `Air.Inst.Tag` and `Air.Inst.Data` and emit every instruction with zero per-tag code? **Yes for tags and for everything reachable by type, with one gap that has three workable fixes.**

- Tags: `@tagName(tag)` is all the dump needs. A new or renamed tag is *a new string in the output*, never a compile error (unlike the hand adapter's exhaustive switch). A new tag whose Data field cannot be determined is emitted as `"shape":null,"raw":[w0,w1]` and the normalizer fails loudly for it (none occurred).
- The gap: `Air.Inst.Data` is a bare `union`, so which field is live for a tag is not in the types (verified: `@typeInfo(union{...}).@"union".tag_type == null`; in safety builds the hidden tag cannot be queried either). The dump needs a tag -> field map. Three ways, all tried:
  1. **Doc comments of Air.zig via `@embedFile`, parsed at comptime** ("Uses the `bin_op` field", "Same as `X`", "payload is `Bin`"): resolves 163 + 35 = 198 of 224 tags in 0.17 (155 + 30 of 214 in 0.16). Cross-checked statically against print.zig's own grouping for 159 tags (`writeBinOp`, `writeUnOp`, `writeNoOp`, `writeTy`, `writeTyOp`, `writeArg`): 158 agree, 1 differs (`save_err_return_trace_index`: docs say `ty_pl`, the printer says no operands; the adapter treats it as no operands; harmless but a real doc/code disagreement).
  2. Naming convention (a field named like the tag: `dbg_stmt`, `reduce`, `prefetch`, `repeat`, `atomic_load`, ...; a trailing `_N` inherits from `_0`): 10 tags.
  3. A small table: 15 entries in `shapes.zig` (`trap`, `breakpoint`, `dbg_empty_stmt`, `unreach` -> `no_op`; `err_return_trace` -> `ty`; `set_err_return_trace` -> `un_op`; `struct_field_ptr_index_0` -> `ty_op`; `dbg_var_ptr`/`dbg_var_val`/`dbg_arg_inline` whose `pl_op.payload` is a string index; `select`, `mul_add`, `slice_elem_ptr`, `ptr_elem_ptr` -> `Bin`; `aggregate_init` -> element list).
- Payload types for `ty_pl`/`pl_op` tags (the "extra" data): from the doc ("payload is `X`"), else by naming convention (CamelCase of the tag, `_weak/_strong/_cold` stripped, matched against Air's declarations), else by **reflecting over Air's own `unwrap*` helpers** (any function whose return type is `Unwrapped<P>`: Block, DbgInlineBlock, Call, CondBr, Try, TryPtr, Asm, Switch). Then `air.extraData(P, ...)` or the helper is walked generically. Payload struct *methods* returning enums (`successOrder`, `failureOrder`, `op`, `ordering`, `compareOperator`) are also discovered by reflection and emitted, which removes the bit-twiddling the adapter had to know about.
- Bodies (block, loop, cond_br, try, try_ptr, dbg_inline_block, switch_br): free, because the helpers' fields of type `[]const Air.Inst.Index` are recursed as instruction lists. The one special case is the switch (an iterator, `iterateCases`): about 20 lines.
- InternPool values and types: used the compiler's own printers (`Type.fmt`, `Value.fmtValue`, `zigTypeTag`) rather than reflecting over `InternPool.Key`. Reflecting over the Key union was not attempted: it has dozens of variants with embedded pool indexes, and two printer calls cover all of it and match the hand adapter byte for byte. Two exceptions are handled generically by type: an `InternPool.Index` that is a function gets `{fqn, module, path, line0}`; an interned *type* value gets `as_type` (needed on 0.16, where `ty_pl.ty` is a Ref).
- Liveness: not used.
- What fell short and still needs hand knowledge: the shape overrides above; the switch iterator; how to name the file/line of an inline callee (comes from the function-typed `InternPool.Index` rule); shuffles take `zcu` as a third helper parameter and are reported `"unresolved":true` (the adapter also marks them unsupported).
- Compile-time cost: the comptime doc parse adds no visible time (0.17 full build 419 s, 0.18 442 s, 0.16 343 to 390 s; the baseline pin is "about 8 minutes").
- Runtime cost, zmoltcp direct check (6194 functions, 0.17, Windows): no export 1.27 s; hand adapter 3.5 s; raw dump 3.8 s; printer text 3.2 s. Raw output 119 MB, v1 74 MB, text 38 MB.

## Task 2: reusing the compiler's printer

- **Reuse is possible only as text.** `Air/print.zig`'s `Writer` struct is file-private and writes straight to a `*std.Io.Writer` with `print`/`writeAll`; there is nothing to wrap but the byte stream. `Air.write` is callable from the hook (done: 3 lines) but is `comptime assert`ed behind `enable_debug_extensions` (0.16, 0.17), so the compiler must be built with `-Ddebug-extensions=true`.
- Stability: 0.16 `write(air, stream, pt, liveness)`; 0.17 `write(air, stream, zcu, liveness)` (print.zig diff 278 lines, nearly all `@backingInt` and new tags); 0.18-dev and master: file renamed `Air/Print.zig`, a `Printer` struct with a `format` method, `Air.write` kept as an alias, assertion now `build_options.log_level == .debug`, and **`--verbose-air` / `verbose_air` are gone** (no occurrence in `src/` of the 0.18-dev checkout). Replacement: `std.log.scoped(.@"illegal-air" | .@"legal-air" | .air).debug("{f}", .{&ap})` in `Zcu/PerThread.zig`, enabled with `--debug-log <scope>` in a build made with `-Dlog=debug` (that is also what `-Ddebug-extensions` implies by default). Our hook calling `Air.write` compiled unchanged on 0.18-dev.
- What the text gives: `tools`-style analysis `norm/txtcmp.zig` pairs each v1 file with the text of the same function and compares ids, tags and instruction operand refs: **0 mismatches over 1083 + 429 + 333,194 instructions** (3454 of 6194 zmoltcp functions had a unique name on both sides; the rest were skipped, not failed).
- What it cannot give: the result type of an instruction (not printed), the type/value split of constants (`<u32, 5>` is ambiguous to parse), callee fqn (prints `function 'returnError'`), file/line of inlined callees, generic flag, source file table. Schema v1 cannot be built from it; a text-based schema would have to drop `ty`.
- Verdict: not a primary source. Useful as an independent, free CI oracle for the instruction graph (ids, tags, operand refs) in the canary; not wired into the workflow yet.

## Task 3: normalizer

Done and gated (table above). Choices: Zig (not Python, which is not even installed on this machine, so `tools/air_read.py` could not be run; see unverified), `std.json.Value` for input, `std.zon.parse` for the rules, `Stringify` for output. Rules are keyed by shape; tag-keyed rules are possible and used for nothing. The 0.16 rules differ from 0.17 by one line. The `unsupported` list (12 tag names: `legalize_*`, `inferred_alloc*`, `shuffle_*`, `wasm_*`, `work_*`) is the only tag-name list left outside the compiler, and a stale name there is harmless.

Quirks the normalizer has to reproduce for byte-identity (they are properties of the adapter's traversal, not of AIR): type ids are assigned in encounter order, with switch ranges registered before items and before the case body; the type of an instruction registers after its bodies; `callees` lists calls and inlines in encounter order with duplicates; `loc` is the nearest preceding `dbg_stmt` carried across nested bodies and restored only after inline blocks.

### Schema v2 proposal (not implemented)

Byte identity was the right gate for the migration, but two things in v1 are accidents of the old decoder and should change in a v2: (1) the `types` table order depends on traversal quirks; sort it by first appearance in a documented pre-order, or key types by name; (2) `val` strings are the compiler's printer output and will change when the printer does; add a structured form (`kind` + integer or name) alongside the string. Also worth adding for free from the raw dump: `branch_hints`, `flags`, and the `Unwrapped*` fields the adapter drops.

## Task 5: silent drift

Two end-to-end cases on a real mutated compiler (`adversarial/mutate.sh`, tree `b-work-m`, full build 432 s), plus two from the real history.

| Case | Mutation | A. hand adapter | B. reflection + normalizer |
| --- | --- | --- | --- |
| A. operand added | `Air.Bin` gains `mask: Inst.Ref = .none` (every producer still compiles) | compiles; output byte-identical to pristine, so the new operand is **silently dropped** | lenient: silent, output identical; `--strict`: **7 of 27 functions fail** naming `payload.value.mask is not covered by rule ty_pl/Bin` |
| B. payload field renamed | e.g. `StructField.field_index` -> `index` (checked by reading both, not built) | compile error at the use site, loud | raw has `index`; the normalizer stops with `missing payload.value.field_index` (loud, at normalize time) |
| C. doc rot | the doc of `add` says `un_op` while the code is unchanged | immune (the code names `bin_op`) | **silently wrong**: `add` loses its second operand, 6 of 27 functions differ from the adapter, and `--strict` does not notice (the rule accepts all of `data`). Caught by the golden diff and by `shapes.snapshot`: `error: shape of AIR tag 'add' changed: snapshot has bin_op/-, Air.zig now gives un_op/-` |
| D. real: 0.16 -> 0.17 renames and new tags | 4 renames, 2 removed, 16 added | one compile error at a time, 9 rounds | 0 edits; new tags flow through by shape |
| E. a tag moves to another Data field in code only (not built; a ReleaseFast exporter reads the wrong union field) | n/a | **silent garbage** (untagged union) | doc-derived shape follows the doc, so silent only if the doc is also stale (same as C) |

Verdict: both designs have silent-drift holes; they are different holes. The adapter's hole is "new data is ignored" and "wrong union field read after a code-only move" (nothing catches either at build time). The reflection design's hole is "shape comes from prose" (C), closed by the snapshot, and "a rule consumes all of `data`" (strict does not see through it).

Cheap tripwires, status:
1. `shapes.snapshot` + comptime check (done): an existing tag whose derived field/payload changes stops the build with the tag name; new/removed tags pass. Demonstrated on the mutated tree in a 10 s type-check.
2. `norm --strict` (done): unconsumed raw fields are errors; each rule lists the fields it deliberately ignores.
3. Golden corpus diff (done in the canary against the hand adapter; checking in a golden v1 corpus, 27 files, 116 KB, is the next step and is what lets `adapter.zig` be deleted).
4. Tag-set hash assertion (not done: it would fail on every release, which is the adapter's exhaustive switch again).
5. Text oracle (`txtcmp`): ids, tags, operand refs from the compiler's own printer (not wired in).

## Task 4: benchmark record

| Step | Result |
| --- | --- |
| 0.16.0 build, hook ported by hand | no port needed: the 12-line patch applied and compiled unchanged. Builds: 390 s, then 343 s after the `as_type` change (full builds) |
| 0.16 adapter port (status quo reconstruction) | `adapter.zig` from 0.17 made to compile on 0.16: 9 type-check rounds, 40 diff lines, output equals B's on the corpus |
| 0.17.0 build | 419 s, status 0 (no `max_rss` complaint with this build line); needs `-Dversion-string=0.17.0` when the tree is not a git checkout |
| 0.18-dev build | 442 s, status 0, `-Dversion-string=0.18.0-dev.738+ae9a8acc7` |
| canary `gh workflow run canary.yml --ref research/track-b` | run 40805907968: success on Linux in 14 min against master `0.18.0-dev.738+ae9a8acc7`: normalizer built with 0.17.0, zig-zv built from the master commit, corpus exported, `norm --strict` output identical to the hand adapter's. The workflow on this branch was changed to do exactly that (and to use `research/track-b/build.sh master`) |

## Dead ends, with evidence

1. **Active union field from types alone.** `@typeInfo` of the bare `union` has `tag_type == null`; no way to ask which field is live. Forced the doc-comment/convention/override scheme.
2. **`std.StaticStringMap` for the override table.** `StaticStringMap(Shape).initComptime` with values containing a union with slice payloads makes host 0.16.0 `zig` die with exit code 253 (0xC00000FD, stack overflow) and no diagnostic, even for a single `get("add")`. Reproduced standalone with `zig test`. Replaced by a plain array scan. Cost: a bisect of about a dozen type-check runs, because the failure is silent and misplaced (the crash shows no file or line).
3. **Doc inheritance cycle.** `struct_field_ptr_index_0` with no doc stripped to itself and recursed forever; found only through a depth guard that turns it into a compile error. Fixed.
4. **Cloning upstream with `--filter=blob:none` from a local path**: more than 10 minutes with no progress on Windows. `git archive` of the pinned ref takes seconds; the build script uses it. (Also: 0.17's `build.zig` fails with `package "" configuration failed: FileNotFound` without a `.git`; `-Dversion-string=` fixes it.)
5. **Printer reuse as a structured source**: see Task 2. The Writer is private and prints no result types.
6. **Generic reflection over `InternPool.Key`**: not tried (see above), recorded as a decision, not a failure.
7. **Strict mode that lists only "fields not named in the rule"** misses case C by construction (a rule that consumes the whole `data` value). The snapshot, not strict mode, covers it.
8. **A normalizer error without context**: `norm: missing i` (0.16 `arg.ty` was a constant object, not a type) did not name the tag or function. Fix: wrap errors with function name and tag; not done.

## Unverified

- `tools/air_read.py` was **not run** (no Python on this machine). Equivalence to what it validated in Phase 1 rests on byte-identity with the hand adapter output only.
- 99 of 224 tags never occur in the corpus, search or zmoltcp (assembly, cmpxchg, cmp_vector, select, shuffles, c_va_*, wasm, work_*, legalize_*, loop_switch_br, `*_optimized`, ...). For them the shape is checked statically against print.zig for the simple groups (158 of 159 agree) but the payload paths (for example `Asm`, `Cmpxchg`, `VectorCmp`, `AtomicRmw` rules) were not exercised end to end.
- 0.16 was checked on the corpus only; `search` and zmoltcp need 0.17.
- The 0.18-dev zmoltcp run used a mechanically parenthesized copy; the copy was not diffed against a human fix.
- Wall time of the port is not measured end to end: queue time on the shared lock dominated (up to about 10 minutes per build slot), so only per-step times are reported.
- The canary run was dispatched before the snapshot tripwire commit; the tripwire passes a local check on 0.17 and 0.18-dev but was not part of that CI run.
- Windows: the two-line check `zig-zv build` through `tools/zv_air.sh` was not used; all runs are direct `test -fno-emit-bin` checks.

## Files

- `compiler/<ver>/zv_air/`: `adapter.zig` (hand decoder, kept for the oracle), `reflect.zig`, `shapes.zig`, `shapes.snapshot` (0.17, 0.18), `export.zig` (writes v1, raw and text depending on `ZV_AIR_OUT`, `ZV_AIR_RAW`, `ZV_AIR_TEXT`); `compiler/<ver>/hook.patch` (identical for all three).
- `norm/norm.zig`, `norm/{0.16,0.17,0.18}.zon`, `norm/txtcmp.zig`.
- `build.sh VER [check]`, `check.sh`, `run.sh VER corpus|search|zmoltcp OUT`, `zv_options.zig`, `adversarial/mutate.sh`.
