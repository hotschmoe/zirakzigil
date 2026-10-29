# Phase 1 results (M1 to M3)

Measured on Zig 0.17.0 (`7647adab`), Windows 11 and Ubuntu 24.04 under WSL2, 24 cores.

## M1: zig-zv builds, output unchanged

- `tools/build_zig_zv.sh` builds `zig-zv` in about 8 minutes on both Windows (Git Bash) and Linux (WSL), peaking near 9 GB. Upstream declares an 8 GB bound for that compiler step, so the build runner reports "memory usage peaked ... exceeding the declared upper bound". The binary is installed and works. The script accepts exactly that one error, and only after checking that the binary reports the pinned version and exports a smoke program. Any other error fails it. `--maxrss` does not help (it only affects scheduling) and editing upstream `build.zig` would count against the hook.
- Hook: `hook.patch` changes 12 lines in 3 files (`src/main.zig` +6, `src/Compilation.zig` +5, `src/Zcu/PerThread.zig` +1). Our code is `src/zv_air/{adapter,export}.zig`.
- No behaviour change: `tools/compare_stock.sh` builds the same program with a stock tree (same tag, same flags, no patch), with `zig-zv`, and with `zig-zv --zv-air-out`, and compares diagnostics plus the bytes of stripped x86_64 objects from the self-hosted backend for a COFF and an ELF target. Chosen because it needs no LLVM and covers analysis, codegen and the linker's object writer. All identical on Windows and on Linux (12 of 12 checks each). Unstripped ELF objects differ only in an embedded cache-directory hash that depends on the compiler binary.
- Windows limitation: a compiler built without LLVM cannot link executables on Windows (`invalid value ... for weak external symbol` while reading `compiler_rt.lib`). The stock no-LLVM build fails identically, so this is upstream, not the patch. `zig-zv build` therefore works under Linux/WSL; on Windows use direct `-fno-emit-bin` runs.

## M2: examples/search.zig

All seven pub functions export (the plan said six; `scale` is the seventh), plus `zv.mul`. `zv.requires`, `zv.ensures` and `zv.invariant` appear as inline callees (`dbg_inline_block`) with the source line of the call. 9 files, 429 instructions, 0 unsupported, round-trip passes. Comparison with the zvc parser (`tools/air_vs_zvc.py`):

```
function       level     zvc                                AIR
midpointNaive  verified  2 params; 1 requires, 1 ensures    line 26; 2 params; 1 requires, 1 ensures; 2 safety-checked ops
midpoint       verified  2 params; 1 requires, 1 ensures    line 32; 2 params; 1 requires, 1 ensures; 3 safety-checked ops
lowerBound     verified  2 params; 1 ensures, 1 invariant   line 40; 2 params; 1 ensures, 1 invariant; 9 safety-checked ops
withdrawNaive  verified  2 params; 1 ensures                line 56; 2 params; 1 ensures; 2 safety-checked ops
withdraw       verified  2 params; 1 requires, 1 ensures    line 61; 2 params; 1 requires, 1 ensures; 3 safety-checked ops
clampedAdd     verified  3 params; 1 ensures                line 68; 3 params; 1 ensures; 5 safety-checked ops
scale          checked   outside subset (line 79: type 'zv' outside zvc subset) line 79; 2 params; ; 1 safety-checked ops
```

Contract counts agree wherever zvc parses the function. Differences:

- AIR covers `scale`, which zvc rejects as outside its subset; types and generics are already resolved (`zv.mul` shows up as its own instance).
- zvc sees source constructs; AIR shows what the compiler made of them: safety checks as `*_safe` instructions, bounds checks as `cond_br` into `debug.defaultPanic`, and each contract as a call whose body is the panic branch. These are exactly the obligations zvc derives by hand.
- Parameter names are not in the export (AIR has only ZIR parameter indexes). Phase 2 can recover them from `dbg_arg_inline` in the inline bodies or by adding names from ZIR to the adapter.
- Functions only appear if the compiler analyzes them. `withdrawNaive` is called by no test, so it needs `tools/air_all.zig` as the root.

## M3: zmoltcp (37.5k lines)

Driven by `tools/zv_air.sh OUT test` (`ZV_AIR_OUT` inherited by the compiler runs that `zig build` spawns; no `build.zig` change, no extra hook lines).

| | Linux (`zig build test`) | Linux (direct check) | Windows (direct check) |
| --- | --- | --- | --- |
| function instances exported | 6188 | 6186 | 6186 |
| of which generic instances | 1020 | 1020 | 1020 |
| instructions | about 618k | 617,881 | 617,881 |
| distinct tags seen | 111 | 111 | 111 |
| unsupported | 0 | 0 | 0 |
| round-trip through `air_read.py` | pass | pass | pass |
| time, export off to on | 10.16 s to 10.6 s | 1.26 s to 1.70 s | 1.27 s to 3.8 s |

"Direct check" is `zig-zv test -fno-emit-bin` on `src/root.zig`, the plain-check baseline. Output is 83 MB of JSON; the file set is identical across runs. The extra time is formatting type and value strings and writing one file per function; Windows pays more for creating 6186 files. Unsupported tags drive to zero here because the adapter decodes everything pre-legalization except the tags listed as unsupported in `adapter.zig` (shuffles, wasm, GPU, legalize-only); none occur in zmoltcp.
