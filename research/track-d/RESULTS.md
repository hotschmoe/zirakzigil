# Track D: is a zero-patch exporter viable?

Question: build stock upstream source with an upstream flag, dump AIR text through the official debug path, and turn it into schema v1 out of tree.

Answer in one line: **partly.** The text carries 99.5% of the corpus instructions exactly, and the parser survives 0.17 -> 0.18-dev with no grammar change. It cannot reach byte-identical schema v1, because the text omits the file, the declaration line, the module name, the return type, some result types, and the full callee name. It also leaks legalization on 0.16 and 0.17. Verdict at the end.

Everything below was run on this machine. Work trees: `C:\Users\hotschmoe\zr\d\z16`, `z17`, `z18` (0.18 is a robocopy of the read-only tree, because `git clone` of it died with `git-pack-objects died ... possible repository corruption`; the copy is clean at ae9a8acc7). Hook baseline: `zig-zv` built from `tools/build_zig_zv.sh` for 0.17.0 at `C:\Users\hotschmoe\zr\d\zv`.

## 1. The three stock compilers (no source edits)

All `-Dno-lib -Denable-llvm=false -Doptimize=ReleaseFast`, through the build lock.

| Compiler | Extra flag | Build time | Peak RSS | Binary |
| --- | --- | --- | --- | --- |
| 0.16.0 | `-Ddebug-extensions=true` | 370 s | 8.14 GB | 24.9 MB |
| 0.17.0 | `-Ddebug-extensions=true` | 426 s | 8.89 GB | 25.3 MB |
| 0.18.0-dev.738+ae9a8acc7 | `-Dlog=debug` (alone) | 440 s | 10.45 GB | 30.5 MB |

Each build ends with the known `memory usage peaked at ... exceeding the declared upper bound of 8.00GB` error and an installed, working binary (same tolerance as `tools/build_zig_zv.sh`). 0.18 goes 2.4 GB over the declared bound, further than the other two; a 16 GB runner is not enough headroom if two builds overlap.

ReleaseFast is allowed. `build.zig` uses the two options only to set `build_options.enable_debug_extensions` / `log_level` (0.17: lines 259-260, 399-400; 0.18: 263-264, 411-412); nothing else forces Debug. In 0.18 `-Dlog=debug` is enough; `-Ddebug-extensions` is not needed.

Runtime cost, corpus compiled with `zig test -fno-emit-bin`, mean of 5 runs on a warm machine:

| Compiler | ms |
| --- | --- |
| stock 0.17 | 222 |
| 0.17 + debug-ext, `--verbose-air` | 1105 (5x) |
| zig-zv hook, 0.17 | 238 |
| stock 0.18 | 218 |
| 0.18 `-Dlog=debug`, no scope | 244 |
| 0.18 `--debug-log illegal-air` | 303 (1.4x) |
| stock 0.16 / 0.16 `--verbose-air` | 383 / 1189 |
| `air_text` parse of the 0.17 dump | 31 |

The 0.16/0.17 flag makes the compiler run codegen for every function (`dump_air` in `PerThread.zig:2296` 0.16, `:2306` 0.17), which is the 5x. In 0.18 the print sits inside `runCodegenInner` (`PerThread.zig:4540`) and the gate is `comp.bin_file != null or any scope enabled`, so the cost is only the printing. The dump is 12 MB for a 216-line corpus because nothing filters std: 2060 (0.16), 2086 (0.17), 2089 (0.18) functions, 27 of them ours.

## 2. Text churn

Corpus dumps are committed in `dumps/` (corpus functions only). Full dumps are 12 MB and stay out of git.

**Determinism.** Two runs of the same compiler give identical bytes on all three. A function's text is never interleaved with another's (the print holds the stderr lock). `-j1` vs default: identical in 0.18; in 0.16 only the generic-instance ids differ (`print__anon_2265` vs `print__anon_2267`), because they are InternPool indices. Those ids also change between versions (`__anon_66841` in 0.16, `__func_830` in 0.17/0.18). The hook's fqn has the same property.

