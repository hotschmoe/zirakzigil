# Track A: hook mechanism

Question: how do we hook into the compiler so a release (or a nightly) needs close to zero hook changes, and a break is loud and local? Track B owns the exporter; the adapter is only touched as far as needed to compile.

Everything here was measured on Windows with `zig-zv` built `-Denable-llvm=false -Doptimize=ReleaseFast`. Raw logs and scripts are in this directory and in `C:\Users\hotschmoe\zr\a-work` (logs `log-*.txt`, trees `t/`, `adv/`).

## Recommendation

Use the rule inserter with the **minimal hook** in `compiler/hook/rules.zon`:

| Rule | File | Anchor | Inserted |
| --- | --- | --- | --- |
| export-call | `src/Zcu/PerThread.zig` | text: `var air = try pt.analyzeFuncBodyInner(func_index, reason);`, plus `watch = analyzeFuncBodyInner` | `try @import("../zv_air/export.zig").exportFunc(pt, func_index, &air);` |
| cache-key | `src/Compilation.zig` | AST: first statement of `addNonIncrementalStuffToCacheManifest` | `@import("zv_air/export.zig").hashCache(comp, &man.hash);` |

- **2 lines, 2 files** (was 12 lines, 3 files). No `Compilation` field, no `CreateOptions` field, no `main.zig` change. Options come from `ZV_AIR_OUT` and `ZV_AIR_STD`, read lazily through `comp.environ_map`, which exists on 0.16.0, 0.17.0 and 0.18.0-dev (`export.zig: optionsOf`).
- The cache line is **not optional for `zig build`**, and the original hash is not enough. Measured: without a cache line a second `zig build` into another output directory exports nothing. With the original hash of `out_dir` and `include_std`, it works until you delete the output directory and rebuild into the same path, which exports nothing silently. `hashCache` adds a fresh random nonce to the key whenever `ZV_AIR_OUT` is set, so an exporting compile can never be a cache hit; that is the only variant that passed every probe.
- Anchors are chosen per site, not globally: text for the call (survives a rename of `analyzeFuncBody` and a function being split), AST for "first statement of function" (the text anchor `man.hash.add(zcu.error_limit);` can end up inside a conditional after an innocent refactor; the AST anchor cannot). The `watch` option makes `verify` fail if `analyzeFuncBodyInner` gains a second call site that the hook does not cover, which is the one silent-drift case no anchor can see.
- The CLI flags `--zv-air-out` and `--zv-air-std` are gone (env only). `zv_air.sh` and `zig build` integration are unaffected because children inherit the environment. `docs/phase1.md` still describes the flags; it was not edited.
- Keep `compiler/hook.patch` only as history. Do not use it as the primary mechanism.
- Pin the host compiler that builds `tools/zv_hook.zig` (it is 0.17 API: `std.zon.parse.fromSlice` and `std.zig.Ast`; it fails on a 0.16 host, compiles on 0.17.0 and on 0.18.0-dev.738).

## Benchmark

Two paths, same metrics. "Hook" = our edits to upstream files. All rebuilds are full `zig-zv` compiles unless marked type-check (`-Dno-bin`, 16 to 20 s, same semantic analysis, no codegen).

### Path 1: 0.16.0 -> 0.17.0 (replay)

| Metric | text diff (original, 629a8db) | text diff (re-anchored) | rule inserter (full 12-line equivalent) | AST inserter (full 12-line equivalent) | minimal hook (recommended) |
| --- | --- | --- | --- | --- | --- |
| hook lines / files | 12 / 3 | 12 / 3 | 12 / 3 | 12 / 3 | 2 / 2 (call only: 1 / 1) |
| applies to 0.16.0 unchanged | no (PerThread hunk) | yes, offsets up to 130 lines | yes | yes | yes |
| applies to 0.17.0 unchanged | yes (authored on it) | yes | yes | yes | yes |
| port diff, hook mechanism | would need a new patch for 0.16 | 0 | 0 | 0 | 0 |
| port diff, in-compiler adapter | 19 lines changed (0.16 shim, see below) | same | same | same | same |
| port diff, out-of-compiler | 0 | 0 | 0 | 0 | 0 |
| rebuilds | 0.16: 1 full + 10 type-check; 0.17: 1 full | | | | 0.16: 1 full (+10 type-check), 0.17: 1 full |
| full build time | 0.17 status quo build 15m13 (lock contention) | | | | 0.16: 5m33; 0.17: 10m28 (lock contention) |
| coverage (`research/corpus/corpus.zig`) | 0.17: 27 functions, 1083 instr, 0 unsupported | | | | 0.16: 27 / 1082 / 0; 0.17: 27 / 1083 / 0 |
| output vs status quo (schema v1) | | | | | 0.17 corpus and `examples/search.zig`: byte-identical to a build with the 12-line patch (sha256 match on all files) |

