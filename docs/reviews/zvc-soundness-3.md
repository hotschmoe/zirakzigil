# zvc soundness review, round 3

Two confirmed false proofs, both from treating a reinterpretation of memory as a copy of fields, and two crashes of the verifier. The reviewer's report and cases (`probe3.zig`, `probe3b.zig`, `show_*.zig`) were re-run first against 0.17.13 and every finding reproduced. Round 2 held: none of its fixes came back `proved`. This file keeps the findings in short and records the resolution of each; the earlier rounds are `zvc-soundness-1.md` and `-2.md`.

## Confirmed

1. **`@bitCast` between aggregates is a field-index copy.** Only a scalar operand was checked; a struct was passed through, and `aggregate_init` is field-wise, so field 0 of `A16 { lo: u8, hi: u8 }` became field 0 of `B16 { n: u4, m: u4, rest: u8 }` whatever the bit layout. `packBit` and `packFieldM` were `proved` with 0 obligations; Debug fails their `zv.ensures` (`packBit(0x10, 0xab)`).
2. **`@ptrCast` between pointers to different layouts is an identity.** `reinterprets` flagged only integer pointees of different widths and looked through one array level. `packPtr` (`*A16` to `*const B16`) was `proved`; Debug fails it.

## Plausible, now fixed or decided

- Verifying a comptime-generic instance panicked at `params[index].ty` (index out of bounds): comptime parameters appear as `.arg` instructions the signature does not list.
- A caller of a falsely proved function (`usePack`) aborted in `term.eq` through `agrees`, which compared values of different sorts.
- `--max-assume 0` printed `proved` and then failed the run.
- `--only ghostMin` also selected `ghostMinMul`; the same substring match was in `zv-own` and in `zv-air dump --fn`.
- Sentinel slices: `xs[xs.len] == 0` on `[:0]const u8` was refuted (a true postcondition).
- A crash anywhere aborted every verdict of the run.

## Resolution

Fixed in 0.17.14. Every case is a pinned verdict in `tests/zvc/soundness3.zig` (`soundness3.expect`), with controls that show what the fixes still accept. The suites were run before and after: no pinned verdict of `search`, `cases`, `features`, `soundness` or `soundness2` changed, zmoltcp's 7 verified functions are still proved (`zig build verify --fork`, `--max-trusted 0`), and the compiler hook is untouched, so the checked-in packs stay valid. The new pack is named `soundness3`, like the earlier rounds' (the round-1 file stays `soundness.zig`).

### 1. Bit cast between aggregates: confirmed, fixed by rejecting

A packed struct is `kind = struct` in the pack, with nothing that says it is packed, and the model keeps fields apart, not bits. Modelling a packed struct as its backing integer needs the compiler hook to export the packed flag and the field bit offsets; the hook was left alone (existing packs stay valid), so the cast is not modelled. `bit_cast` still accepts a scalar operand as before (integers of one width, `bool` with `u1`), and any other operand only when its type is the result type; every other reinterpretation is outside the fragment (UNPROVEN, `bit_cast of obj to T`). Nothing is copied through when the types differ.

Regression: `packBit`, `packFieldM`, `packBit2`, `packToInt` UNPROVEN; `usePack` UNPROVEN (its callee is outside the fragment) and no longer aborts. Controls: `packRead` (a field of one packed struct) proved, `packOrder` REFUTED (field order is by declaration), `bitSign` REFUTED at `x = 128`, `bitRoundTrip` and `bitBool` proved.

Correct code that is now UNPROVEN: a packed struct cast to another packed struct or to its backing integer (`packToInt` is a correct cast; the old model also gave it a result of the wrong sort), and any struct, array or vector bit cast. It is the cost of the soundness; the way back is the packed flag in the pack.

### 2. Pointer cast between layouts: confirmed, fixed by an allow-list

