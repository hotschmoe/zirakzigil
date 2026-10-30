# Track C: routes to AIR that need no fork, or less fork

Question from `research/README.md`: what is the cheapest way to keep the Phase 1 AIR exporter working across Zig releases before 1.0? This track does not port the hook. It records every route to the same per-function, post-Sema information, and the dead ends, with the command or the upstream line that settles each one.

Hosts, all stock release binaries, none rebuilt:

| Host | Binary | Version |
| --- | --- | --- |
| 0.16.0 | `C:\Users\hotschmoe\zr\host-0.16\zig.exe` | 0.16.0 |
| 0.17.0 | `zig` on PATH | 0.17.0 |
| 0.18.0-dev | `C:\Users\hotschmoe\zr\host-0.18-dev\zig.exe` | 0.18.0-dev.738+ae9a8acc7 |

Upstream trees were read, not modified: `C:\Users\hotschmoe\Documents\GitHub\zig-0.17` (tag 0.17.0), `C:\Users\hotschmoe\zr\zig-0.18-dev` at ae9a8acc7, and the 0.16 tree for ZIR and C comparison. No compiler was rebuilt. SeaHorn, SMACK, KLEE, CBMC, Frama-C, and ESBMC were not executed on this machine. Their version pins below are from their own docs.

Probes live in `research/track-c/probes/`. Multi-megabyte `.ll` and `.c` outputs were left in `research/track-c/artifacts/` and are not committed.

## Verdicts

| # | Route | Verdict | Versus AIR | Stability |
| --- | --- | --- | --- | --- |
| 1 | What replaced `--verbose-air` | PARTIAL | Same pre-legalize AIR, as unversioned text, only from a compiler built with debug logging | The flag died on 2026-10-08. Release binaries print nothing |
| 2 | Compiler as a library, or a custom backend | DEAD END | A backend would see post-legalize AIR plus liveness, and adding one edits more upstream files than the hook | Closed enums. No per-function plugin point |
| 3 | `-femit-llvm-ir` | PARTIAL | Safety checks survive in Debug and are deleted in ReleaseFast. Types, contracts, and error names are lowered | Zig 0.18 requires LLVM 23. KLEE 3.3 recommends LLVM 18. SeaHorn and SMACK docs are still on LLVM 5 to 12 |
| 4 | `-ofmt=c` (design track F) | PARTIAL | Same safety split as LLVM. One Debug function is ~250k lines | User-function shape holds across 0.16, 0.17, and 0.18. Names and comments drift |
| 5 | ZIR and AST | PARTIAL | Untyped, one body per declaration, comptime not resolved. Overflow *intent* is a tag | 0.17 and 0.18 histograms match on the corpus. 0.16 differs by a handful of tags. `ast-check -t` is dead on all three release hosts |
| 6 | Upstream intent | DEAD END as a plan | No accepted proposal for a stable dump or a plugin was found | The last AIR-dump change moved it into a stripped debug log |
| 7 | Prior art (Kani, Charon, Creusot, Verus, Clang) | The reference class | They pin a toolchain and port. None of them gets a stable compiler IR for free | A bump can be one nightly and a touched codegen file |

## Metrics, both upgrade paths

These numbers are for the landscape routes, which add no upstream lines. They are not a port of `compiler/hook.patch`.

