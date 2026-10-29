# zvc soundness review, round 2

Three confirmed holes. In each, `zvc` printed `proved` for a function that a Debug run panics in, or whose `zv.ensures` fails, on an input satisfying `zv.requires`. The reviewer's report and repro cases (`probe2.zig`, `probe3.zig`, `wit_*.zig`) were re-run first against 0.17.8 and every finding reproduced. This file keeps the findings in short and records the resolution of each; round 1 is `zvc-soundness-1.md`.

## Confirmed

1. **`Seq.sub` treats a wrapped `lo + n` as the end index.** The range obligation built `lo + n` with a 256-bit bit-vector add that wraps and carries no overflow obligation. `ghostCall` then skips the inlined body, so the runtime `@intCast` to `usize` was never an obligation. `seqSubWrap` and `seqSubMax` were `proved`; Debug panics at `zv.Seq.sub`.
2. **Ghost `Int.divFloor` does not reject `minInt(i256) / -1`.** The machine path obliges it; the ghost path obliged only a nonzero divisor. `ghostDivOv` was `proved`; Debug panics with `integer overflow` in `@divFloor`. `Int.mod` is not affected: `@mod(minInt, -1)` is 0 at run time.
3. **Every slice parameter is assumed shorter than `2^63 / elem_size`.** The model added `len <= 2^63/size - 1`. Safe Debug code builds longer slices. `lenBound`, `lenPlus`, `lenWrapEns` and `lenTriple` were `proved` and fail in Debug.

## Plausible, now fixed or decided

- `zv.assume` was a silent axiom.
- `ptr_cast` was an identity, and a later compare between widths aborted `zvc` in `term.eq`.
- Identical names: first function wins.
- Shift amounts were checked only through the compiler's panic branch.
- `@setRuntimeSafety(false)` additions were reported as a panic the binary does not raise.

## Resolution

Fixed in 0.17.12. Every case is a pinned verdict in `tests/zvc/soundness2.zig` (`soundness2.expect`); `tools/run_zvc.sh` runs the cross-function and gate-option ones again. The unsound ones are REFUTED or UNPROVEN there and never `proved`. The suites were exported again with a zig-zv built from master and run before and after: no pinned verdict of `search`, `cases`, `features` or `soundness` changed.

### 1. `Seq.sub` wrap: confirmed, fixed

The range obligation now includes that `lo + n` does not overflow the ghost width (`noOverflow`, the one `ghostArith` uses), alongside `0 <= lo`, `0 <= n`, `lo + n <= len`. With those and a sequence of at most `capacity` elements, both `@intCast` to `usize` and the slice in the body are in range, so the skipped body has no other check.

Audit of every ghost operation against its body in `src/zv.zig`: `Int.of`, `add`, `sub`, `mul`, `neg` go through `ghostArith`; `Int` comparisons cannot fail; `Seq.push` and `concat` oblige the capacity; `Seq.len` cannot fail; `Seq.at` obliges `0 <= i < len` (stricter than the body); `Seq.sub` fixed here; `divFloor` fixed in 2; `mod` has the zero check only, as its body does.

Deriving the obligations from the body mechanically was considered and not done: ghost values are single terms (a bit-vector, a sequence), not the struct the body works on, so the body cannot be run over them without giving up the native encoding that keeps the queries cheap. The guard is the audit above and a pinned case per operation family.

Regression: `soundness2.seqSubWrap` and `seqSubMax` REFUTED; `seqSubOk` (a real subsequence) proved.

### 2. Ghost `divFloor` overflow: confirmed, fixed

`divFloor` now obliges that the dividend is not `minInt(i256)` or the divisor is not `-1`, with the message of the other ghost width obligations. Regression: `ghostDivOv` REFUTED (inputs and the `-2^255` product shown); `ghostDivOk` (`-2^127 / -1`) proved; `ghostModOv` proved, because `@mod(minInt, -1)` does not panic.

### 3. Slice length axiom: confirmed, removed

The axiom (`boundsOf`) is gone; a slice parameter has any 64-bit length. It was not replaced by a counted assumption, because dropping it cost nothing: all four existing suites keep every pinned verdict, and zmoltcp's 7 verified functions are still proved (`zig build verify` equivalent, `--max-trusted 0`). Regression: `lenBound`, `lenPlus`, `lenWrapEns`, `lenTriple` are REFUTED with `len = 2^63` (and the third add of `lenTriple` at `len = 6148914691236517206`).

### Plausible items

- **`zv.assume`.** Visible now: a verdict that used one ends with `, assuming zv.assume at file:line`, and so do the verdicts of the `.verified` functions that rely on it (`useAssume` names the site in `assumeCheat`). The run ends with the distinct list, and `--max-assume N` (`max_assume` of `addVerifyGate`) fails the run above N. Regression: `soundness2.assumeCheat`/`useAssume` proved and named; `run_zvc.sh` checks `--max-assume 1` passes, `--max-assume 0` fails, and the text.
- **`ptr_cast`.** A cast between pointers to integers (or arrays of integers) of different widths is outside the fragment, so the verdict is UNPROVEN and `zvc` no longer aborts. Regression: `ptrCastLoad` UNPROVEN.
- **Duplicate names.** Calls resolve by name, and generic instances of one name legitimately share it inside a pack, so a duplicate is an error where it matters: a call to a name with two different functions (different function ids) is outside the fragment, never first-wins. Regression: `useLenBound` is UNPROVEN with both `tests/zvc/soundness2.zvp` and `tests/zvc/dup/soundness2.zvp` loaded (`soundness2.dup.expect`), and UNPROVEN in the main run because `lenBound` is refuted.
- **Shift amounts.** `shift` obliges `amount < bits` itself, with the message of the compiler's check. `shiftOff` (`@setRuntimeSafety(false)`, no panic branch in the AIR) was `proved` before this change and is REFUTED now; `shiftU8`, `shiftU24`, `shiftI65`, `shiftU96` REFUTED; `shiftI128` (a `u7` amount) proved.
- **`@setRuntimeSafety(false)`.** The AIR exposes it: the checked forms are `add_safe`, `sub_safe`, `mul_safe`, and the plain `add`, `sub`, `mul` are the unchecked ones (also what the compiler uses for its own loop counters). An overflow there is neither a panic nor a defined wrap in Zig (undefined behaviour), so wrapping was not modelled, because a proof under a wrap would not hold for the optimised binary. The obligation stays, of a new kind `unchecked`, and its failure makes the verdict UNPROVEN, never REFUTED: `wrapOff` is UNPROVEN with the counterexample shown.

### Completeness gaps

Unchanged and still `UNPROVEN` rather than wrong: indirect calls, AIR ops without an encoding (`byte_swap`, `abs`, `add_sat`, `shl_with_overflow`, `set_union_tag`), globals, error-set parameters, integers wider than 128 bits as values, loops without `zv.decreases` (partial correctness).