Only the minimal hook and the status quo (text diff, `ZV_HOOK=patch`) were fully built for 0.17. Full-equivalent rule sets were checked by applying them to each source tree and diffing the result against the patched tree (below).

### Path 2: 0.17.0 -> 0.18.0-dev.738+ae9a8acc7 (live)

| Metric | text diff (original) | text diff (re-anchored) | rule inserter (full) | AST inserter (full) | minimal hook |
| --- | --- | --- | --- | --- | --- |
| hook lines / files | 12 / 3 | 12 / 3 | 12 / 3 | 12 / 3 | 2 / 2 |
| applies unchanged | **no**: `src/Compilation.zig:163` and `src/main.zig:939` fail | yes (offsets up to 26) | yes | yes | yes |
| port diff, hook mechanism | re-anchor needed (the 88-line churn commit 5864287 did this for master) | 0 | 0 | 0 | 0 |
| port diff, in-compiler adapter | 0 | 0 | 0 | 0 | 0 |
| port diff, out-of-compiler | 0 | 0 | 0 | 0 | 0 |
| rebuilds | | | | | 1 type-check (16 s, passed) + 1 full |
| full build time | | | | | 6m27 local; CI canary 9m42 |
| failure quality | loud (git apply error naming the hunk) | silent on placement: applied with offsets, see drift section | loud or correct | loud or correct | n/a, no failure |
| coverage | | | | | 27 functions, 1083 instructions, 0 unsupported |

The upgrade to the nightly cost nothing in our files: the same rules, the same adapter, one build. Of the 27 corpus functions, 21 are identical to 0.17 output modulo `zig_version`; the other 4 differ only in InternPool function numbers embedded in names (`doNotOptimizeAway__func_828` vs `_831`, `generic__func_830` vs `_833`). That is an instability in the exporter's schema (Track B), not in the hook.

Canary: `gh workflow run canary.yml --ref research/track-a` built the matching master commit (`0.18.0-dev.738+ae9a8acc7`) successfully with the rule inserter (run 40801016206, text-anchored variant of the minimal hook; run 40802266828 repeated it with the final hybrid `rules.zon` (text call anchor with `watch`, AST cache anchor, `hashCache`): success, so the final rules build against the nightly).

### The 0.16 adapter shim (not a Track A metric)

`research/track-a/shim16.sh`: sed edits to the 0.17 adapter, 19 lines changed. What 0.16 needed: `@backingInt`/`@fromBackingInt` -> `@intFromEnum`/`@enumFromInt`; `Air.Inst.Tag` names (`bitcast`, `intcast`, `intcast_safe`, `struct_field_val`, `bool_and`, `bool_or`; the new `agg_field_val`, `div_ceil`, `ptr_cast` ... do not exist); `arg.ty` and `ty_pl.ty` are `Ref` there (`.toType()`); `Type.fmt` and `Value.fmtValue` take a `Zcu.PerThread`. Eleven iterations, ten of them 20-second type-checks. Notable: the adapter's tag switch is exhaustive, so a new or renamed AIR tag is a compile error with file:line, never silent.

## Mechanisms compared

### 1. Rule inserter (`tools/zv_hook.zig`, 496 lines, builds in 2.3 s)

Commands: `check`, `apply`, `verify`, `undo`. All rules are resolved in memory and nothing is written unless every rule resolves, so a broken rule never leaves a half-hooked tree. Idempotent and reversible: an applied rule is recognised by its inserted lines, which are stripped and the anchor re-resolved to confirm the text still sits exactly where the anchor says (`verify`); `undo` removes them (tested: zero residual diff on all four trees). Check time 24 to 48 ms per rule set (a `git apply --check` is 37 ms).

Failure output names the rule and file, and lists candidates when the count is wrong, e.g. (real output, 0.16 tree, AST rule that was too loose):

```
error: rule 'main-pass' (src/main.zig): anchor matched 2 times, expected exactly 1
  anchor: fn buildOutputType, initializer field .libc_installation
  candidates:
    src/main.zig:1024: .libc_installation = null,
    src/main.zig:3649: .libc_installation = if (create_module.libc_installation) |*lci| lci else null,
1 of 9 rules failed; nothing was written
```

When the count is 0 it lists the nearest lines mentioning the anchor's names. Text anchors compare whole lines without indentation; multi-line anchors work; `text_after` requires a preceding line (needed because `} else if (mem.eql(u8, arg, "--debug-compile-errors")) {` occurs twice in 0.16's `main.zig`).

