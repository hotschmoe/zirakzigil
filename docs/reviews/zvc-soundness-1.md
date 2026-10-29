# zvc soundness review

Two confirmed unsoundnesses. In both, `zvc` prints `proved` and exits 0 for the function, and a Debug `zig test` of that function panics on an input that satisfies `zv.requires`.

Packs were exported with `tools/zvc_export.sh` and `ZIG_ZV=C:\Users\hotschmoe\zr\v2\work2\zig-air\zig-out\bin\zig.exe` (ghost on, target `x86_64-linux-gnu`). `zvc` was `repo/zig-out/bin/zvc.exe` with `ZV_Z3` pointing at Z3 4.16.0. Runtime checks used stock Zig 0.17.0 in Debug.

## Confirmed

### 1. A call summary does not include "the callee does not panic"

`summarize` builds the postcondition from `zv.ensures` only. The path condition of the return, which is where overflow and other safety goals have been assumed, is dropped. `call` then assumes that postcondition and never asks the solver whether the callee's safety obligations hold. `summaryHook` does this for every `.verified` and `.trusted` callee, before those obligations are discharged. `--only` never discharges a callee it does not print, so the process can exit 0.

Root cause:

- `repo/src/zvc/vc.zig:1478-1496` (`summarize`): `post` is `result == ensures-value && ensures-ok`, or `true` when some non-constant return has no `ensures`. `r.state.pc` is not conjoined.
- `repo/src/zvc/vc.zig:1033-1037` (`call`): the only obligation is the callee's `zv.requires`. The postcondition is assumed.
- `repo/src/zvc/program.zig:89-103` (`summaryHook`): `.verified` and `.trusted` both supply a summary. A summary is returned even when the callee's own obligations are satisfiable failures. Discharge happens later, and only for functions `main` actually verifies (`repo/src/zvc/main.zig:92`).

#### 1a. `useInc` calls a `.verified` callee that overflows

`cases/probe.zig`:

```zig
pub fn inc(x: u8) u8 {
    return zv.ensures(x + 1, true);
}
pub fn useInc(x: u8) u8 {
    return inc(x);
}
```

Both are `.verified`.

`zvc --only useInc --src cases cases/out/probe.zvp` (exit 0):

```
proved   probe.useInc: 0 obligations, 0 ms

zvc: 1 proved, 0 refuted, 0 unproven
```

The same pack, without `--only`, refutes the callee and still proves the caller:

```
REFUTED  probe.inc: 1 obligations, 13 ms
    cases/probe.zig:61:25: integer overflow in `+` on u8
      inputs: x = 255;
proved   probe.useInc: 0 obligations, 0 ms
```

Debug `zig test` (`cases/run_panic.zig`, `--test-filter useInc`, exit 3):

```
thread panic: integer overflow
cases/probe.zig:61:25: in inc
    return zv.ensures(x + 1, true);
cases/probe.zig:65:15: in useInc
    return inc(x);
cases/run_panic.zig:9:21: in test.useInc overflows
    _ = probe.useInc(255);
```

`useInc(255)` is a legal call (no `zv.requires`). It panics inside `inc`.

#### 1b. `useBadAdd` calls a `.trusted` callee that overflows

`cases/probe.zig`: `badAdd` is `.trusted` and is `return x + 1`. `useBadAdd` is `.verified` and returns `badAdd(x)`. A trusted function is not discharged at all, so a pack whose only verified function is the caller exits 0.

`zvc --only useBadAdd --src cases cases/out/probe.zvp` (exit 0):

```
proved   probe.useBadAdd: 0 obligations, 0 ms

zvc: 1 proved, 0 refuted, 0 unproven
```

Debug `zig test` (`cases/run_panic.zig`, exit 3):

```
thread panic: integer overflow
cases/probe.zig:52:14: in badAdd
    return x + 1;
cases/probe.zig:56:18: in useBadAdd
    return badAdd(x);
cases/run_panic.zig:5:24: in test.useBadAdd overflows
    _ = probe.useBadAdd(255);
```

`badAdd` has no `zv.ensures`, so the summary postcondition is `true` (`vc.zig:1495`). The caller learns that the call returns, which is the fact the panic contradicts.

### 2. Ghost `zv.Int` is 256 bits in the proof and `i128` when that proof is run