| Metric | 0.16.0 to 0.17.0 | 0.17.0 to 0.18.0-dev.738+ae9a8acc7 |
| --- | --- | --- |
| hook lines | 0 | 0 |
| port diff | C comment `/* file:2:14 */` became `/* one.one */` plus `/* 2:14 */`. Enum prefix `builtin_` became `lang_`. Tuple hash and symbol suffix changed. `Ast.parse`'s third parameter changed from `Mode` to `ParseOptions` (one comptime branch in `probes/zir_walk.zig`). ZIR instruction count on the corpus went from 1327 to 1336. `validate_deref` became `deref`. `zig dump-zir` appeared. | `--verbose-air` became an unrecognized parameter (exit 1). `--debug-log illegal-air` warns and dumps nothing on this host. C symbol suffix and tuple hash changed again; the comment form and `lang_` prefix held. The ZIR walker and its histogram were unchanged (1336 instructions, same tags). |
| rebuilds | 0 | 0 |
| failure quality | `--verbose-air` on the stock 0.16 and 0.17 compilers exits 0 with empty stdout and empty stderr. `ast-check -t` exits 1 with `error: -t option only available in builds of zig with debug extensions`. Importing `Air.write` and calling it fails at `src/Air/print.zig:5` with `no module named 'build_options'`. | `--verbose-air` exits 1: `error: unrecognized parameter: --verbose-air`. `--debug-log illegal-air` exits 0 and warns: `Zig was compiled without logging enabled (-Dlog). --debug-log has no effect.` |
| silent-drift risk | A release compiler accepts `--verbose-air` and prints no AIR. ReleaseFast C and LLVM drop overflow checks and still exit 0 (`add nuw`, or `t0 = a0 + UINT32_C(1)`). The ZIR walk exits 0 on all three hosts while the tag mix moved between 0.16 and 0.17. | The debug-log text format is not versioned. A parser of `Air.Print` would keep compiling against a compiler whose log line drifted. Schema v1 would not notice, because this route never produces schema v1. |
| coverage | Not schema v1. ZIR has 19 `add`, 10 `addwrap`, 3 `add_unsafe` on the corpus, and one `generic` declaration. LLVM and C monomorphize in Debug and inline the generic away in ReleaseFast. | Same. `illegal-air` would be pre-legalize AIR for every function that enters codegen, including std, with no module filter. |
| wall time | Emitting the corpus was under a second (0.17 `zig test --test-no-exec`, Debug: C in 0.41s, LLVM IR in 0.83s). No 8-minute compiler build. | `one.zig` Debug C and LLVM on the 0.18 host each finished in under a second. |

## 1. What replaced `--verbose-air`

**PARTIAL.** A compiler built with `-Dlog=debug` (or `-Ddebug-extensions`, which defaults the log level to debug) can print pre-legalize AIR with zero source edits. The stock release binaries cannot. The text is not schema v1 JSON.

### The commit

`git log -S verbose_air --oneline -- src/` in `zig-0.18-dev` returns two commits:

- `f08a8f0fc217914690a58035291da8bcc7a86e47`, Jacob Young, Thu 8 Oct 2026, `main: reimplement compiler debug flags`. 48 files, +349/−421. Patch: https://codeberg.org/ziglang/zig/commit/f08a8f0fc217914690a58035291da8bcc7a86e47.patch
- `0c978ba957ad1d44f5a4952b2d6dce121a5b05e6`, Andrew Kelley, Mon 22 Jun 2026, `WIP: migrate build and fetch commands to Maker process`. The pickaxe only says the string's count inside `src/` changed. That WIP is not a design statement about AIR, and it was not diffed further.

The October commit's message replaces the dedicated flags with log scopes:

- `--debug-log illegal-air`: pre-legalized AIR
- `--debug-log legal-air`: post-legalized AIR
- `--debug-log air`: final AIR with liveness
- plus `ip-stats`, `ip-values`, `ip-generic-instances`, `llvm-ir`, `opt-llvm-ir`

It deletes `--verbose-cimport` and `--verbose-llvm-cpu-features`. It also adds object formats `.llvmbc` and `.llvmir`.

### Where the dump sits, relative to the hook

0.17 still has the flag and still gates the dump on debug extensions.

- Help text: `src/main.zig:797` (`--verbose-air`).
- Parsed at `src/main.zig:1817`.
- Codegen is entered only when `build_options.enable_debug_extensions and comp.verbose_air` (`src/Zcu/PerThread.zig:2306`).
- The print happens after legalize and after liveness (`src/Zcu/PerThread.zig:4527-4543`). So 0.17 `--verbose-air` is post-legalize AIR, which is already a step past the hook. The hook runs on the AIR returned by `analyzeFuncBodyInner`, before this function.

0.18 moves the three prints inside `runCodegenInner`, and the first one is before legalize:

```
src/Zcu/PerThread.zig:4540  std.log.scoped(.@"illegal-air").debug(...)   // liveness still null
src/Zcu/PerThread.zig:4542  legalize, if the backend asks
src/Zcu/PerThread.zig:4548  std.log.scoped(.@"legal-air").debug(...)
src/Zcu/PerThread.zig:4551  liveness
src/Zcu/PerThread.zig:4552  std.log.scoped(.@"air").debug(...)
```

`illegal-air` is the same pre-legalize AIR the hook exports, for every function that reaches codegen. Codegen is entered when a bin file exists, or when any of those three scopes is enabled (`src/Zcu/PerThread.zig:2319`). `-fno-emit-bin` plus the scope is enough to enter, and the job then returns `error.NoLinkFile`.

The printer refuses to exist unless the compiler was built with debug logging:

```
src/Air/Print.zig:24  comptime assert(build_options.log_level == .debug);
```