### 2. AST-anchored insertion (same tool, anchors via `std.zig.Ast`)

Anchor kinds: `decl`, `fn_stmt` (first, last, or the statement that calls X), `container_field` (named, first, last), `init_field` (inside a function). About 125 of the tool's 496 lines. Cost: parse of a 7,000-line file is in the noise (full AST rule set: 48 ms vs 24 ms for the same rules as text).

- Robustness is real: the 0.17 parser parsed the 0.16, 0.17, 0.18-dev and older-master sources without errors; all rules in `full.ast.zon` and `min.ast.zon` resolved on all four trees with no edits.
- It fixes the failures text cannot: a decoy duplicate (below), "first statement" and "field of this struct" anchors, a hash line that lands inside a conditional.
- It breaks where text does not: function renames (`analyzeFuncBody` -> `analyzeFuncBodyImpl`) and a helper being extracted. Both fail loudly with 0 matches.
- Overkill for: a single unambiguous statement (the call). Insufficient for: an `else if` chain (no AST anchor kind expresses "a new branch here"; the flag rule needed `text_after`), and struct initializers shared by several literals (`.libc_installation` matched twice; a unique field had to be chosen by hand).
- It does not remove the need to pick the right anchor; it changes which refactors break it.

### 3. Minimal surface (what we can drop)

| Variant | Lines / files | `zig build` second run, other out dir | STD toggled | out dir deleted, same path reused |
| --- | --- | --- | --- | --- |
| call only (built, 0.16) | 1 / 1 | **0 files (silent skip)** | **0 files** | **0 files** |
| call + hash of `out_dir`, `include_std` (built, 0.16) | 2 / 2 | 2 files | 5590 files | **0 files (silent skip)** |
| call + nonce key (`hashCache`, built, 0.16) | 2 / 2 | 2 files | 5590 files | 2 files |

Probe: a one-object `build.zig` (`research/track-a/proj`, `hazard_build.sh`) run five times with shared local and global cache directories. Direct invocations are not affected: `-fno-emit-bin` and an explicit `-femit-bin=` give `cache_mode = .none` (`src/main.zig:3623`, `output_to_cache == null`), and re-running 27-function corpus exports five ways gave 27 files every time (hash-variant binary). The cache only matters when the compiler emits into the cache, which is what the build runner does.

So:
- Env-only control is fine (the `main.zig` flags are removed at no cost to `zig build`, which only ever used the environment).
- Lazy option reading is fine and removes the `Compilation` and `CreateOptions` fields.
- A one-line, one-file hook is achievable and correct for direct invocations, and wrong for `zig build` unless the caller uses a fresh cache for every run, which `tools/zv_air.sh` does for the local cache (it keeps a persistent global cache; with `ZV_AIR_STD=1` a global-cache hit of std/compiler_rt would be skipped). Cheaper than the nonce line to explain, but the failure is silent. A post-check (zero files written means error) catches total skips but not partial ones.
- The nonce line costs one more upstream line and makes the no-silent-skip property hold by construction. It disables caching for exporting compiles by design. Non-exporting compiles are unaffected.

### 4. Silent-drift analysis (constructed upstream edits on a 0.17 tree, `adv.py`, output `adv-out.txt`)

| Edit | text diff (re-anchored) | text rules | AST rules | recommended `rules.zon` |
| --- | --- | --- | --- | --- |
| decoy: a copy of the two anchor lines in a function placed nearer the old line number | **applied silently in the wrong function** (`analyzeFuncBodyTraced`) | loud: matched 2 times | correct (`analyzeFuncBody`) plus warning | loud: matched 2 times |
| call moved into a helper (anchor lines moved intact) | loud (`patch failed: PerThread.zig:2297`) | applies in the helper (correct only if the helper is the single path) | loud, 0 matches | applies in the helper; same caveat |
| call replaced by a wrapper call (`analyzeFuncBodyWrapped`) | loud | loud | loud | loud |
| function renamed `analyzeFuncBody` -> `...Impl` | applied silently (still correct) | applied | loud, 0 matches | applied (correct) |
| variable renamed `air` -> `func_air` | loud | loud | applies; inserted `&air` then fails to compile (reasoned, not built) | loud |
| the hashed line nested inside `if (comp.incremental)` | loud (context mismatch) | **applied inside the conditional: hash silently skipped** | correct (first statement) | correct |
| second caller of `analyzeFuncBodyInner` that bypasses the hooked function | **applied silently, those functions never exported** | silent | applied + warning | applied + warning (`verify` exits 1) |