`zvc` exports with `ghost = true` (`tools/zvc_export.sh`). In that build `zv.Int` is an `i128` and `+`, `-`, `*` panic on overflow (`repo/src/zv.zig:72-93`). The verifier widens every operand to a signed 256-bit vector and only obliges overflow of that width (`repo/src/zvc/term.zig:12`, `repo/src/zvc/vc.zig:1218`, `repo/src/zvc/vc.zig:1229-1232`, `repo/src/zvc/vc.zig:1249-1252`). Values that fit in 256 bits and overflow `i128` are proved.

A Debug build with `ghost = false` deletes these operations, so the panic is the ghost build `zvc` analyzed. Reproduction: `cases/run_ghost.zig` with `-Mzv_options=cases/opts_true.zig`. Each test exits 3.

#### `ghostMul`

`cases/ghost.zig:11-14`. `zvc --only ghostMul --obligations` (exit 0):

```
proved   ghost.ghostMul: 2 obligations, 79 ms
    cases/ghost.zig:12:45: a specification outgrows 256-bit ghost integers
    cases/ghost.zig:13:22: postcondition (zv.ensures) may not hold

zvc: 1 proved, 0 refuted, 0 unproven
```

Both obligations were discharged. The 256-bit product of two `u64`s fits. The `i128` product does not.

```
thread panic: integer overflow
repo/src/zv.zig:90: in mul
        return .{ .v = a.v * b.v };
cases/ghost.zig:12:45: in ghostMul
    const ok = !zv.ghost or zv.Int.of(a).mul(zv.Int.of(b)).ge(zv.Int.of(0));
cases/run_ghost.zig:5:23: in test.ghostMul overflows
    _ = ghost.ghostMul(std.math.maxInt(u64), std.math.maxInt(u64));
```

#### `ghostAdd`

`cases/ghost.zig:21-25`, requires `y >= 0`. Full-pack line: `proved ghost.ghostAdd: 2 obligations, 27 ms`.

```
thread panic: integer overflow
repo/src/zv.zig:84: in add
        return .{ .v = a.v + b.v };
cases/ghost.zig:23:45: in ghostAdd
    const ok = !zv.ghost or zv.Int.of(x).add(zv.Int.of(y)).ge(zv.Int.of(x));
cases/run_ghost.zig:9:23: in test.ghostAdd overflows
    _ = ghost.ghostAdd(std.math.maxInt(i128), 1);
```

`y = 1` satisfies `zv.requires`. `maxInt(i128) + 1` overflows `i128` and fits in 256 bits, and the sum is `>= x`, so the ensures is true in the model.

#### `ghostNeg`

`cases/ghost.zig:16-19`. Full-pack line: `proved ghost.ghostNeg: 2 obligations, 14 ms`.

```
thread panic: integer overflow
repo/src/zv.zig:93: in neg
        return .{ .v = -a.v };
cases/ghost.zig:17:45: in ghostNeg
    const ok = !zv.ghost or zv.Int.of(x).neg().eq(zv.Int.of(0).sub(zv.Int.of(x)));
cases/run_ghost.zig:13:23: in test.ghostNeg overflows
    _ = ghost.ghostNeg(std.math.minInt(i128));
```

Negating `minInt(i128)` overflows `i128`. The same negation fits in 256 bits, so `neg(x) == 0 - x` is proved for every `x`.

## Plausible, not confirmed

These match a wrong encoding, but the cases came back `UNPROVEN` or `REFUTED`, so they are not confirmed false proofs.