`std.log` debug is itself a comptime no-op below that level. Passing the flag on a quieter compiler warns and drops the scope (`src/main.zig:6248`):

```
warn("Zig was compiled without logging enabled (-Dlog). --debug-log has no effect.", .{});
```

`build.zig` in that commit: `-Ddebug-extensions` defaults the log level to `.debug`. Otherwise Debug optimize is `.debug`, safe/fast are `.info`, small is `.err`. A ReleaseSafe or ReleaseFast compiler cannot print AIR. A Debug compiler, or any compiler passed `-Dlog=debug`, can, with no patch.

### What the stock binaries actually do

Corpus file `research/corpus/corpus.zig`, `build-obj -fno-emit-bin`:

| Command | Exit | stdout | stderr |
| --- | --- | --- | --- |
| 0.16 `--verbose-air` | 0 | 0 bytes | 0 bytes |
| 0.17 `--verbose-air` | 0 | 0 bytes | 0 bytes |
| 0.18 `--verbose-air` | 1 | 0 | `error: unrecognized parameter: --verbose-air` |
| 0.18 `--debug-log illegal-air` | 0 | 0 | `warning: Zig was compiled without logging enabled (-Dlog). --debug-log has no effect.` (111 bytes) |

The 0.16 and 0.17 release compilers parse the flag and then compile it out of the dump. That is the silent-drift case for this route: success, and no AIR.

`Air.Print.format` (`src/Air/Print.zig`) writes the fully qualified name, a byte total, and `writeBody`. Human text on stderr. It includes the standard library, because nothing filters modules. It is not versioned. Reproduced here only from the source. This host was not rebuilt with `-Dlog=debug`, so the text itself was not captured. The source plus the stock warning is the evidence. A rebuild would take about 8 minutes and 9 GB and would not change the verdict.

### Incremental debug server

`src/IncrementalDebugServer.zig` is a TCP REPL on port 7623, enabled by `--debug-incremental`, and the file is compiled only when `enable_debug_extensions` is set (lines 1-14). Commands found in the file include `summary` (line 198) and `type_info` (line 341), plus navigation over types, navs, and units. There is no AIR dump and no plugin hook.

`lib/std/zig/Server.zig` is the build-runner protocol: `test_results`, `test_started`, `file_system_inputs`, `coverage_id`, `fuzz_start_addr`, `time_report`, `discovered_inputs`, `config`, `bsp_handshake`, and the other `bsp_*` messages (lines 40-107). No AIR and no ZIR.

## 2. Compiler as a library, or a custom backend

**DEAD END** for injecting the hook without editing upstream files. A custom backend is a larger fork than `compiler/hook.patch`, and it is handed AIR after legalize.

### The import, run on stock 0.17

`probes/import_air.zig` imports `src/Air.zig` as a module and calls `Air.write`. Command:

```
zig build-exe --dep air_upstream -Mroot=probes/import_air.zig ^
  -Mair_upstream=C:\Users\hotschmoe\Documents\GitHub\zig-0.17\src\Air.zig -fno-emit-bin
```

Exit 1:

```
src\Air\print.zig:5:31: error: no module named 'build_options' available within module 'air_upstream'
const build_options = @import("build_options");
referenced by:
    write: src\Air\print.zig:13:21
    main: probes\import_air.zig:8:14
```

`build_options` is generated by the compiler's own `build.zig`. User code has no such module. `Air.zig` also file-imports `InternPool.zig`, `Type.zig`, `Value.zig`, `Zcu.zig`, and `Air/print.zig`, and those files import `build_options` the same way (`src/Zcu.zig:36`, `src/InternPool.zig:6`, `src/Value.zig:1`).

Zig analyzes function bodies lazily. An earlier form of the probe that only took the `Air.write` value, and did not call it, exited 0 with empty stderr. The call is what forces `print.zig` to be analyzed. A type-level import that "succeeds" has not linked the compiler.

There is no `@import("root")` extension point in the compiler. The two hits are the user's root module (`src/Zcu/PerThread.zig:2522`) and comments in `src/crash_report.zig` about the user's panic handler. `src/dev.zig` `Env` (line 1) is how the compiler strips itself for bootstrap (`bootstrap`, `core`, `full`, `ast_gen`, `sema`, per-backend). `.full => true` (line 73). It is not a slot for a third-party pass.

### Closed backend and linker

