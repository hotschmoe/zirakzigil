# Phase 1: AIR exporter

Goal: every function in a pilot codebase exports its AIR in a versioned, compact, deterministic format that out-of-compiler tools read in place. No analysis happens in this phase; it only produces the input that `zvc` (Phase 2) and `zv-own` (Phase 3) will read. The fork follows the fork policy in [design.md](design.md#fork-policy-stay-fast-forwardable).

## Where AIR comes from (Zig 0.17.0)

- `src/Zcu/PerThread.zig`, `analyzeFuncBody`: `pt.analyzeFuncBodyInner(func_index, reason)` returns a function's finished AIR. This is the hook point. It runs once per function instance (each generic instantiation separately) and runs with `-fno-emit-bin`, so the exporter needs no backend and no LLVM.
- The AIR here has not been legalized or run through liveness yet; those happen later, per backend, in `runCodegenInner`. That suits us: it is backend-independent and closest to the source.
- Stock release compilers can't print AIR. `--verbose-air` exists, but only in compilers built with `-Ddebug-extensions`, and its output is unversioned text. It is a useful oracle while developing, not an interface.
- Inline calls survive as `dbg_inline_block` with the callee, so `zv.requires`, `zv.ensures` and friends stay identifiable even when inlined. `dbg_stmt` carries line and column relative to the function.

## Layout

```
src/air/               the schema and its readers; std only, shared with the compiler by copy (rule 5)
  schema.zig           the one definition: records, tables, header, index entry, validation, scrub
  builder.zig          builds packs (one per function, then merged); used by the compiler
  json.zig             the JSON form of a pack
  reader.zig           loads a pack file or an index directory
  air.zig              the `zv_air` module (build.zig exposes it; Phase 2's zvc imports it)
tools/zv_air_cli.zig   `zv-air list|stats|verify|dump` (zig build zv-air)
compiler/
  ZIG_VERSION          upstream tag and commit the hook targets
  hook/rules.zon       the only edits to existing compiler files: three inserted lines
  src/zv_air/          our files, copied into the Zig tree as src/zv_air/ (together with schema, builder, json)
    adapter.zig        the only file that reads Air / InternPool; fills a Builder
    export.zig         collects the functions of a compilation and merges them into its pack
    cache.zig          options, cache key, where the pack and the index entry go
tools/zv_hook.zig      inserts the rules; every anchor must match exactly once or nothing is written
tools/build_zig_zv.sh  fetch tag, copy the files, apply the rules, build zig-zv
```

The hook is three lines. `exportFunc` runs after `analyzeFuncBodyInner`. `hashCache` adds a salt to the whole-cache key, and only when `ZV_AIR_OUT` is set. `restore` is deferred at the top of `Compilation.update`. There are no flags and no new fields: options come from `ZV_AIR_OUT`, `ZV_AIR_STD` and `ZV_AIR_JSON`, read from `comp.environ_map`. With `ZV_AIR_OUT` unset, none of the three does anything, and the cache key is stock's.

The compiler is built with `-Denable-llvm=false`. The patched compiler (`zig-zv`) is used only for export runs; shipped binaries still come from the stock compiler.

## Packs and the index

One pack per compilation (per compile step of a `zig build`, per update): everything that compile analyzed, in one file. `exportFunc` encodes each function as a small single-function pack as soon as its AIR is final (in parallel, on the analysis threads); when the update ends, the parts are sorted by (name, id) and merged into the compilation's pack. Nothing is written per function.

Where the pack lives: in the compile's own cache entry, `o/<digest>/zv_air.zvp`, next to a one-line `zv_air.zvi` that is written after it. A cache hit finds both; so a cached compile step still has its export, and the output never depends on which run produced it. Without a cache (a direct `-fno-emit-bin` run) the pack goes to the index directory.

`ZV_AIR_OUT=DIR` names the **index directory**. On every update of a compile, hit or miss, that compile writes one small entry there, `<identity>.zvi`:

```
zvi 2 pack 27986048 cfce1d4f214a654c 5869 /abs/path/to/cache/o/<digest>/zv_air.zvp
```

(schema version, format, size, content hash, function count, path). The identity is a hash of the compile's name, kind, target, optimize mode and module graph, so an update replaces its own previous entry and the directory always names the packs that make up the current build: an edited step's old pack is no longer named, a `--watch` rebuild does not union with older output, a deleted index is rewritten by the next hit. Readers load the entries, then the packs they name, and check size and hash; an entry whose pack is gone or changed is an error, never skipped. The packs themselves stay in the Zig cache and are read in place; nothing is copied. `tools/zv_air.sh` empties the directory of entries before a run, which is only needed to drop compile steps that no longer exist.

`-fincremental` is unsupported and fails loudly (below). The build scripts (the project's `build.zig` and the dependencies') are never exported: `zig build` compiles it only when its configuration cache misses, so exporting it would make the set depend on that cache. A compile that analyzed no function leaves no entry.

## Schema v3 (v2 plus `fields`)

Defined once, in `src/air/schema.zig`. A pack is a header and fifteen tables of fixed-size little-endian records (extern structs without padding, 8-aligned sections), so a reader maps or reads the file and casts: there is no parse step beyond the header's section table. Every table is shared by all functions of the pack.

| Table | Record |
| --- | --- |
| `strings`, `str_index` | one deduplicated byte blob; `StrId` indexes `str_index` (`off`, `len`) |
| `files` | `{module, path}` (module-relative, `/` separators) |
| `types` | `{name, kind, child, bits, len, flags}`: `kind` is a `std.builtin.TypeId` name, `child` the pointee, element, optional child or error-union payload, `bits` the width of ints and floats, `len` the length of arrays and vectors, `flags` signedness and pointer size and qualifiers. A type's `child` always has a smaller id |
| `consts` | `{kind, ty, a}`: undef, void, null, bool, int (64-bit), float (IEEE bits), enum_literal, enum_tag, error, func (a callee), type, and `text` (the compiler's printed form) for what is not decoded yet: aggregates, pointers, big ints, f80/f128 |
| `callees` | the fully qualified name of every function called or inlined, once |
| `locs` | `{file, line, col}`, once each |
| `funcs` | `{id, fqn, file, line, ret, params, callees, insts, unsupported, flags}` |
| `params`, `callee_refs` | per-function ranges: `{ty, zir_index}`, and `{callee, inlined}` without duplicates |
| `insts` | `{id, tag, ty, loc, ops, attrs, bodies}`, 32 bytes; the instructions of one body are contiguous; `ty` is `none` for an instruction the adapter does not decode |
| `operands` | one `u32`: none, an instruction `id`, or a constant |
| `attrs` | `{key, value}`: the decoded payload (`index`, `field`, `callee`, `target`, `order`, ...); the key fixes whether `value` is an int, a string, a flag, an instruction or a callee |
| `bodies` | `{label, items, ranges, insts}`: `then`/`else`, `error`, `block`, `loop`, `inline`, `case` |
| `fields` | `{owner, index, name, ty}` (schema 3, sorted by owner and index): the fields of the structs, tuples and unions a function uses by value, and of what they hold by value. A type without records has no known fields (empty, or only ever behind a pointer): `Pack.fieldsOf`. Schema 2 packs have no such table and remain readable |

The header carries the schema version (2), the Zig version, the target triple, the optimize mode and the root name of the compile.

What makes the bytes a function of the program and the target alone:

- Functions are sorted by (name, id), where `id` is the hash of the function's own single-function pack. Generic instances that share a name are told apart by it.
- Every table is filled in first-use order, and types are interned children first, so ids do not depend on thread timing.
- No InternPool id reaches a name: `foo__anon_1234` becomes `foo__anon` (`schema.scrub`), in function, type, callee and constant names and in printed values. File paths use `/`.
- No host path, time or pointer is stored. Windows and Linux produce identical packs for the same source and target (below).
- Constants are structured; only the kinds the adapter does not decode carry the compiler's text.

`Pack.validate` checks every reference (ids in range, ranges inside their tables, children before parents, unsupported counts, function order); a pack that passes can be walked without further checks.

### JSON form

`ZV_AIR_JSON=1` writes the same pack as one JSON document (`zv_air.json` in the cache entry, named by the same index entry with format `json`) instead of the binary pack; `zv-air dump PACK` prints a pack the same way. It is the readable form for people and agents, generated by `src/air/json.zig` from the same tables: ids stay ids (`ty` indexes `types`, `file` indexes `files`, `callee` indexes `callees`), constants are inlined as `{"ty", "kind", "val"}` (floats as `"0x<bits>"`), an instruction is `{id, tag, ty, operands?, attrs?, loc?, bodies?}`. `tools/air_read.py` validates this shape and checks that re-serializing the parsed file reproduces it byte for byte; `tools/check_corpus.sh` requires `zv-air dump` of the binary pack to equal the JSON the compiler writes directly, byte for byte.

## Using it

```
tools/build_zig_zv.sh                      # once per Zig release; ~8 min, ~9 GB RAM
ZV_AIR_OUT=DIR zig-zv build-obj -fno-emit-bin file.zig     # one compilation
tools/zv_air.sh DIR test                   # a whole `zig build` project: runs `zig-zv build test`
zig build zv-air                           # the reader tool: zig-out/bin/zv-air
zv-air stats DIR                           # counts, table sizes, load time of the whole set
zv-air list DIR                            # one line per function
zv-air dump PACK --fn midpoint --pretty    # a pack (or part of it) as JSON
zv-air verify DIR                          # entries match their packs, every reference valid
ZV_DEBUG_AIR=1 tools/build_zig_zv.sh       # adds --verbose-air, for the gate below
tools/check_corpus.sh zig-zv-air           # pinned counts, determinism, binary vs JSON, hook-vs-printer
tools/check_cache.sh zig-zv                # index scenarios on a zig build project
```

From Zig, `const zv_air = b.dependency("zirakzigil", .{}).module("zv_air")`; `zv_air.Set.open` loads an index directory, `zv_air.loadPack` one file, and `Pack` exposes the tables as slices. Nothing allocates after the load.

Controls: `ZV_AIR_OUT=DIR` turns the export on, `ZV_AIR_STD=1` includes std and the other toolchain modules (compiler_rt, ubsan_rt, the test runner), which are skipped by default, and `ZV_AIR_JSON=1` writes JSON instead of packs. The environment variables are what make `zig build` work without touching `build.zig`: the build runner spawns `zig-zv` for each compile step and the children inherit them. Only functions the compiler analyzes are exported, so export from a root that reaches them (a test root, or `src/verify/air_all.zig` for a file whose pub functions are not all reached). `zig-zv` on Windows cannot link executables: built without LLVM it uses the self-hosted COFF linker, which fails on the `compiler_rt.lib` it just wrote (`invalid value 608 for weak external symbol 0x630`, `linker failed to load archive member`); a stock compiler built without LLVM behaves the same. That is a defect of the self-hosted linker in this Zig release and out of scope here, because export never links: `zig build verify` and `tools/zvc_export.sh` run `zig-zv test -fno-emit-bin` on a root that reaches the functions (direct invocations, Windows and Linux alike), and the checkers are built by the stock compiler. Only whole-project `ZV_AIR_OUT=DIR zig-zv build` runs (`tools/zv_air.sh`) need Linux.

## Packs are exported in CI, never committed

The packs of the suites (`tests/zvc`, `tests/own`) are not in the repository. `tools/zvc_packs.sh` and `tools/own_packs.sh` export them from the sources in the tree; CI does that on every run with a zig-zv built from the pinned tag and `compiler/` (cached by the hash of the tag, the patch queue, the hook rules and the schema files it is built from), so a pack cannot be stale and a change of source or of the exporter shows in the verdicts. This rests on the exporter being deterministic: the 73 packs exported on the Windows and the Linux CI runners were byte-identical to each other and to the packs committed before 0.17.24 (a local Windows export and a WSL export agreed as well). `tools/check.sh` does the same locally.

## Prebuilt zig-zv and Z3 for consumers

A project that adopts zv does not build a compiler. `addVerify` (docs/adoption.md) takes zig-zv from a release asset, `zig-zv-<zig tag>-<patch queue hash>-<arch>-<os>.tar.gz` (the executable and `ZIG_VERSION`), pinned in this package's `build.zig.zon` as a lazy dependency per host (`zig_zv_x86_64_windows`, `zig_zv_x86_64_linux`), so the Zig package manager downloads it once into the global cache and checks its content hash; the same hash is the same on Windows and Linux hosts (checked). The patch queue hash (`tools/queue_hash.sh`) covers everything zig-zv is built from, so an asset stays valid across releases until the queue changes, and CI (`tools/check_pins.sh`) fails when a pinned asset belongs to another queue or Zig tag. Z3 4.16.0 is pinned the same way, from the upstream release. Without a pin for the host (or with `-Dzv-from-source`) the build falls back to `tools/ensure_zig_zv.sh`, which builds from source once per queue hash into the global cache.

Cutting a release: push the tag `vX.Y.Z`. `.github/workflows/release.yml` builds zig-zv on Windows and Linux runners, packages it with `tools/package_zig_zv.sh` and attaches the assets to the release of the tag (creating a draft when there is none). **A release must include those assets**: check that the workflow succeeded and the draft lists both archives before publishing. When the patch queue changed, run `tools/pin_assets.sh vX.Y.Z` after the upload, which writes the two `zig_zv_*` entries (URL, content hash, lazy) into `build.zig.zon`, and commit it; the next release then carries the pins. Until a release has been pinned, consumers get the from-source fallback. `tools/consumer_flow.sh` is the end-to-end test of all of this (it packages the zig-zv of the tree, pins it from a local server, and runs the consumer cold, warm, after an edit and after a seeded mistake); CI runs it on both OSes.

## Cache scenarios (Zig 0.17.0, Linux; `tools/check_cache.sh`)

A `zig build` project of two objects (two exported functions each), run with `ZV_AIR_OUT` set. After every build the index must name exactly two packs and four functions, and `zv-air verify` must accept it.

| Scenario | Result |
| --- | --- |
| Cold build | works: 2 packs, 4 functions |
| Second build (cache hit, `cached` in the summary) after deleting the index directory | works: the same entries and functions, written again from the cache |
| Hit with the index present | works: unchanged |
| Edit `a.zig`, rebuild, index not cleared | works: still 2 packs and 4 functions; `b`'s functions identical, `a_one` has a new id and the old one is gone (in 0.17.1 the old file stayed unless the directory was cleared) |
| Rebuild after the edit (hit) | works: same set as the edit build |
| Export off: cache entries and installed objects vs the stock compiler | identical (the key is untouched) |
| Export on: installed objects vs the stock compiler | identical |
| `zig build --watch`, edit one file | works: the rebuilt step replaces its own entry; the index names exactly the current packs (in 0.17.1: a union, the old `a_one` stayed) |
| `--watch`, delete the index directory, edit one file | partial, unchanged: only the rebuilt step writes its entry; untouched steps are not run at all, so they are named again by the next full `zig build` |
| `-fincremental` (with or without `--watch`) | unsupported, fails loudly: `zv_air: ZV_AIR_OUT cannot be combined with -fincremental`. Under `--watch` the Maker then panics on the dead compiler child (upstream) |

Found on zmoltcp (`1915b35`, `zig build test`) in 0.17.1: before dependency build scripts were excluded, a cold build exported 6829 functions and a cache hit 6821, because the 8 functions of a dependency's `build.zig` are compiled only when the configuration cache misses. With the exclusion, cold, hit and cold-again runs give 6821 with an identical function list; the index model keeps that (below).

Why `-fincremental` cannot work: an incremental update analyzes only what changed, so the hook sees only those functions. Measured with a prototype that wrote straight to the output directory: after editing `a.zig`, `a_one` was written again and `a_two`, `b_one`, `b_two` were not; after deleting the output directory and editing a comment, nothing was written at all. A cache-keyed location cannot repair that, because the incremental artifact directory is keyed by compilation inputs and is never replaced.

## Measurements (zmoltcp `1915b35`, `zig build test`, Ubuntu 24.04 under WSL2, 24 cores)

Export off versus on, `zig build test` with an empty local cache and a warm global cache, median of 5 interleaved runs (the first v2 run of a series is slower, about 2 s, while the new compiler's pages load). Reader load is the whole set read into memory (pack: read, hash and header check; JSON: `std.json` into a `Value`), measured in Zig.

| | v1 JSON (0.17.1) | v2 JSON | v2 binary |
| --- | --- | --- | --- |
| files in the output | 6821 | 12 | 12 packs + 12 entries (about 110 bytes each) |
| size | 80.1 MB | 69.3 MB | 32.6 MB |
| functions (instances) | 6821 | 6891 | 6891 |
| `zig build test`, export off | 11.66 s | 11.62 s | 11.62 s |
| `zig build test`, export on | 12.05 s | 12.07 s | 11.86 s |
| export overhead | +0.39 s (+3.3%) | +0.45 s (+3.9%) | +0.24 s (+2.1%) |
| reader load of the whole set | 820 ms | 730 ms | 13 ms |

v2 counts 70 more functions than v1 has files because v1 named a file by name and content, so the same function analyzed by two compile steps was one file; in v2 each of the 12 packs holds its own compile's functions. Table sizes of the binary set (bytes): instructions 22.1 M, bodies 3.4 M, operands 2.4 M, strings 1.5 M, attrs 1.3 M, locs 0.6 M, funcs 0.4 M, everything else under 0.3 M. Direct `-fno-emit-bin` check of `src/root.zig` on Windows (5869 functions, 598k instructions): export off 1.20 s, binary 1.46 s, JSON 1.57 s; v1 measured 1.27 s to 3.8 s there.

Determinism, same source and target on both hosts: the corpus pack (`-target x86_64-windows-gnu`, 58,416 bytes) has sha256 `be63ff2c872a5f0813083857c41c880203013954154bd9b86ba2816ef427283e` on Windows and on Linux; the zmoltcp pack (`-target x86_64-linux-gnu`, `src/root.zig`, 27,986,040 bytes) has sha256 `1e1625e191b73bca47269d06577d9615d53d7267f866ccf0c7e5b813c069775e` on both.

## Milestones

| | Deliverable | Done when |
| --- | --- | --- |
| M1 | `zig-zv` builds from the script on Windows and Linux | Hook under 50 lines; with the export off, `zig-zv` and a stock build from the same tag give identical output |
| M2 | Export `examples/search.zig` | Every function exported; contracts visible; compared against what the zvc spike parses |
| M3 | Export zmoltcp | Every function exports; the pack validates and converts to JSON that round-trips; `unsupported` count reported and driven to zero for zmoltcp's instruction set; export overhead measured |
| M4 | Canary | An on-demand workflow builds zig-zv, checks that every hook anchor matches exactly once, runs the corpus gate (27 functions, 1083 instructions, 0 unsupported, pack equal to its JSON, JSON equal to the compiler's own `--verbose-air` text) and the cache scenarios; failure opens an issue |

The Phase 1 exit gate is M3 plus M4. Phase 2 then ports `zvc` from parsing source to reading packs through `zv_air`.

## Out of scope

Analysis inside the compiler, LLVM builds, incremental-compilation mode, and exporting `std` (off by default, behind an option).