**0.16 -> 0.17**, corpus functions, liveness annotations normalised away: 175 changed lines of ~1250.

| Area | Change |
| --- | --- |
| Tag names | `bitcast` split into `bit_cast`, `ptr_cast`, `int_from_ptr`, `ptr_from_int`, `error_cast`; `intcast(_safe)` -> `int_cast(_safe)`; `bool_and/or` -> `bit_and/or`; `struct_field_val` -> `agg_field_val`. New: `array_to_vector`, `shl_exact`, `legalize_vec_store_elem`. Over all 2000+ functions, 20 tag names differ |
| Names in types | `builtin.StackTrace` -> `lang.StackTrace`; generic suffix `__anon_N` -> `__func_N` |
| Types | `*align(L:C:4:3) f32`-style alignment printing appeared |
| Header, nesting, `dbg_stmt` (`line:col`, relative to the declaration), operand syntax, `<ty, val>` constants, `@.name` static refs | unchanged |

**0.17 -> 0.18-dev**, same normalisation: 30 changed lines of ~1250, all explained by two things.

1. The 0.18 dump is **pre-legalize** and has no liveness (`illegal-air`). The 0.16/0.17 dump is **post-legalize with liveness**: `!` marks, `%N! %M!` death lines, `} %N!)` trailers, branch-hint words. The corpus function `casts` shows it: the hook (pre-legalize) has `int_from_float_safe`, the 0.16/0.17 dump has an expanded `block` of `cmp_lte`/`cmp_gte` plus `int_from_float`. 26 of 27 corpus functions have identical (id, tag) sets between the hook JSON and the 0.17 dump; `casts` is the one legalization changed. A target whose backend legalizes more (wasm, SPIR-V) would diverge much more. This is the first dead end: **on 0.16 and 0.17 the official dump cannot reproduce the hook's pre-legalize AIR.**
2. Framing: `# Begin Function AIR: fqn:` ... `# End Function AIR: fqn` became `debug(illegal-air): "fqn":` with a quoted fqn and no end marker; the `# Total AIR+Liveness bytes` stats block remains.

Also: `__opaque_200` became `__opaque_0`; `__struct_827` became `__struct_830`.

## 3. Information content versus schema v1

Everything the instruction stream needs is printed: id, tag, operand ids, constants as `<ty, val>` (same value text as the hook), static refs, nested bodies with their kind, switch items and ranges, `br`/`repeat` targets, `dbg_var` names, atomics' orderings. What is missing or ambiguous:

| Field | In the text? | How the prototype gets it | Residual loss |
| --- | --- | --- | --- |
| source file, module name | No | `--module NAME=FILE` plus `--file-module` on the command line | The compiler's name for the root module (`test`, `root`) is not derivable; the fqn prefix is the file stem, not the module name |
| declaration `line` | No (`dbg_stmt` is relative to it) | parse the source with `std.zig.Ast`, index fn/test decls by fqn | Generic type members (`zv.Ranged(0,50).lit`) are not in the index: line 0. 3 of 13 functions in `examples/search.zig` |
| per-inst `loc` | Needs the line above | base line + relative line | Wrong in inline bodies whose callee is unresolved |
| `ret` | No | type of the first `ret*` operand | Wrong for a function that only ever returns `noreturn`, or whose return coerces |
| `generic_instance` | No | name suffix `__func_N` etc. | A user name ending in `__func_5` fools it |
| callee fqn | **No: `(function 'short')` only** | unique match among the dump's other fqns, else the caller's container, else a unique decl in the sources | Inline-only callees never get a body in the dump. In `search.zig` 11 callees stay unresolved (all `std.testing.*`, whose fqn is `testing.expectEqual` with no `std.` prefix and sits behind an `@import` chain) |
| result `ty` | Printed for ty_op, ty_pl, `arg`, `alloc`, blocks | inferred from operands, `fn` types, `E!T`, pointers | Unknowable: `agg_field_val`, `struct_field_ptr` (field types need struct layout), `union_init`, `field_parent_ptr`, `select`, `cmp_vector`. 3 of 1083 corpus instructions, 1699 of 225666 over the whole dump (0.75%) |
| type `kind` | No | classify the printed text; named types via the source index | Generic types, aliases and `@typeInfo(...).tag_type.?` give `unknown` (1 of 305 on the corpus, 19 of 160 on `search.zig`) |
| type identity | No | by printed name | Two distinct types with one printed name merge |
| std module filter | **No** | allowlist of module prefixes | std fqns have no `std.` prefix (`Io.Writer.print`, `debug.FullPanic((function 'defaultPanic')).outOfBounds`), so a user module cannot be told from std except by a list |
| `zig_version` | No | command line | |
| per-function files | One stderr stream | split on the framing | |
| `assembly` | Printed, not parsed | counted as `unsupported` | 14-18 in whole dumps |