`std.lang.CompilerBackend` (`lib/std/lang.zig:1288`) is a closed list: `stage2_llvm` through `stage2_spirv`, `zsf_spork8`, and a nonexhaustive `_`. `src/target.zig:893` `zigBackend` maps `use_llvm` to `stage2_llvm`, `ofmt == .c` to `stage2_c`, and otherwise the arch, including `.spork8 => .zsf_spork8`. `src/codegen.zig:154` `generateFunction` is a comptime switch on that enum and calls `CodeGen.generate(lf, pt, func_index, air, liveness)`. `src/link.zig:1379` `File.Tag` is `coff`, `elf`, `elf2`, `llvm`, `macho`, `macho2`, `c`, `wasm`, `spirv`, `spork8`, `plan9`, `lld`, dispatched by `@fieldParentPtr` through `Tag.Type`. Adding a backend means editing `CompilerBackend`, `zigBackend`, `codegen.zig`, `link.zig`, and a `dev.zig` feature. That is more upstream surface than the hook, which is three files (`compiler/hook.patch`: `Compilation.zig`, `Zcu/PerThread.zig`, `main.zig`).

The AIR a backend receives is the one after `illegal-air` and after `legalize` (`PerThread.zig:4540-4552`). Legalize rewrites the instruction stream for that backend. Liveness is attached. The hook's export is the pre-legalize stream, with no liveness, and it can skip the standard library. A "verification backend" would not be a drop-in home for the current exporter.

## 3. LLVM IR from a stock compiler

**PARTIAL.** `-femit-llvm-ir` works on stock 0.17 and on this 0.18 host (the host was built with LLVM; `-femit-llvm-ir` is documented as requiring LLVM extensions). It is not a stand-in for AIR.

`zig build-obj` on `corpus.zig` alone emitted a 1,820-byte module that contains `builtin.output_mode` and no corpus function. Unreferenced `pub fn`s are not analyzed. The corpus run that does analyze them is:

```
zig test --test-no-exec -femit-llvm-ir=corpus-0.17-test.ll -fno-emit-bin -ODebug research/corpus/corpus.zig
```

Exit 0, 0.83s, 25,462,885 bytes. The matching `-ofmt=c -ODebug` run was 0.41s and 14,480,675 bytes (292,203 lines). `export fn` cannot carry a comptime parameter (`error: comptime parameters not allowed in function with calling convention 'x86_64_win'`), so the semantics probe keeps `generic` as a non-exported function.

### What survives, on `probes/semantics.zig`, stock 0.17

Debug LLVM, `sem-0.17-debug.ll`, 21,030,568 bytes. `semantics.addChecked` at line 272024:

```
%9 = call { i32, i1 } @llvm.uadd.with.overflow.i32(i32 %0, i32 %1)
%10 = extractvalue { i32, i1 } %9, 1
br i1 %10, label %OverflowFail, label %OverflowOk
```

The overflow path calls the integer-overflow panic. A slice index uses `llvm` bounds logic and an out-of-bounds panic. `a +% b` is a plain `add`. An explicit `@panic("...")` contract survives as `icmp` plus `debug.defaultPanic` of an anonymous string global. The string is a length and a pointer, not a `zv.requires` call. Each function takes an extra `ptr` argument for the stack trace, and Debug allocates a `lang.StackTrace`.

ReleaseFast, `sem-0.17-fast.ll`, 16,399,007 bytes. The same function at line 125974:

```
%2 = add nuw i32 %1, %0
ret i32 %2
```

`nuw` means overflow is LLVM undefined behavior. The bounds check on the index probe is gone. The `@panic` contracts remain, which is why ReleaseFast is still 16 MB: the panic runtime stays. `useGeneric` is inlined to `llvm.umax` and the generic function disappears. In Debug the two instantiations are separate (`corpus.generic__func_831` returning `i64`, `corpus.generic__func_830` returning `i8`).

Corpus Debug LLVM, the lowering that matters for a verifier:

- `corpus.tryChain` at line 326809: `sret({ i32, i16, [2 x i8] })`. An error union is a payload, a 16-bit error code, and padding. `try` / `errdefer` become branches, not a structured defer. AIR would keep the error union and the defer.
- `corpus.errors` switches on the raw codes. The error names are not in the type.
- `+%` is `add`, `-|` is `llvm.usub.sat`, `@mulWithOverflow` is `llvm.umul.with.overflow`.
- `inline` `helper` is not its own function. AIR keeps a `dbg_inline_block`.

The same Debug shape holds on the 0.18 host for `probes/one.zig`: `define internal i32 @one.one` at line 4653 of `one-0.18.ll` (21,087,977 bytes), and `llvm.uadd.with.overflow.i32` at line 4665.

