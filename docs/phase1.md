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
  ZIG_VERSION          upstream tag and commit the patch targets
  hook.patch           the only edits to existing compiler files (target: under 50 lines)
  src/zv_air/          our files, copied into the Zig tree as src/zv_air/
    adapter.zig        the only file that reads Air / InternPool internals
    export.zig         JSON writer over the adapter's stable view
tools/build_zig_zv.sh  fetch tag, copy src/zv_air, git apply hook.patch, build zig-zv
```

The hook does three things: it adds a flag (`--zv-air-out <dir>`), stores it on `Compilation` and hashes it into the cache manifest (so a cached build can't silently skip the export), and calls `zv_air.export` after `analyzeFuncBodyInner`. The compiler is built with `-Denable-llvm=false`. The patched compiler (`zig-zv`) is used only for export runs; shipped binaries still come from the stock compiler.

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
zig-zv build-obj -fno-emit-bin --zv-air-out DIR file.zig     # one compilation
tools/zv_air.sh DIR test                   # a whole `zig build` project: runs `zig-zv build test`
python tools/air_read.py DIR               # validate and round-trip
```

Controls: `--zv-air-out DIR` or `ZV_AIR_OUT=DIR`, and `--zv-air-std` or `ZV_AIR_STD=1` to include std and the other toolchain modules (compiler_rt, ubsan_rt, the test runner), which are skipped by default. The environment variables are what make `zig build` work without touching `build.zig`: the build runner spawns `zig-zv` for each compile step and the children inherit them. Only functions the compiler analyzes are exported, so export from a root that reaches them (a test root, or `tools/air_all.zig` for a file whose pub functions are not all reached). A cached compile step skips analysis and so skips the export; `tools/zv_air.sh` uses a fresh cache for that reason. `zig-zv` on Windows cannot link executables (its self-hosted COFF linker rejects `compiler_rt.lib`; stock builds without LLVM behave the same), so on Windows use direct `-fno-emit-bin` invocations or run `zig build` under Linux/WSL.

## Milestones

| | Deliverable | Done when |
| --- | --- | --- |
| M1 | `zig-zv` builds from the script on Windows and Linux | Hook diff under 50 lines; with the flag off, `zig-zv` and a stock build from the same tag give identical output |
| M2 | Export `examples/search.zig` | JSON for all six functions; contracts visible; compared against what the zvc spike parses |
| M3 | Export zmoltcp | Every function exports; JSON round-trips through a reader; `unsupported` count reported and driven to zero for zmoltcp's instruction set; export overhead measured |
| M4 | Canary | Scheduled CI applies the patch to upstream Zig master and builds; failure opens an issue |

The Phase 1 exit gate is M3 plus M4. Phase 2 then ports `zvc` from parsing source to reading this JSON.

## Out of scope

Analysis inside the compiler, LLVM builds, incremental-compilation mode, and exporting `std` (off by default, behind an option).