Honest residue: if a refactor moves the single call into a shared helper that other paths also use, or adds a bypass that the `watch` identifier does not match (a renamed `analyzeFuncBodyInner`), no static check sees it. The detector for that is a coverage test: export `research/corpus/corpus.zig` and assert the function and instruction counts (27 / ~1083 / 0 unsupported). The canary builds but does not do this yet; its smoke test exports one function. That is the one addition I would make to CI.

## Dead ends and surprises (with evidence)

1. **Whole-patch approach on 0.18-dev.** The original `hook.patch` fails on `ae9a8acc7`: `error: patch failed: src/Compilation.zig:163`, `src/main.zig:939`. The re-anchored patch applies, but with offsets and with no check that the hunk is in the right place; the decoy experiment shows `git apply` choosing the nearest match.
2. **Single-line anchor for the flags.** `} else if (mem.eql(u8, arg, "--debug-compile-errors")) {` occurs at `src/main.zig:1723` and `:5106` in 0.16.0. Needed `text_after`. (It also occurs only once in 0.17; the ambiguity was invisible there.)
3. **AST `init_field` for `.libc_installation`**: matched twice (`:1024` and `:3649` on 0.16). Used `.clang_passthrough_mode`, which is unique in `buildOutputType`.
4. **The cache hash of `out_dir` is not sufficient**: table in section 3. The hazard is real in `zig build` and is hidden in direct runs.
5. **Probe via `-fno-emit-bin`/`-femit-bin=` shows nothing**: no cache is used there (all 10 runs exported 27 files), which is why I first thought the hash was untestable.
6. **`zig build` with the 0.17 `zig-zv` on Windows cannot link even the build runner**: `error: invalid value 512 for weak external symbol 0x5e5 ... compiler_rt.lib`. All `zig build` probes therefore ran on the 0.16 binaries. The 0.17 and 0.18 behaviour of the nonce/hash is by source reading only (`optionsOf`, `hashCache` are identical), not measured. A Linux or WSL run would settle it.
7. **`tools/air_all.zig` is 0.17-only** (`@typeInfo(...).@"struct".decl_names`); on 0.16 the corpus is exported with `zig-zv test` on `corpus.zig` itself.
8. **`tools/zv_hook.zig` does not build with the 0.16 host** (`std.zon.parse.fromSlice` takes 5 arguments there). The build script takes `ZV_HOOK_ZIG` (default `zig`).
9. **`C:\Users\hotschmoe\zr\zig-0.18-dev` is a partial clone**: `git clone` from it fails (`could not fetch 0ef6a917... from promisor remote`). Worked around by copying the working tree into the build directory.
10. **Env-switch emulation of "no hash" replaced by real builds**: I first added a test env var to `hashEnv`; since it also changes the key it would have measured nothing, so the call-only and nonce variants were built for real.

## Things I did not verify

- 0.17 and 0.18 `zig build` cache behaviour (Windows linker blocker above); `hashCache` was built only for 0.16.0, and the final hybrid `rules.zon` was apply/verify/undo-checked on 0.16, 0.17, 0.18-dev and older master and built only by the CI canary on 0.18-dev. The minimal hook with `hashEnv` was built on 0.16, 0.17 and 0.18-dev.
- That the patched compiler's binaries are identical to stock (design rule 4).
- zmoltcp export; the six-function `examples/search.zig` root (I used `zig-zv test` on the file: 2 functions).
- That `rename_var` fails to compile (reasoned).
- Export overhead of the per-function environment lookup (expected negligible; not measured).
- Wall time per port in minutes: not tracked precisely. Build times are from the logs; machine was shared (lock waits inflate 0.17: 10m28, status-quo patch build: 15m13).
- Older-master source tree in the scratchpad (a commit before `ae9a8acc7`): rules and re-anchored patch apply, original patch fails; not built.

## Files

- `tools/zv_hook.zig`, `compiler/hook/*.zon` (`rules.zon` is the recommendation; `call.*`, `min.*`, `nonce.*`, `full.*` are the compared variants), `tools/build_zig_zv.sh` (`ZV_HOOK=patch` for the old route, `ZV_RULES`, `ZV_HOOK_ZIG`, `ZV_POST`, `ZV_NO_BIN`).
- `compiler/src/zv_air/export.zig`: `optionsOf`, `hashEnv`, `hashCache`; works with both the flag hook (`zv_air_options` field present) and the env hook.
- `research/track-a/`: `adv.py` (adversarial edits), `hazard.sh` and `hazard_build.sh` (cache probes), `cov.py`, `shim16.sh`, `b.sh`, `hooktest.sh`, `proj/`.