### Verifiers, and the LLVM they pin

Zig 0.18's `cmake/Findllvm.cmake:43` rejects anything other than LLVM 23.x (`expected LLVM 23.x`). Comments in the 0.18 standard library still talk about LLVM 21 behavior. The tools a C or LLVM proof would reach for are pinned far behind that:

| Tool | LLVM it documents | Source |
| --- | --- | --- |
| SeaHorn `master` | README still describes LLVM 5.0 and calls that tree obsolete | https://github.com/seahorn/seahorn/tree/master |
| SeaHorn `dev10` | LLVM 10 | https://github.com/seahorn/seahorn/tree/dev10 |
| KLEE 2.3 (April 2022) | recommended LLVM 11, support added for 12 and 13 | https://github.com/klee/klee/releases/tag/v2.3 |
| KLEE 3.3 (current releases page) | recommended LLVM 18, support for 17-19, support removed below 15 | https://github.com/klee/klee/releases |
| SMACK via verify-c-common | LLVM 12.0.1, last SMACK commit they name is `4894245` | https://github.com/seahorn/verify-c-common |
| verify-c-common on KLEE | still tells users to use LLVM 11, with 12 and 13 added | same README |

KLEE has moved (18, not 11). It has not moved to LLVM 23, which is what `cmake/Findllvm.cmake` requires for this Zig. verify-c-common, the AWS C case study that also wires SeaHorn and SMACK, is still written against LLVM 11 and 12. SMACK's own README describes a translator from LLVM IR to Boogie and names C via Clang, not Zig (https://github.com/smackers/smack). Crux-LLVM is in the same family. No current Crux LLVM pin was fetched, and Crux was not run. No Zig-specific consumer of this IR showed up. A proof over this IR is a proof of the LLVM that `-O` happened to emit. Debug and ReleaseFast disagree on overflow, and both exit 0.

## 4. C backend

**PARTIAL.** This is design track F (`docs/design.md`: "C backend plus CBMC proof harnesses. Needs no fork, so it can start any time."). Stock `-ofmt=c` works on 0.16, 0.17, and 0.18. It does not replace AIR, and a ReleaseFast proof is a different property from a Debug proof.

### `probes/one.zig`, `export fn one(a: u32) u32 { return a + 1; }`

| Output | Bytes | Lines | The add |
| --- | --- | --- | --- |
| 0.16 Debug `one-0.16-debug.c` | 12,759,383 | 233,706 | `zig_addo_u32` then `integerOverflow__294`, comment `/* file:2:14 */`, symbol `one_one__211`, tuple `tuple_2_u32_u1_536870912`, enum `builtin_OutputMode` |
| 0.17 Debug `one-0.17-debug.c` | 13,127,162 | 250,234 | `zig_addo_u32` then `integerOverflow__300`, comments `/* one.one */` and `/* 2:14 */`, symbol `one_one__214`, tuple `tuple_2_u32_u1_33554432`, enum `lang_OutputMode` |
| 0.18 Debug `one-0.18-debug.c` | 13,170,641 | 251,224 | `zig_addo_u32`, comments `/* one.one */` and `/* 2:14 */`, symbol `one_one__213`, tuple `tuple_2_u32_u1_201326592`, enum `lang_OutputMode`. `builtin.zig_backend = 3` (`stage2_c`) |
| 0.17 ReleaseFast `one-0.17-fast.c` | 3,559 | 53 | `t0 = a0 + UINT32_C(1); return t0;` |

The design's "~226K lines for a one-line function" matches this Debug band (233k to 251k), not ReleaseFast. `zig_addo_u32` is `__builtin_add_overflow` in `lib/zig.h` (0.17 around line 1100, 0.18 around line 1102). The header is included from the Zig lib dir. It is not emitted next to the `.c`.

The corpus Debug C file is 14,480,675 bytes and 292,203 lines. The same functions show up, with different generic suffixes than LLVM (`generic__func_592` / `__func_593` in C, `__func_830` / `__func_831` in LLVM). `semantics.zig` ReleaseFast C is still 11,318,377 bytes, because the `@panic` contracts pull the panic runtime in. `one.zig` ReleaseFast stays at 53 lines only because that file has no panic.

The C is a hard CBMC target: `goto zig_block_N`, gcc builtins, vtables, and on the order of 200k lines of panic, Io, and allocator runtime, with Windows paths in the panic strings. CBMC, Frama-C, and ESBMC were not run. AWS uses CBMC on aws-c-common. That is a C project written for the tool, not Zig's C backend. A track F harness can start with no fork for a sliced, Debug, panic-freedom question. The proof does not transfer to ReleaseFast, and it does not feed `zvc` or `zv-own`, which consume schema v1 AIR.