- `term.mask` (`repo/src/zvc/term.zig:101-103`) returns all 256 bits when `bits >= 128`, so it is not `2^bits - 1`. `division` uses that as the signed divisor `-1` (`repo/src/zvc/vc.zig:830-834`). `probe.divMin128` and `probe.div128` (`@divTrunc` on `i128`) did not become false proofs: the safety check mentions `minInt(i128)`, the adapter stores that as an undecoded text constant, and zvc stops with `constant -170141183460469231731687303715884105728`. If that constant were encoded as a 128-bit literal, the internal overflow check would compare it with a different all-ones value and could fold away.
- `term.signed` (`repo/src/zvc/term.zig:105-109`) shifts by `128 - bits` and then arithmetic-shifts an `i256`, whose sign bit is bit 255. Sign extension does not happen. Constant folding of signed division and signed compares uses this. Sema folds the same constant operations before AIR, so the fold did not show up as a proved function. It does show up in counterexamples: an `i8` value `-1` is printed `255`, an `i32` `-5` is printed `4294967291`, and an `i8` `-2` is printed `254` (`probe.cmpSignWrong`, `probe.floorWrong`, `probe.divSignWrong`). The verdicts on those functions were still the right refutations, because the solver saw real bit-vectors.
- Error codes are `1 + Wyhash(name) % 65534` (`repo/src/zvc/vc.zig:338-340`). `E204` and `E349` collide (code 51296). `probe.errCollide` was `UNPROVEN` (`comparison of a non-integer`), so the collision never became a proof that `error.E204` and `error.E349` are the same.
- `zv.Seq` is unbounded in the solver and has capacity 64 at runtime (`repo/src/zv.zig:123-141`). `ghost.seqTooLong` pushes 65 times under an invariant `s.len() == i`. zvc rejected the loop (`a store through an unknown pointer inside a loop`) instead of proving it.
- Slice and array element stores are `UNPROVEN` (`store through elem_ptr` in `probe.elemWrite`, `probe.aliasWrite`; `modifiedCells` returns unsupported rather than ignoring the store, `repo/src/zvc/vc.zig:1345-1369`). An aliasing or lost-update false proof needs that store to be treated as a no-op. It is not.

## Completeness gaps

These are functions zvc refuses or refutes on an abstracted state. They are not false proofs.

- `@shlExact` lowers to `shl_with_overflow`, which `step` does not handle (`probe.shlExactU8`). `@abs` is the same (`probe.absI32`, `instruction abs`).
- `array_to_slice` (`probe.reslice`), `error_cast` (`probe.catchUnreach`), and aggregate constants such as `"\x01\x02".*` (`probe.arrayWrite`) are unsupported.
- `i128` literals above 64 bits stay text (`probe.div128`), so signed 128-bit division is outside the fragment even though `u128`/`i128` addition is checked and was refuted (`probe.add128`, `probe.addI128`).
- A `zv.requires` whose argument indexes a slice is rejected (`zv.requires must open the function body`) because the bounds check is an obligation before the contract is seen. Rewriting the requires to a length test lets the ensures through.
- Call postconditions omit the callee's branch condition. `probe.usePick` requires `x == 2` and ensures `pick(x) == 1`, which is false (`pick` returns `x` on that path). zvc refuted it. The same weakness means a true postcondition that depends on which branch ran is not implied by the summary.
- Loops without `zv.decreases` are only partially correct. Havoc plus a weak invariant also reports overflow on states a concrete execution does not reach (`probe.forDrop`, `probe.deferBump`); the tool marks those with the loop-abstraction note.

Encodings that were tried with a deliberately false ensures and came back `REFUTED`: signed compare and division, `@divFloor` / `@mod` / `@rem`, arithmetic right shift, `u8` ranges that sit above 127 and `i8` ranges that include negatives, slice tails (`xs[1..][0] == xs[1]`, including across a `.verified` call to `first`), `xs[1] == xs[0]`, a three-way `switch` join, past-the-end and empty-slice indexes, null unwrap, a `u5` cast used as a shift amount, and a `u24` shift by 24. Slice offset substitution in `term.Subst` matched the runtime on `probe.useFirstWrong` / `probe.useFirstRight`.

## Resolution

Fixed in 0.17.8. Every case below is a pinned verdict in `tests/zvc/soundness.zig` (`soundness.expect`), and `tools/run_zvc.sh` runs the cross-function ones again with `--only`. Each "proved while it panics" case was also compiled and run in Debug against the fix to check that the verdict and the run agree.

### 1. A call summary does not include "the callee does not panic": confirmed, fixed

Root cause as reviewed: a summary is the callee's contract only, and nothing made sure the callee's own obligations were discharged in the run that relied on it.

Fix: a proof that uses a callee's contract is final only when the callee is proved too.

- `Vc.relied` records the summaries a function used. The driver (`main.zig`) proves every `.verified` function reachable that way, transitively, whatever `--only` selected; they are printed as `(relied on)` and counted. A caller whose `.verified` callee is refuted, unproven or not checked is `UNPROVEN` with `relies on X, which is not proved`.
- A `.trusted` callee is an assumption by design (docs/design.md, assurance levels): its contract and that it does not panic when its precondition holds are taken on faith, because nothing machine-checks it. The verdict says so (`proved ..., assuming trusted: X`), the run ends with the list, `zvc --max-trusted N` fails the run above N, and `addVerifyGate` takes `max_trusted` for the same ratchet.
- The summary stays the contract. It need not carry "does not panic", because that is exactly the callee's own proof, now required. When the callee is verified it holds under the precondition, which the caller must establish.

