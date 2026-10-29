# Phase 2: `zvc` on AIR

`zvc` reads zig-zv AIR packs ([phase1.md](phase1.md)) through the `zv_air` module, finds the functions whose assurance manifest says `.verified`, derives verification conditions with Zig's semantics, and discharges them with Z3 as an external process speaking SMT-LIB2 over stdin and stdout. It links no compiler code and no solver library (design rule 5).

```
tools/zvc_export.sh OUT_DIR FILE.zig...     AIR pack of each file (Debug, ghost on, fixed target)
zig build zvc                                zig-out/bin/zvc
zvc --src DIR [--expect FILE] PACK|INDEX_DIR...
tools/run_zvc.sh                             the suite: pinned packs against pinned verdicts (CI)
tools/install_z3.sh DEST                     the pinned Z3 release, checked against its digest
```

The solver is found by `--z3`, then `ZV_Z3`, then `z3` on `PATH`. Packs must be exported in Debug or ReleaseSafe: in the other modes the contracts compile out and the safety checks are not in the AIR, so `zvc` refuses the pack.

## What the AIR already says

Zig lowers its own safety checks to ordinary control flow, so most obligations are visible without knowing the language rules:

- bounds, division by zero, signed division overflow, unwrapping null, `unreachable` and `@panic` are a `cond_br` whose failing branch calls a `noreturn` function. Reaching that call is the obligation.
- overflow of `+ - *` is the opcode (`add_safe`, `sub_safe`, `mul_safe`; the unchecked forms are obligations too, since overflow there is undefined) and narrowing casts are `int_cast_safe`.
- a contract is a `dbg_inline_block` whose callee is `zv.requires`, `zv.ensures` or `zv.invariant`; its operands are the `dbg_arg_inline` instructions that open the block. The panic branch inside it is not interpreted: the contract is read for what it means.

## Verification conditions

One function is run symbolically (`src/zvc/vc.zig`):

| AIR | Meaning |
| --- | --- |
| instruction result | a `Value`: a term, or a slice (`mem`, `off`, `len`), array, optional, error union, or struct whose fields are created on first use, so no layout is needed |
| `alloc`, `load`, `store`, field and slice pointers | memory cells holding the mutable locals; a pointer is a place (cell and path) |
| `block`, `br` | the block collects its incoming paths and joins them: path condition by `or`, cells and result by if-then-else |
| `cond_br` | both branches run under `pc and c` and `pc and not c`; a branch whose condition folds to false is skipped |
| `call` to a `noreturn` function | obligation `pc => false`, with the panic named (`index out of bounds`, `division by zero`, a `@panic` message) |
| arithmetic, casts, shifts | bit-vector terms, exact; overflow is `extend(a op b) == extend(a op b truncated)` in a wider vector |
| `zv.requires(p)`, `zv.assume(p)` | `pc := pc and p`; `requires` must open the function body |
| `zv.ensures(v, p)` | obligation `pc => p`; the block's value is `v` |
| `loop` with `zv.invariant(p)` | obligation that `p` holds on entry; every cell the body stores to is havoced; `p` is assumed; one iteration runs; at `repeat`, obligation that `p` holds again; exits leave with the havoced state, `p` and the exit condition |

Each obligation is `pc => goal` and is then assumed (assert, then assume), so one failure is reported once and not again in everything after it. Loops with no invariant are cut with the trivial one; a counterexample that passes through a cut loop is marked, because the loop abstraction may have made it unreal. Termination is not checked yet.

Terms are hash-consed with constant folding (`src/zvc/term.zig`). Integers and booleans are bit-vectors and Bool; slices are arrays from 64-bit indexes; a slice parameter is assumed to fit the address space.

## Output

```
REFUTED  search.midpointNaive: 2 obligations, 23 ms
    examples/search.zig:28:21: integer overflow in `+` on u32
         28 |     const mid = (lo + hi) / 2;
            |                     ^
      inputs: lo = 1; hi = 4294967295 (0xffffffff);
```

A refuted obligation prints the function, the position the AIR carries mapped to `file:line:col`, the obligation, the source line, and concrete values of the inputs (parameter names come from the source) and of the named locals at that point. Inputs are shrunk toward 0, 1, 2 and the extremes, so counterexamples are the plain ones. Verdicts per function: `proved`; `REFUTED` (some obligation has a counterexample); `UNPROVEN` (a construct outside the supported fragment, with the position and reason, or a solver timeout). Exit status is 0 only when everything is proved, or, with `--expect FILE`, when every verdict equals the pinned one.

## The suite

`tests/zvc/` holds the packs of `examples/search.zig` and `tests/zvc/cases.zig` and the pinned verdicts (`*.expect`). `cases.zig` is 32 functions that each exercise one rule on both sides: proved with a guard, refuted without it. A verdict that changes there is a soundness or completeness change of `zvc` and is reviewed as one. The packs are checked into the repository so CI needs neither the 8-minute compiler build nor 9 GB; `tests/zvc/SOURCES` pins the sources they were exported from, and the on-demand canary re-exports them with a fresh `zig-zv` and compares byte for byte.

## Spike parity (M1)

Every verdict of the Python spike on `examples/search.zig` reproduces from AIR:

| function | spike | zvc on AIR |
| --- | --- | --- |
| `midpointNaive` | rejected, `lo=1, hi=4294967295` | refuted at the `+`, `lo = 1; hi = 4294967295` |
| `midpoint` | verified | proved |
| `lowerBound` | verified | proved |
| `withdrawNaive` | rejected | refuted at the `-` |
| `withdraw` | verified | proved |
| `clampedAdd` | verified | proved |

The whole file takes 0.8 s end to end (Z3 4.16.0, Windows), of which the solver is about 0.7 s.