## 5. ZIR and AST

**PARTIAL** as a zero-fork front end. **DEAD END** as a replacement for AIR.

### `ast-check -t` is not in the release compilers

Help text calls `-t` a debug option (`src/main.zig` usage for `ast-check`, 0.17 around line 5574). The implementation fatals when debug extensions are off (0.17 `src/main.zig:5680` and `:5745`). The renderer is `@import("print_zir.zig")`, which is a compiler file, not `std`.

Stock `zig ast-check -t research/corpus/corpus.zig`:

| Host | Exit | Diagnostic |
| --- | --- | --- |
| 0.16 | 1 | `error: -t option only available in builds of zig with debug extensions` |
| 0.17 | 1 | same |
| 0.18 | 1 | same |

### `zig dump-zir` is in the 0.17 and 0.18 release binaries, and it dumps a cache file

`src/main.zig` (0.17) puts `dump-zir` and `changelist` in `debug_usage`, and `usage` is `debug_usage` only when `enable_debug_extensions` (lines 119-128). The subcommand is still dispatched (line 504) because `dev.check(.dump_zir_command)` is true for `Env.full` (`src/dev.zig:73`). `cmdDumpZir` (`src/main.zig:5756` on 0.17, `:5745` on 0.18) opens a ZIR cache file, calls `Zcu.loadZirCache`, and renders with `print_zir.zig`.

| Command | Result |
| --- | --- |
| 0.16 `zig dump-zir <file>` | exit 1, prints the top-level `Usage: zig [command]` |
| 0.17 `zig dump-zir` with no path | exit `-1073741819` (`0xC0000005`), no diagnostic |
| 0.17 `zig dump-zir` on a text file | exit 1, `error: EndOfStream` |
| 0.18 `zig dump-zir` on a text file | exit 1, `error: EndOfStream` |

The command does not take source. A real cache file was not dumped in this pass. The text format is still compiler-private, and it is still ZIR.

### What `std` can see, run on the corpus

`std.zig.Ast.parse` and `std.zig.AstGen.generate` are public (`lib/std/zig/AstGen.zig:143`, `pub fn generate`). `probes/zir_walk.zig` reads the corpus at runtime, parses, generates ZIR, and counts tags. `zig build zir` from `probes/` runs it. The same source ran on all three hosts. The only port in the walker is the third argument of `Ast.parse`: 0.16 takes `Mode` (`lib/std/zig/Ast.zig:145` in the 0.16 tree), 0.17 and 0.18 take `ParseOptions`.

| | 0.16.0 | 0.17.0 | 0.18.0-dev.738+ae9a8acc7 |
| --- | --- | --- | --- |
| ast nodes | 888 | 888 | 888 |
| parse errors | 0 | 0 | 0 |
| zir instructions | 1327 | 1336 | 1336 |
| zir extra | 3254 | 3279 | 3279 |
| compile errors | false | false | false |
| declarations | 32, including one `generic` at line 132 and one `helper` at line 144 | same names and lines | same names and lines |

Arithmetic tags, identical on all three: `add` 19, `addwrap` 10, `add_unsafe` 3, `sub` 1, `subwrap` 1, `sub_sat` 1, `mul` 9, `mulwrap` 1. Those tags are documented on the instruction (`lib/std/zig/Zir.zig:167-178` in 0.17): `add` "asserts no integer overflow", `addwrap` is twos-complement, `add_sat` saturates, `add_unsafe` is "the same as `add` except no safety check." Safety is still chosen later, in Sema. ZIR does not carry the resolved type, the comptime value, or a copy of `generic` per instantiation. `helper` is still its own declaration here. LLVM inlined it away.

Tags that moved from 0.16 to 0.17, with the walk still exiting 0: `validate_deref` (1) is only on 0.16, `deref` (1) is on 0.17 and 0.18, `dbg_stmt` 236 vs 237, `load` 34 vs 33, `restore_err_ret_index_unconditional` 23 vs 32. 0.17 and 0.18 match each other on this file, tag for tag.

An early comptime scan that rejected any tag whose name contained the substring `safe` failed the build, because the tag is `add_unsafe`. The substring is not a new safety tag. The walker now counts the real tags instead of rejecting them.

## 6. Upstream intent