Regression: `soundness.useInc` (1a) is UNPROVEN and `soundness.inc` REFUTED, with and without `--only`; `soundness.useUseInc` is UNPROVEN through two levels; `soundness.useSafeInc` is the proved control. `soundness.useBadAdd` (1b) is proved assuming `soundness.badAdd`, and `run_zvc.sh` checks that `--max-trusted 0` fails and `--max-trusted 1` passes.

### 2. Ghost `zv.Int` is 256 bits in the proof and `i128` when run: confirmed, fixed

Root cause: two widths, 256 in `term.ghost_bits` and 128 in `zv.Int`.

Fix: `zv.Int` is an `i256` (`zv.ghost_bits`), the width the solver obliges. Zig 0.17 compiles `i256` arithmetic in Debug, with overflow panics, on every target of the matrix. The ghost operations of `Int.of` on a literal now read `i256` constants. `ghostMul`, `ghostAdd` and `ghostNeg` of the review are proved and no longer panic; the reproductions from the review pass in Debug.

Regression: `soundness.ghostMul`, `ghostAdd`, `ghostNeg` (proved, run in Debug without a panic) and `ghostMulWide` (REFUTED at 256 bits, and it panics when run).

### 3. Plausible, now treated as fixed

- `term.mask` for bits of 128 or more: returned 256 ones, so a literal was never masked and `-1` as the signed divisor was the wrong constant. Now `2^bits - 1` for every width up to 256. `soundness.div128` and `divMin128` are REFUTED on the overflow of `minInt(i128) / -1`.
- `term.signed`: shifted by `128 - bits` in a 256-bit integer, so it did not sign-extend. Now by `256 - bits`; the arithmetic-shift fold used a `u7` amount and is a `u8`. A signed counterexample prints signed: `soundness.cmpSign` shows `x = -1` (checked in `run_zvc.sh`).
- Error codes: `1 + Wyhash % 65534` collided (`E204`, `E349`). Codes are now numbered in the order the program names its errors, so two errors never share one. Comparing two errors for equality is supported, which is what makes a collision observable: `soundness.errCollide` is REFUTED, `errSame` proved.
- `zv.Seq`: capacity 64 when run, unbounded in the proof. Now `Seq.push` and `Seq.concat` oblige the capacity (`term.seq_capacity`, `zv.Seq.capacity`). `soundness.seqFull` (64 pushes) is proved and `seqOverfull` (65) REFUTED; the latter panics when run. A ghost operation inside a loop no longer makes the loop's stores unknown.
- i128 constants past 64 bits were left as text and made the function unsupported. Decimal text of an integer type is now a bit-vector literal.

### Audit beyond the review

- Confirmed, new: **a signed constant between 2^63 and 2^64 in a type wider than 64 bits was read as negative.** The pack stores an integer constant sign-extended to 64 bits, and the adapter wrote an unsigned 64-bit value as is, so `2^63` and `-2^63` were the same record. `soundness.bigPos`: `requires(x == 9223372036854775808)` on an `i128`, then `if (x > 0) 255 else 0` and `+ 1` was `proved` while `bigPos(9223372036854775808)` panics. Fixed in the adapter (`compiler/src/zv_air/adapter.zig`: such a constant stays text, which `zvc` now decodes); `bigPos`, `bigNeg`, `bigWide` (`i65`) and `bigU128` are REFUTED, and `bigPosIs`, `bigNegIs` proved. This needs a rebuilt zig-zv; the checked-in packs were exported again.
- A `bit_cast` of a boolean to `u1` (`@intFromBool`) kept the boolean sort, so the next cast aborted `zvc` (a crash, not a false proof). It converts now: `soundness.boolInt` is REFUTED.
- A branch of a `cond_br` or a `switch_br` that fell through used to be dropped silently; it is now outside the fragment. The AIR never produces one; the check is there so a change in it cannot become a false proof.
- Looked at and sound: obligations are never skipped on `break`, `continue`, early `return`, `try`, `defer` and `errdefer` paths (probes `breakEarly`, `contOv`, `loopRet`, `deferOv`, `errdeferOv`, `innerBreak`, `labeled`); an instruction `zvc` does not model is outside the fragment, not a no-op; a field never set is a fresh symbolic value, never a default. `zv.assume` is an assumption by design and stays unreported.
