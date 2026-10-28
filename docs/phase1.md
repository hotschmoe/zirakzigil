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

One file per function instance, containing:

- `schema`, `zig_version`, the fully qualified name, and the source file and line;
- parameter and return types;
- every instruction with its tag, result type, operands, decoded payload and nearest `dbg_stmt` location;
- callees, including inline ones.

Types are interned into a per-file table. Anything the adapter doesn't decode yet is emitted as `{"tag": ..., "unsupported": true}` rather than dropped, so coverage can be measured.

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