**DEAD END** as something to wait on. No public commitment that a hook or a stable dump would be accepted was found, and the last change to the dump went the other way.

Searches, and what they returned:

- Codeberg commit `f08a8f0fc` (route 1). Jacob Young, compiler contributor, 8 Oct 2026. The dedicated `--verbose-air` flag was deleted and replaced with `--debug-log` scopes that a release compiler strips at comptime.
- GitHub issue search `repo:ziglang/zig compiler plugin in:title`: `total_count` 0. https://api.github.com/search/issues?q=repo:ziglang/zig+compiler+plugin+in:title
- GitHub issue search `repo:ziglang/zig verbose-air`: 63 hits. The top ones are people using the flag to file compiler bugs, not a proposal for a stable export. Examples: https://github.com/ziglang/zig/issues/15728 (`a and b` lowered to `cond_br`, reproduced with `--verbose-air`) and https://github.com/ziglang/zig/issues/22419 (jacobly0, missed simplifications, AIR pasted from `--verbose-air`). The GitHub tracker is archived. New work is on Codeberg.
- Codeberg web search for a plugin, an AIR export, or an analysis API returned `Sema.zig`, the compile-commands PR (https://codeberg.org/ziglang/zig/pulls/35462, which is `compile_commands.json` for C, not AIR), and unrelated repositories. No proposal turned up.
- ZLS README, https://github.com/zigtools/zls : "The default branch of ZLS targets Zig master." and "When upgrading Zig, make sure to update ZLS too keep them in sync." Semantic analysis is listed as work in progress. ZLS is a language server that is rebuilt with the compiler. It is not an AIR service. Mitchell Hashimoto's 2022 notes (https://mitchellh.com/zig/sema) and the ziggit thread on `--verbose-air` (https://ziggit.dev/t/how-do-i-generate-ir-when-building-an-executable/3624) document the same debug-build-only dumps.
- `std.zig.Server` and `IncrementalDebugServer` have no AIR message (route 1).

Design rule 7 (`docs/design.md:329`) says to delete the fork if Zig gains an official dump or a plugin interface. Nothing found in this pass is that interface. A guess about whether a tiny PR would be merged is not evidence. The evidence on record is that the AIR dump was just reclassified as an unstable debug log.

## 7. Prior art

This is the reference class for the port budget. Person-days are not invented. The pins and the diffs that are public are the cost.

| Project | What they pin | What a bump costs, from their repo |
| --- | --- | --- |
| Kani | `rust-toolchain.toml` channel `nightly-2025-12-03`, components `llvm-tools`, `rustc-dev`, `rust-src`, `rustfmt`. https://github.com/model-checking/kani/blob/main/rust-toolchain.toml | Uses `rustc_private` (https://model-checking.github.io/kani/rustc-hacks.html). Issue https://github.com/model-checking/kani/issues/4471 : the automated bump from `nightly-2025-11-12` to `nightly-2025-11-13` required source changes. Commit `24ececc` bumped `nightly-2023-12-14` to `nightly-2023-12-15` and edited `operand.rs`. Release notes record toolchain bumps on 2025-08-06, 2025-11-05, and 2025-11-21. |
| Charon (Aeneas) | `charon/rust-toolchain`, channel `nightly-2026-09-17`, components `rustc-dev`, `llvm-tools`, `rust-src`, `miri`. https://github.com/AeneasVerif/charon/blob/main/charon/rust-toolchain | A rustc driver. Aeneas pins Charon rather than tracking rustc directly (`charon-pin`, `make setup-charon` in the Aeneas docs). The toolchain file is one nightly, not "stable". |
| Creusot | Changelog toolchain lines, because `rust-toolchain.toml` 404s on `main` and `master`. The file in commit `8f7fee4` is named `rust-toolchain`. | https://github.com/creusot-rs/creusot/blob/master/CHANGELOG.md bumps `nightly-2026-02-25`, `nightly-2026-04-21`, `nightly-2026-06-22`, and `2026-08-03`. Releases v0.11.0 (20 Apr 2026), v0.12.0 (12 Jun), v0.13.0 (30 Jul), v0.14.0 (12 Oct). Commit `8f7fee4` "Update toolchain to nightly-2025-11-13" touches 24 files, +37/−493. |
| Verus | `rust-toolchain.toml` channel `1.99.1` (a stable release), components include `rustc-dev` and `llvm-tools`. https://github.com/verus-lang/verus/blob/main/rust-toolchain.toml | They pin a stable compiler and still request `rustc-dev`. That is the component `rustc_private` needs (https://rustc-dev-guide.rust-lang.org/rustc-driver/external-rustc-drivers.html). The file was fetched. Their source was not audited line by line. |
| Clang plugins | A shared library loaded into one clang via `-fplugin` / `-Xclang -load`. https://clang.llvm.org/docs/ClangPlugins.html | The documented build uses that clang's include tree (`-I$BD/tools/clang/include`). The plugin is compiled against the clang that will load it. |
| ZLS | Zig master, by their README | "When upgrading Zig, make sure to update ZLS too". Same shape as a pin, on the Zig side. |

The class is: pin a compiler, carry a driver or a plugin that includes that compiler's private headers, and pay a source update when the pin moves. The movement is sometimes one nightly. Nobody in this set has a stable, versioned, compiler-independent IR that still contains the typed post-Sema program. They either live on the compiler's private API or they lower further (LLVM, C, Why3) and accept the loss.

The Phase 1 hook is the same class of cost, with a much smaller delta: three files in `compiler/hook.patch`, a target under 50 lines (`docs/design.md` fork rule 2), and one adapter that is the only file allowed to read `Air`. Kani's one-nightly bump that edits codegen is a bigger diff than that hook.

## Ranked options, to combine with Tracks A and B

1. **Keep the hook. Let A shrink how it is inserted, and let B isolate the adapter.** This is the only route that produces per-function, pre-legalize, standard-library-filtered, versioned JSON from a compiler whose optimize mode and backend do not change the export. The landscape did not find a zero-fork substitute for schema v1.
2. **A debug-log build as a patchless fallback, if A's problem is applying the hunk.** `-Dlog=debug` plus `--debug-log illegal-air` prints the same pre-legalize AIR, from `PerThread.zig:4540`, with zero source delta. The consumer would parse `Air.Print` text, would see every function including std, would read stderr, and would have no schema. It still requires a compiler rebuild per pin. It is a fallback for "the patch does not apply", not a replacement for the exporter.
3. **Start track F on stock `-ofmt=c -ODebug`, sliced.** CBMC or ESBMC can chase panic-freedom on a harness cut out of the 250k-line Debug C. Do this in parallel. Do not feed it to `zvc`. State the optimize mode in the claim. ReleaseFast deletes the check the proof is about.
4. **Keep the ZIR walker as a cheap pre-filter.** `probes/zir_walk.zig` already runs on 0.16, 0.17, and 0.18. It can see `add` versus `addwrap` versus `add_unsafe` before Sema, and it sees one generic, not two instantiations. Useful for a fast syntax and overflow-intent pass. It does not carry types.
5. **Do not add a custom backend to host the exporter.** More upstream edits than the hook, and the AIR is post-legalize.
6. **Do not block on an upstream PR.** Nothing found says one would be merged. If someone writes one later, the shape upstream just implemented is a debug-log scope, which route 1 already is, and which release builds strip. Design rule 7 still applies on the day a real interface exists.

## The strongest case against the current fork

Upstream already prints the AIR the hook exists to capture.

`f08a8f0fc` (8 Oct 2026) dumps pre-legalize AIR at `src/Zcu/PerThread.zig:4540` under `--debug-log illegal-air`, before `legalize`, with no patch, from any compiler built with `-Dlog=debug` or Debug optimize. The hook's job, at the return of `analyzeFuncBodyInner`, is to see that same stream a moment earlier and write it as schema v1 JSON, skipping the standard library. The patch is an output-format and a filter decision. It is not the only way to observe the instructions.

Stock `-ofmt=c` and `-femit-llvm-ir` go further: track F can start with no fork at all, on today's 0.16, 0.17, and 0.18 release compilers, for a Debug panic-freedom question that CBMC already answers for C.

That case has a boundary, and the measurements are the boundary. The debug log is human text, unversioned, unfiltered, on stderr, and the three release binaries we have print none of it (`--verbose-air` is a silent success on 0.16 and 0.17, and an unrecognized parameter on 0.18). ReleaseFast LLVM turns a checked add into `add nuw` and still exits 0, so a proof over stock IR drifts with `-O` and nobody gets an error. ZIR keeps overflow intent and loses types, comptime, and instantiations. A custom backend sees the stream only after legalize, and it costs more edits than `compiler/hook.patch`.

The fork stays the smallest edit that yields pre-legalize, per-function, backend-independent, schema v1 AIR. The case against it is that the information is already on a debug log, so the fork should stay as small as that observation: a filter and a JSON writer, which is what Tracks A and B are for, and not a second compiler.
