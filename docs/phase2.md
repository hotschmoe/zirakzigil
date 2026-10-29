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

Each obligation is `pc => goal` and is then assumed (assert, then assume), so one failure is reported once and not again in everything after it. Loops with no invariant are cut with the trivial one; a counterexample that passes through a cut loop is marked, because the loop abstraction may have made it unreal. Termination is checked where a loop states a measure (below).

Terms are hash-consed with constant folding (`src/zvc/term.zig`). Integers up to 128 bits are bit-vectors, booleans are Bool, slices are arrays from 64-bit indexes (a slice parameter is assumed to fit the address space), and a struct, optional or error union is kept apart field by field.

## Beyond one function (M2)

**Calls.** A call to a `.verified` (or `.trusted`) function does not run its body. Each function is run once and leaves a summary: its `zv.requires` conditions, and, over its `zv.ensures` calls, the disjunction of "the returned value is what that path computed and its condition holds". A return no `ensures` covers promises nothing, except one that returns a literal (an error code, `null`, a constant), which promises exactly that. At a call, the arguments replace the parameters in the summary, a callee slice is read at the caller's slice offset, the callee's internal variables are renamed per call, the precondition becomes an obligation (`precondition of X may not hold`) and the postcondition becomes an assumption. A callee that is `.checked`, absent, outside the fragment or recursive makes the caller UNPROVEN, with that as the reason. Loops inside a callee contribute through their invariants only.

**Inlined contracts.** A `zv.requires` inside an inlined callee (`inline fn`, or a call the compiler inlined) is an obligation of the caller, its `zv.ensures` is re-proved there and assumed after.

**Termination.** `zv.decreases(m)` placed after a loop's invariants states a measure: an unsigned integer, or a ghost `Int`. At the end of every iteration it must be smaller than at the head (several are ordered lexicographically); a ghost measure must also stay non-negative. A loop with no `decreases` leaves the function `proved`, with a note that only partial correctness holds; with `--total` the function is UNPROVEN.

**Ghost integers and sequences.** `zv.Int` and `zv.Seq` exist only in ghost builds (`zv.ghost`), so a specification uses them behind it: `zv.ensures(r, !zv.ghost or zv.Int.of(r).le(zv.Int.of(x).mul(zv.Int.of(y))))`. `zvc` reads their operations as mathematics. A ghost integer is a signed 256-bit bit-vector, not a solver `Int`: mixing `bv2nat` with integer arithmetic made Z3 time out on `a + b <= 0xffffffff` implies no wrap, where the pure bit-vector form takes 20 ms. An operation that leaves 256 bits is an obligation, so a specification never wraps silently. When run, `Int` is an `i128` and `Seq` holds up to 64 elements.

**Structs, optionals, errors.** A struct value is a set of fields created on first use, named from the source (`p.a`); optionals and error unions keep their tag and payload apart; `try`, `orelse`, `.?`, `switch` on integers, returning a struct and passing it to a verified function are covered by `tests/zvc/features.zig`.

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

`tests/zvc/` holds the packs of `examples/search.zig`, `tests/zvc/cases.zig` (the rules of one function, 32 cases proved with a guard and refuted without it) and `tests/zvc/features.zig` (calls, structs, errors, termination, ghost values, `switch`, 36 cases), and the pinned verdicts (`*.expect`). A verdict that changes is a soundness or completeness change of `zvc` and is reviewed as one. The packs are checked into the repository so CI needs neither the 8-minute compiler build nor 9 GB. `tests/zvc/SOURCES` pins the sources they were exported from (`zvc --pins`: a changed source is an error, because the verdicts would be about another program), `tools/zvc_repin.sh` exports them again, and the on-demand canary re-exports them with a fresh `zig-zv` and compares byte for byte. A function the manifest marks `.verified` that the packs do not contain is reported UNPROVEN, so a claim cannot escape by being left out of the export.

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
