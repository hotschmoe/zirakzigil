# Phase 1: AIR exporter

Goal: every function in a pilot codebase exports its AIR as versioned JSON, and the JSON round-trips. No analysis happens in this phase; it only produces the input that `zvc` (Phase 2) and `zv-own` (Phase 3) will read. The fork follows the fork policy in [design.md](design.md#fork-policy-stay-fast-forwardable).

## Where AIR comes from (Zig 0.17.0)

- `src/Zcu/PerThread.zig`, `analyzeFuncBody`: `pt.analyzeFuncBodyInner(func_index, reason)` returns a function's finished AIR. This is the hook point. It runs once per function instance (each generic instantiation separately) and runs with `-fno-emit-bin`, so the exporter needs no backend and no LLVM.
- The AIR here has not been legalized or run through liveness yet; those happen later, per backend, in `runCodegenInner`. That suits us: it is backend-independent and closest to the source.
- Stock release compilers can't print AIR. `--verbose-air` exists, but only in compilers built with `-Ddebug-extensions`, and its output is unversioned text. It is a useful oracle while developing, not an interface.
- Inline calls survive as `dbg_inline_block` with the callee, so `zv.requires`, `zv.ensures` and friends stay identifiable even when inlined. `dbg_stmt` carries line and column relative to the function.

## Layout

```
compiler/
  ZIG_VERSION          upstream tag and commit the hook targets
  hook/rules.zon       the only edits to existing compiler files: three inserted lines
  src/zv_air/          our files, copied into the Zig tree as src/zv_air/
    adapter.zig        the only file that reads Air / InternPool internals
    export.zig         JSON writer over the adapter's stable view
    cache.zig          options, cache key and restore-on-hit
tools/zv_hook.zig      inserts the rules; every anchor must match exactly once or nothing is written
tools/build_zig_zv.sh  fetch tag, copy src/zv_air, apply the rules, build zig-zv
```

The hook is three lines. `exportFunc` runs after `analyzeFuncBodyInner`. `hashCache` adds a salt to the whole-cache key, and only when `ZV_AIR_OUT` is set. `restore` is deferred at the top of `Compilation.update`. There are no flags and no new fields: options come from `ZV_AIR_OUT` and `ZV_AIR_STD`, read from `comp.environ_map`. With `ZV_AIR_OUT` unset, none of the three does anything, and the cache key is stock's.

Restore-on-hit: a compile that goes through the cache writes its JSON into its own artifact (`o/<digest>/zv_air/`) and, on every update, hit or miss, copies the files to `ZV_AIR_OUT`. So a cached compile step still produces the full export, deleting the output directory and rebuilding restores it, and the output directory stays out of the cache key. A direct `-fno-emit-bin` run has no cache and writes straight to `ZV_AIR_OUT`. File names embed a content hash, so copies never conflict, but the directory is a union: a function whose body changed leaves its old file behind. Clear the directory before a run that must be exact (`tools/zv_air.sh` does). `-fincremental` is unsupported and fails loudly (below). The build scripts (the project's `build.zig` and the dependencies') are never exported: `zig build` compiles it only when its configuration cache misses, so exporting it would make the set depend on that cache.

The compiler is built with `-Denable-llvm=false`. The patched compiler (`zig-zv`) is used only for export runs; shipped binaries still come from the stock compiler.

## JSON contract (schema v1)

One compact JSON file per function instance, named `<fqn>.<content hash>.json`. The hash makes generic instances with the same name distinct and the file set reproducible. Top level:

| Field | Meaning |
| --- | --- |
| `schema`, `zig_version` | 1, and the compiler version that produced the file |
| `fqn`, `file`, `line`, `generic_instance` | fully qualified name, index into `files`, 1-based declaration line, whether this is a generic instantiation |
| `params`, `ret` | runtime parameters (`ty`, `zir_index`) and the return type, as indexes into `types` |
| `files`, `types`, `callees` | the per-file tables: `{module, path}`, `{name, kind}`, and `{fqn, inlined}` for every direct call and every `dbg_inline_block` |
| `unsupported` | number of undecoded instructions |
| `insts` | the main body |

An instruction is `{id, tag, ty, operands?, attrs?, loc?, bodies?}`. `id` is the AIR instruction index and is what operands and `target` attributes refer to. An operand is `{"inst": id}`, `{"ty": type, "val": "<printed value>"}` for a constant, or `null`. `loc` is `[file, line, col]` of the nearest preceding `dbg_stmt`, absolute and 1-based, switched to the callee's file inside an inlined body. `attrs` holds the decoded payload (`index`, `field`, `callee`, `target`, `order`, ...). `bodies` holds nested instruction lists: `then`/`else` for `cond_br`, `error` for `try`, `block`, `loop`, `inline` for `dbg_inline_block`, and one `case` (with `items`/`ranges`) per prong plus `else` for switches. A tag the adapter does not decode is `{id, tag, "unsupported": true}`.

`tools/air_read.py` validates this shape and checks that re-serializing the parsed file reproduces it byte for byte.

## Using it

```
tools/build_zig_zv.sh                      # once per Zig release; ~8 min, ~9 GB RAM
ZV_AIR_OUT=DIR zig-zv build-obj -fno-emit-bin file.zig     # one compilation
tools/zv_air.sh DIR test                   # a whole `zig build` project: runs `zig-zv build test`
python tools/air_read.py DIR               # validate and round-trip
ZV_DEBUG_AIR=1 tools/build_zig_zv.sh       # adds --verbose-air, for the gate below
tools/check_corpus.sh zig-zv-air           # pinned counts and hook-vs-printer comparison
tools/check_cache.sh zig-zv                # restore-on-hit scenarios on a zig build project
```

Controls: `ZV_AIR_OUT=DIR` turns the export on, and `ZV_AIR_STD=1` includes std and the other toolchain modules (compiler_rt, ubsan_rt, the test runner), which are skipped by default. The environment variables are what make `zig build` work without touching `build.zig`: the build runner spawns `zig-zv` for each compile step and the children inherit them. Only functions the compiler analyzes are exported, so export from a root that reaches them (a test root, or `tools/air_all.zig` for a file whose pub functions are not all reached). `zig-zv` on Windows cannot link executables (its self-hosted COFF linker rejects `compiler_rt.lib`; stock builds without LLVM behave the same), so on Windows use direct `-fno-emit-bin` invocations or run `zig build` under Linux/WSL.

## Cache scenarios (Zig 0.17.0, Linux; `tools/check_cache.sh`)

A `zig build` project of two objects (two exported functions each), run with `ZV_AIR_OUT` set.

| Scenario | Result |
| --- | --- |
| Cold build | works: 4 files |
| Second build (cache hit, `cached` in the summary) after deleting the output directory | works: the same 4 files, restored |
| Hit with the output directory present | works: unchanged |
| Edit `a.zig`, rebuild | works: complete set; `b`'s files byte-identical, `a_one` has a new name |
| Rebuild after the edit (hit) | works: same set as the edit build |
| Export off: cache entries and installed objects vs the stock compiler | identical (the key is untouched) |
| Export on: installed objects vs the stock compiler | identical |
| `zig build --watch`, edit one file | works: the rebuilt step exports again, the output directory is a union (the old `a_one` stays) |
| `--watch`, delete the output directory, edit one file | partial: only the rebuilt step writes; untouched steps are not run at all, so their files stay missing until the next `zig build` |
| `-fincremental` (with or without `--watch`) | unsupported, fails loudly: `zv_air: ZV_AIR_OUT cannot be combined with -fincremental`. Under `--watch` the Maker then panics on the dead compiler child (upstream) |

The set is asserted exact (4 files for the project, build scripts of the project and of a path dependency excluded). Found on zmoltcp (`1915b35`, `zig build test`): before dependency build scripts were excluded, a cold build exported 6829 functions and a cache hit 6821, because the 8 functions of a dependency's `build.zig` are compiled only when the configuration cache misses. A stray 8 also separates the earlier reports of 6186 and 6194. With the exclusion, cold, hit and cold-again runs give 6821 with an identical file list.

Why `-fincremental` cannot work: an incremental update analyzes only what changed, so the hook sees only those functions. Measured with a prototype that wrote straight to the output directory: after editing `a.zig`, `a_one` was written again and `a_two`, `b_one`, `b_two` were not; after deleting the output directory and editing a comment, nothing was written at all. A cache-keyed location cannot repair that, because the incremental artifact directory is keyed by compilation inputs and is never replaced.

## Milestones

| | Deliverable | Done when |
| --- | --- | --- |
| M1 | `zig-zv` builds from the script on Windows and Linux | Hook under 50 lines; with the export off, `zig-zv` and a stock build from the same tag give identical output |
| M2 | Export `examples/search.zig` | JSON for all six functions; contracts visible; compared against what the zvc spike parses |
| M3 | Export zmoltcp | Every function exports; JSON round-trips through a reader; `unsupported` count reported and driven to zero for zmoltcp's instruction set; export overhead measured |
| M4 | Canary | An on-demand workflow builds zig-zv, checks that every hook anchor matches exactly once, runs the corpus gate (27 functions, 1083 instructions, 0 unsupported, hook JSON equal to the compiler's own `--verbose-air` text) and the cache scenarios; failure opens an issue |

The Phase 1 exit gate is M3 plus M4. Phase 2 then ports `zvc` from parsing source to reading this JSON.

## Out of scope

Analysis inside the compiler, LLVM builds, incremental-compilation mode, and exporting `std` (off by default, behind an option).