The cast is an identity only when the pointees have one layout: the same type, integers of the same width (signedness may differ; the load uses the destination's), or arrays of the same length whose elements have one layout, recursively. Everything else is outside the fragment (`a pointer cast to a pointee of another layout`), including an unknown pointee. This replaces `reinterprets`, which was a deny-list.

Regression: `packPtr`, `ptrNest0`, `ptrNest1`, `ptrNest4` (`*[8]u8` to `*[2][4]u8`), `ptrWide` UNPROVEN. Controls: `ptrCastSame` REFUTED at `x = 128`, `ptrSameOk` (`*const u8` to `*const i8`) proved. Correct casts that are now UNPROVEN: a pointer to an array cast to a pointer to its element and the reverse (they were an identity before, and a following load produced the wrong kind of value).

### 3. Comptime parameters: confirmed, fixed

`runInner` now checks that an `.arg` names a parameter of the declared signature, with the same type; otherwise the function is outside the fragment (`argument N is not a parameter of the declared signature (a comptime parameter)`). The two instances of `plus1` are UNPROVEN, as are `incU8` and `incU16` (the callee names two different functions, round 2's rule). Instances that could be verified with the comptime values bound are left for later.

### 4. `agrees` and `term.eq`: confirmed, fixed

`agrees` compares the sorts of two scalars and reports the function outside the fragment instead of asserting. The path from fix 1 is gone as well (`usePack` above).

### 5. A crash must not take the pack: not true before, now true

Verdicts were printed after every function had been verified, so a panic anywhere lost all of them. `zvc` now supervises itself: the verification runs in a child process that reports the function it is in on stderr; if the child aborts, the parent names the innermost function (a bug in `zvc`), runs again with that function marked as crashed (UNPROVEN, `the verifier crashed on this function`), and so on, so each crash costs one more run and no verdict. A callee that crashes inside a caller's run makes the caller UNPROVEN through the usual call rule. A crash outside any function, or twice on one function, ends the run with exit 2. `--list`, `--survey` and `--smt` run in process. Checked by hand with an injected panic in two functions of `soundness3` (one a callee of another): the other verdicts came out unchanged, the three affected ones UNPROVEN, exit 1. There is no pinned case for it, since a pinned case needs a real bug.

### 6. `--max-assume 0`: confirmed, fixed for both ceilings

`--max-trusted` behaved the same (`proved` lines, then the failure line, exit 1). Both now decide the ceiling before the verdicts are printed: when the distinct trusted functions or `zv.assume` sites exceed it, every `proved` verdict that carries one is printed UNPROVEN with `its assumptions exceed --max-trusted` (or `--max-assume`), counted so, and compared to `--expect` so. The failure line and exit status stay. `tools/run_zvc.sh` checks both.

### 7. `--only`: confirmed, fixed in all three tools

`--only PATH` (`zvc`, `zv-own`) and `zv-air dump --fn PATH` select a function whose declared name (without generic arguments and instance suffix) has PATH as whole dotted components: `min` selects `a.min` and `a.min.inner`, not `a.minMul`; `wire.tcp` selects the container. The matcher is `zv_air.names.selects`; `declaredName` moved next to it. `tools/zvc_export.sh --only` is a container path of the exporter and was never a substring. No script or document relied on the substring: `run_zvc.sh` and `run_own.sh` pass full or whole names. Regression in `run_zvc.sh`: `--only soundness3.packBit` and `--only packBit` select `packBit` and not `packBit2` (`soundness3.only.expect`, which also fails on a verdict with no line). `--expect` itself matched names by substring when it looked for a verdict with no expectation; it is exact now.

### 8. Sentinel slices: fixed

A slice parameter whose type name states an integer sentinel (`[:0]const u8`) has it at its length: `mem[len] == sentinel` is added to the path condition and to the function's precondition, so a caller has to establish it (the language guarantees it for a value of that type, and the slicing that makes one is checked in Debug). Other sentinels (characters, negative values) and sentinel arrays are not read and stay as before. Regression: `sentinel0` and `sentinelCall` proved, `sentinel1` REFUTED.

### Other items in the review

Not bugs, unchanged: error codes as a free 16-bit value, safety-off access without a check, loop havoc, and the completeness list (saturating arithmetic, `byte_swap`, vectors, unions, enums, labelled switch, `ptr_from_int`, `Int.of(minInt(i256))` as a constant: `ghostMin` UNPROVEN, `ghostMinMul` REFUTED, both pinned).
