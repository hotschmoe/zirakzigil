# Track E: generate the adapter's operand switch from the compiler's own code

Branch `research/track-e`. Question (SYNTHESIS step 5): can `tools/zv_gen.zig` emit an explicit `switch (tag)` from compiler sources, so a port is "rerun the generator, review the diff"? Benchmark: 0.16.0 -> 0.17.0 only. All numbers measured on this machine; builds went through the lock.

## Verdict: partial

It works and is byte-identical, but the win is narrow. It removes the tag-churn part of a port (16 of the hand adapter's 40 lines, and, plausibly, the one-error-per-round tag rounds: 4 rounds here against 9) and turns operand drift into a compile-time or generation-time failure. It does not touch the API-drift part (24 lines), and it adds about 600 lines of generator and 378 generated lines to maintain. Adopt it only if the release cadence makes tag churn the dominant cost; otherwise the hand adapter plus the canary stays cheaper. Hand edits per port go from 40 to 24; the 24 are the ones a generator cannot see.

## What was built

- `tools/zv_gen.zig` (599 lines, `std.zig.Ast`; builds on the 0.16 and 0.17 hosts, one line differed: `dupeZ` is gone in 0.17). Usage: `zv_gen ZIG_TREE VERSION OUT.zig [--check]`; runs in about 1 s.
- Sources mined:
  - **Liveness `analyzeInst`** (`src/Air/Liveness.zig`): per prong, the `data` field, the `extraData` payload type and the operand tuple of `analyzeOperands`/`analyzeFuncEnd`. The compiler enforces it exhaustively, so it covers all tags.
  - **`Air.typeOfIndex`**: the data field each tag's result type reads. Used only as a cross-check.
  - **Sema** (`addTy`/`addTyOp`/`addUnOp`/`addBinOp`/`addUnionInit` helpers found by AST, their call sites, and every `.{ .tag = .x, .data = .{ .field = ... } }`): the data field written. Cross-check only.
- Output `shapes.zig`: an explicit `switch (tag)` with one tag per line (reviewable diff, `zig fmt` clean), `operands(a, air, tag, data) !?Manual`. A prong the generator cannot translate becomes a `Manual` enum kind, named after its first tag, that `adapter.zig` must handle in an exhaustive switch.
- `adapter.zig` keeps what the compiler's code cannot tell us: attrs, bodies, callee names. Attrs are keyed by structure where possible: `a.field(.reduce, x)` over `std.meta.FieldEnum(Air.Inst.Data)` (exhaustive, no `else`) and `a.extra(payload)` over `@TypeOf(payload)` (`@compileError` for an unknown payload type). Only `arg`, `dbg_stmt`, `dbg_var_*`, `atomic_store_*` and `runtime_nav_ptr` are tag-keyed. "Unsupported" became a prefix rule (`legalize_`, `wasm_`, `work_`) plus 4 `Manual` kinds.
- In-compile checks: the exhaustive generated switch (no `else`), the `Manual` switch, the `FieldEnum` switch, `@compileError` on unknown payload types, and a comptime Wyhash of `Air.zig` and `Air/Liveness.zig` (`@embedFile`) that stops the build when either changed since generation. Measured: appending one comment line to `Liveness.zig` in the 0.17 tree gives `shapes.zig:17:13: error: ../Air/Liveness.zig changed since shapes.zig was generated: rerun tools/zv_gen.zig` in an 8 s type-check.
- Generation-time checks (exit 1): every Liveness tag must exist in `Air.Inst.Tag` and the prongs must cover all tags; the data field read by Liveness, `typeOfIndex` and Sema must agree. 173 of 224 tags are compared across at least two sources on 0.17 (162 of 214 on 0.16), with 0 conflicts.

## Metrics: 0.16.0 -> 0.17.0

| Metric | Hand adapter (baseline, SYNTHESIS) | Generated shapes + slim adapter |
| --- | --- | --- |
| hook lines / port | 12 / 0 | 12 / 0 (same patch) |
| generated diff, 0.16 -> 0.17 | n/a | 30 changed lines in `shapes.zig`: 6 header/hash lines, 24 tag lines (6 removed or renamed, 2 `div_ceil` added, 9 `bit_cast` group added, `array_to_vector`, `agg_field_val`, `spirv_runtime_array_len`) |
| hand edits, adapter | 40 changed lines | 24 changed lines, all API drift: `pt`/`zcu` (6), `@backingInt`/`@intFromEnum` (5 pairs), `arg.ty.toType()`, `arrayLen`, `@fromBackingInt` |
| hand edits, tag lists | about 16 lines (the 40 minus the 24 that remain; 4 renames, 2 removals, 16 additions) | 0 |
| hand edits, `export.zig` | 2 | 2 (`pt` in the `view` call) |
| generator port | n/a | 0 edits to run it on 0.17 (the 0.16-built binary parsed the 0.17 sources); 1 line to compile it with the 0.17 host |
| type-check rounds (hand part) | 9, one error per round | 4 (`@backingInt` x5; `arg.ty` and `@intCast`; `export.zig` `pt`; clean) |
| compiler rebuilds | 1 (390 s) | 1 (426 s on 0.17, 375 s on 0.16) |
| failure quality | loud and local, but one switch item per round | loud: compile errors for renames in attr arms; generation-time conflict output names tag and `Air.zig:`/`Sema.zig:` line; stale source -> `@compileError` naming the file |
| decoder size | 454 lines | 368 hand (`adapter.zig`) + 378 generated (`shapes.zig`) + 599 generator |
| coverage, tags with generated operands | 0 of 224 (all hand) | 200 of 224 (89%); 24 tags in 18 `Manual` kinds stay hand: `call*`, `block`, `loop`, `dbg_inline_block`, `br`, `repeat`, `switch_dispatch`, `cond_br`, `try*`, `switch_br`, `loop_switch_br`, `assembly`, `aggregate_init`, `shuffle_*`, `inferred_alloc*`, `legalize_compiler_rt_call` |
| coverage, instructions | n/a | in zmoltcp 72% of instructions fall in generated arms (599,762 total); 28% (`block`, `br`, `call`, `cond_br`, ...) go through hand arms |

The 0.16 hand part was derived from the 0.17 adapter (the same direction track B used for its baseline), not by a first-time 0.16 port.

## Byte-identity (schema v1)

Baseline = today's hand adapter built as `zig-zv` on each version (`research/track-e/baseline`), same hook. `diff -r` over the whole output directory:

| Zig | input | functions | instructions | result |
| --- | --- | --- | --- | --- |
| 0.17.0 | `research/corpus/corpus.zig` | 27 | 1083 | identical |
| 0.17.0 | `examples/search.zig` (via `tools/air_all.zig`) | 9 | 429 | identical |
| 0.17.0 | zmoltcp `src/root.zig` | 5974 | 599,762 | identical, 111 distinct tags, 0 unsupported |
| 0.16.0 | corpus | 27 | 1082 | identical |

Caveat: the first generated run on zmoltcp produced 6194 functions (86 MB), later runs of both the baseline and the generated binary produced 5974 (71.5 MB). Track B recorded 6194 too. I did not find the cause; the 5974-function sets are the ones compared.

Byte-identity needed one hand rule in the generator. `mul_add` is the only tag where schema v1 and Liveness disagree on operand order: v1 emits `[addend, lhs, rhs]` (the hand adapter's choice), Liveness and the printer use `[lhs, rhs, addend]`. `v1_order` in `zv_gen.zig` permutes it. The corpus contains `@mulAdd`, so a missing rule would have shown up.

## Where it silently drifts

Tested by editing copies of the 0.17 sources (`gen/mut`) and re-running the generator:

| Change | Result |
| --- | --- |
| Liveness reads `un_op` where `typeOfIndex` and Sema say `bin_op` | loud: 21+ conflicts naming tags and `Air.zig:` lines |
| Sema helper `addBinOp` writes a different union field | loud: conflict with `Sema.zig:15112`-style site lines |
| Renaming `analyzeOperands` in Liveness | generator succeeds with 5 tags generated and 219 manual; the adapter then fails to compile on every unhandled `Manual` kind (loud, not local). No floor check in the generator. |
| `Air.Bin` gains `mask` but Liveness is not updated | silent: output unchanged apart from hashes. Same hole as the hand adapter, but not realistic: Liveness must track every operand, or backends break. |
| `Air.Bin` gains `mask` and Liveness lists it | generator emits `extra.mask` in the operand list. The hand adapter would drop it silently. This is the real gain. |
| Any edit to `Air.zig` or `Liveness.zig` | build stops until the generator is rerun (also for cosmetic edits; a false positive by design) |
| New payload type or `Data` field in a generated arm | `@compileError` / non-exhaustive switch (loud) |
| New tag needing an attr (an `order`, a name) | silent: no attr emitted, not in any compiler list |
| Tag in a generated arm moves union field in code only | caught only if `typeOfIndex` or Sema also read the field; Liveness-only tags (e.g. `ret_load`, `dbg_stmt` family) have one witness |
| Operand semantic order (like `mul_add`) | silent: Liveness order is an arbitrary packing order, not a schema |
| LF/CRLF checkout | the Wyhash covers raw bytes, so a CRLF checkout fails the tripwire; the archives used here are LF |

## Dead ends and limits, with evidence

1. **Sema as an operand source**: only 130 of 224 tags have a literal `.tag = .x` or helper call with an enum-literal tag. Tags passed through variables, and tags only produced after Sema (Legalize), are invisible, so Sema can cross-check but cannot drive. It also never says which refs are operands.
2. **`typeOfIndex` as an operand source**: it gives a field for 154 tags and only the first operand; the rest return fixed types (`.bool`, `.noreturn`, `.void`) without reading `data`. Cross-check only.
3. **Liveness operand order is not the schema's order**: `mul_add` (Liveness `.{ extra.lhs, extra.rhs, pl_op.operand }`, `Liveness.zig` `.mul_add` prong; hand adapter `adapter.zig` `.mul_add`/`.select` arm: operand first). One override list entry in the generator; there may be future cases.
4. **Helper-driven prongs cannot be translated**: `call`, `assembly`, `aggregate_init`, `block`, `loop`, `cond_br`, `try*`, `switch_br`, `br` (`analyzeInstBr` etc.) go through `unwrap*` helpers and `AnalyzeBigOperands`; the generator rejects any text that mentions `inst`, `a`, `ip`, `pass` or `zcu`. These are 24 tags and 28% of exported instructions, and they carry the bodies, so they are hand code by nature.
5. **Liveness carries no attrs**: callee names, `order`, `op`, `field`, `target`, `volatile`, and `loc` handling are all outside it. Structural dispatch (`FieldEnum`, `@TypeOf(payload)`) recovers some tag-churn immunity, but the dispatch tables are hand knowledge.
6. **The generator carries hand knowledge too**: the function names `analyzeInst`, `typeOfIndex`, `analyzeOperands`, `analyzeFuncEnd`, the `inst_datas[...]` and `a.air.` rewrites, the reject list, and `v1_order`. A rename of one of them degrades silently to "all manual" (above).
7. **Ast parser direction**: the 0.17-built generator cannot parse 0.16 sources (`ParseFailed`); the 0.16-built one parses 0.17. Port direction is old-host over new-source, which works, but the 0.17 -> 0.18 case was not tested (no nightly in scope).
8. **Runtime oracle from Liveness**: `Liveness` stores only death bits per operand slot, not refs, so it cannot check the generated operand list at run time. Not attempted beyond that reading of `Liveness.zig`.
9. **`zig fmt` joins a long prong list into one line** unless each tag has a trailing comma; hence one tag per line in the output (more lines, but a tag-level diff).
10. **`categorizeOperand`** (also in `Liveness.zig`, per-tag operand index) and `print.zig` groupings are two more independent witnesses for operand lists. Not wired in.

## Reproduce

```
zig build-exe tools/zv_gen.zig                               # host 0.16 or 0.17
zv_gen C:\...\zig-0.17 0.17.0 research/track-e/compiler/0.17/zv_air/shapes.zig [--check]
sh buildlock.sh sh research/track-e/build.sh 0.17 [check]      # sources: research/track-e/compiler/VER/zv_air
sh research/track-e/run.sh ZV_BIN corpus|search|zmoltcp OUT
```