The parser mimics the hook's traversal so that the `types` table order matches (operands, then nested bodies, then the instruction's own type; params, then ret). That is what makes byte identity possible at all.

## 4. The prototype

`air_text.zig` (Zig 0.17, ~1450 lines after `zig fmt` spreads the tag table), `compare.py` (field-by-field diff against hook JSON), `golden.sh` (tripwire), `dumps/`, `base17/` (the hook's JSON for the corpus on 0.17, the oracle), `golden/0.18.0-dev/` (snapshot of the parse of the 0.18 dump).

```
zig test -fno-emit-bin --verbose-air research/corpus/corpus.zig 2> d17.txt        # 0.17, debug-extensions build
air_text --zig-version 0.17.0 --module corpus=research/corpus/corpus.zig --file-module test --out out d17.txt
```

Against `zig-zv` on the corpus, 0.17.0:

| | |
| --- | --- |
| functions byte-identical to the hook | 24 of 27 |
| instructions exact (tag, ty name, operands, attrs, loc, bodies) | 1078 of 1083 |
| type kind correct | 302 of 305 |
| the 3 non-identical functions | `casts` (legalization; 2 instructions, plus 2 callees the legalized code added); `area` and `fnPointers` (`agg_field_val` result type, 3 instructions) |

On `examples/search.zig` (modules `search` and `zv`), 0.17.0: 5 of 13 byte-identical, 589 of 749 instructions exact. The misses are the inline `std.testing.expectEqual` callee (unresolved, so its inlined lines are located against the wrong base) and the generic `zv.Ranged(..)` members. zmoltcp was not run: it is multi-file, and the prototype's source index follows no `@import` chains. Its fidelity is therefore unmeasured.

Grammar coverage with every function parsed (`--all`, std included), strict mode, zero parse errors: 2060/2060 (0.16, `--legacy-tags`), 2086/2086 (0.17), 2089/2089 (0.18-dev); 212,713 / 225,666 / 224,335 instructions.

**Port diff for the live path.** Pointing the 0.17 parser at the 0.18 dump: 0 grammar changes. The only 0.18-specific code is the log framing in `splitDump` (6 lines). I wrote that framing after reading the 0.18 header, not after a failing run, so call it "6 lines, planned". The parse of the 0.18 dump of the corpus differs from the 0.17 parse in only: generic ids, the version string, and `casts` (pre-legalize in 0.18, so it now matches the hook's shape). For 0.16 text: 9 lines of tag renames plus the `--legacy-tags` plumbing; the `bitcast` split cannot be undone from the text alone (the 0.17 tag depends on the operand kinds), so a 0.16 parse is schema v1 with a different tag mix, not the hook's.

## 5. Silent drift and tripwires

The parser is strict by construction: unknown tag, unknown static ref, unbalanced bracket, wrong operand count, unknown branch-hint word and a malformed closer are all errors that print the dump line and the instruction. Counters printed on every run: `unknown_ty`, `callee_unresolved`, `callee_ambiguous`, `decl_unresolved`, `kind_unknown`, `unsupported`, `failed`, `loc_suspect`. `loc_suspect` checks that each `dbg_stmt` `line:col` lands on a non-blank byte of the source. `golden.sh` runs the compiler and parser and byte-compares with committed golden JSON.

Adversarial edits to the real 0.17 corpus dump:

| Change | Result |
| --- | --- |
| A. tag `ptr_cast` renamed `ptr_cast_unchecked` | **Loud:** `UnknownTag at dump line 293762` |
| B. `dbg_stmt(L:C)` printed `C:L` | **Silent exit 0.** 985 `loc` values and 229 `attrs` wrong. `loc_suspect` = 165 of 235 statements, so a statistical catch; the golden check catches all of it |
| C. `add_wrap`/`sub_wrap`/`mul_wrap` operands printed rhs-first | **Silent.** 13 operand lists wrong, 18 files differ. Only the golden check catches it |
| D. constant `<ty, val>` printed `<val: ty>` | **Loud:** `BadOperand` with the instruction's head |
| E. a new word in a `cond_br` hint list | Loud after adding the closed hint list; **silent before** (the first version skipped hints) |

The honest summary: syntax changes are loud; meaning changes in a position-compatible form (B, C) are silent, and only a golden corpus finds them. Unlike the hook, there is no compiler-side invariant to lean on. `golden.sh` must run on every nightly bump, and the corpus must exercise every tag family that matters.

## 6. Hybrid

- **Cache hash.** With `build-obj` and a cache, `--verbose-air` / `--debug-log illegal-air` still print on a second, cache-hitting invocation (tested: 1 and 1). A `-fno-emit-bin` invocation is never cached. The hook's cache-hash edit therefore buys nothing for the direct commands; under `zig build` a step-level cache hit would still skip the child compile. Not tested.
- **`zig build` in 0.18** forwards `zig build --debug-log illegal-air` to every compile step as an official option (`lib/compiler/Maker/Step/Compile.zig:605`), so a whole project can be dumped with no wrapper. Whether the flag is part of the step's cache key was not checked. In 0.17 the equivalent was not tried.
- **One header line would close most of the gap.** Printing file path, declaration line, module name and return type in the dump header (one `w.print` in `printVerboseAir` in 0.17, `Air.Print.format` in 0.18; they live in different files and the file was renamed `print.zig` -> `Print.zig`) would remove the source parse, the `ret` heuristic and the module guess. It is 1-3 lines in one file, with no flag and no cache edit. It does not fix callee names (those come from `Value.fmtValue`), field result types, or the 0.16/0.17 legalization leak. I did not build it.
- **CI cost.** The `-Dlog=debug` 0.18 compiler does not build faster than the hook's (440 s, 10.45 GB). It is built once per upstream commit and cached by commit hash. A run costs 1.4x the stock compile plus the parse. On 0.17 the dump costs 5x.

## Metrics

| Metric | 0.16.0 -> 0.17.0 | 0.17.0 -> 0.18.0-dev.738+ae9a8acc7 |
| --- | --- | --- |
| hook lines | 0 | 0 |
| port diff | hook mechanism 0. In-compiler adapter 0. Out-of-compiler: 9 lines (tag renames) + 9 plumbing lines for 0.16 text; going the other way, 12 new tag names would be `UnknownTag` errors, about 12 table lines | hook mechanism 0. In-compiler 0. Out-of-compiler: 6 lines of framing, 0 grammar. The two builds differ only by `-Ddebug-extensions=true` vs `-Dlog=debug` |
| rebuilds | 1 stock-with-flag build per version (370 s, 426 s), 0 caused by the port | 1 (440 s), 0 caused by the port |
| failure quality | Loud and local (dump line plus instruction) for syntax. Silent for position-compatible meaning changes (B, C above) | Same. The 0.16/0.17 flag compiled into a release compiler prints nothing and exits 0 (Track C); the 0.18 scope without `-Dlog` warns |
| silent-drift risk | High without the golden check (operand order, `line:col` order). Medium with it. 0.16/0.17 text is post-legalize, so a backend change alters the AIR with no error | Lower: 0.18 prints pre-legalize, the hook's own point. Format change risk unchanged |
| coverage | Corpus: 1099 instructions parsed, 0 unsupported, 3 with unknown `ty`. Whole dump: 225,666 instructions, 18 unsupported (`assembly`), 1,699 unknown `ty` | Corpus: 1083, 0 unsupported, 3 unknown `ty`. Whole dump: 224,335, 14 unsupported, 1,711 unknown `ty` |
| wall time | Not timed precisely; roughly 3 h elapsed, much of it queued on the lock and the clone. Compute: three builds, 20 min | The live port itself: minutes (run, compare, golden) |

## Dead ends

- **`git clone` of `zig-0.18-dev` through `file://`**: `error: git upload-pack: git-pack-objects died with error ... aborting due to possible repository corruption on the remote side`. Worked around with robocopy. Not investigated further; the source tree at `C:\Users\hotschmoe\zr\zig-0.18-dev` may have a damaged pack.
- **Post-legalize dump on 0.16/0.17**: see section 2. Not fixable without a source edit.
- **Filtering std by fqn prefix**: not possible (section 3).
- **Recovering callee fqns from the text alone**: not possible for inline-only callees.
- **Recovering `agg_field_val` result types from the text**: needs the struct layout.
- **Skipping unknown hint words** (first draft): silent; replaced by a closed set.

## Verdict: zero-patch versus the hook

Zero-patch exporting is **viable on 0.18-dev and later as a lower-fidelity, versioned variant of schema v1**, and **not viable as a drop-in replacement** for the hook:

- It never produces the exact schema v1: 24 of 27 corpus functions and 1078 of 1083 instructions match on a toy corpus; on a real example with an inline std callee and generic types, 5 of 13 files and 589 of 749 instructions. The unrecoverable items (module name, generic member lines, std callee names, field result types, type identity) are structural.
- On 0.16 and 0.17 it dumps post-legalize AIR, so the instruction stream itself can differ from the hook's. Only 0.18's `illegal-air` is the hook's point.
- It needs a stock compiler rebuilt per release with a debug flag (8 min, up to 10.5 GB), the same cost as the hook's build. It saves the hook's per-release anchor work and nothing else.
- Its port cost is very low (0-6 lines per version here) and its failures are mostly loud. That is real. But a text parser is exposed to silent meaning changes that a golden corpus must catch; the hook is exposed to compile-time breakage that is loud.

Recommendation: keep the hook (tracks A and B decide how) as the source of truth, and keep `air_text` plus `golden.sh` as an **independent oracle and canary** run against each nightly: it needs no patch, it exercises the compiler's own printer, and a divergence in tag set, instruction count or `loc` between the hook's JSON and the parsed dump flags a hook that silently stopped matching upstream. The cheapest upgrade of this route is the one-line header change in section 6; the hook-free path is worth reconsidering if upstream adds file and line to that header.

## What I could not verify

- zmoltcp (multi-file; no `@import` chasing in the prototype).
- The one-line header hybrid: not built.
- `zig build` with `--verbose-air` (0.17) and whether `--debug-log` is part of the step cache key (0.18).
- Linux: no canary was run (`gh workflow run canary.yml` was not triggered; this track adds no patch to apply).
- Targets other than the host x86_64 Windows backend; legalization differs by backend and the 0.16/0.17 leak was measured on only one.
- The kind/identity merging on projects with two types printing the same name.
- A 0.16 hook baseline (no `zig-zv` for 0.16 was built), so the 0.16 parse is compared only against the 0.17 parse.
