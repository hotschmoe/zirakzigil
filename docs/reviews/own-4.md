# Review 4 of zv-own and the repair of the tag model: resolution (0.17.20)

The fourth adversarial review ([grok review of 0.17.18](../phase3.md), read-only; 38 programs) found that the tag model of 0.17.18 deleted kills on the strength of constants that were not current: the constant of the success exit judged the error exit, writes the checker could not read left the old constant behind, a union destructor never reached its summary. All of its programs are pinned in `tests/own/review4.zig` (verbatim), exported with and without std, with the verdicts of `tests/own/review4.expect` and `tools/run_own.sh` (which also checks that the programs that stay undecided say so in the footer).

I reproduced every claimed fault in Debug first with the review's `probe.exe` (segmentation fault in `use` for `badArmTry`, `badArmLocal`, `badArmFromTrue`, `badDeinitArm`, `badMemsetKind`, `badByteStore`, `badAtomicRmw`, `badCmpxchg`, `badUnionAssign`, `badFnPtr`, `badSetKind`, `badLoopRelease`, `badSoftParam`, `badErrOnly`, `badErrOnlyLocal`; a segfault in `show` for `badOwnOrFree`; `byte 170` and a double free for `badKeepFirst`; `okInstallCleanup` returns `error.Rejected`). `badArmError` is not in the dispatch table of the executable (it is `badArmFromTrue` there).

The principle of the repair: **a constant that might be stale must never suppress a kill.** A scalar is either a constant the run read (a store of a constant, a test, an exchange with a constant), or one of two constants (a join), or unknown; an end under an unknown tag is a soft end, counted, never silence.

## The review, item by item

| Case | 0.17.18 | Now |
| --- | --- | --- |
| `badArmTry`, `badArmFromTrue`, `badArmLocal`, `badDeinitArm` (the success constant judged the error exit) | clean, `decided: 1 of 1 ends` | **findings**. A summary has the constant of each exit: a write that a failing path also makes carries the constant the failing paths agree on (`Write.fail_con`), and the error side of `try` and `catch` takes it (or nothing known) instead of the success constant. `okArmSuccess` stays clean. |
| `badMemsetKind` | clean, silent | clean, **counted** (1 end not decided, 1 may-alias, 1 may-stale). `@memset` makes the tag unknown; the bytes written are not read as a discriminant. |
| `badByteStore` | clean, silent | **finding**. A store through a pointer cast to another type drops the constant (the stored integer is not the enum's name), so the inline test is no longer pruned. |
| `badAtomicRmw`, `badCmpxchg` | clean, silent | **findings**. An exchange with a constant stores it; a compare-exchange of a place known to hold the expected constant stores the new one (a weak one: one of the two); any other atomic update makes the scalar unknown. |
| `badUnionAssign` | clean, silent | **finding**. A union passed by value is a struct of its variants, so `freeSlot`'s summary says `kills param 0 value path { 1 }`. `get_union_tag` itself is still not modelled: the arms of the `switch` all run, so an end in one arm is an end on some path. `okUnionNone` and `okUnionKeep` stay clean: naming a variant of a local union ends the content of the others. `badUnionField` (reported; Debug panics earlier on the safety check, as the review says) is a finding too. |
| `badFnPtr` | clean, silent | clean, **counted** (the same footer). A call through a function pointer clobbers what it was given, and the summary of the wrapper says so (`clobbers`), so that the caller's tag is unknown. |
| `badSetKind` | counted | **finding**. A write says the by-value scalar parameter it copied (`setKind(&buf, kind)` leaves whatever `kind` was), and the caller reads its own argument. |
| `badLoopRelease` | counted | **finding**. A join of two constants is kept as the pair, and an end that either of them allows is as certain as a branch is. |
| `badErrOnly`, `badErrOnlyLocal` | counted | **findings** (the failing paths' constant, above). |
| `badSoftParam` | counted | counted, unchanged: the mode is an argument of the function under test, nothing in the program says what it is. |
| `badOwnOrFree`, `badKeepFirst` | counted | counted, unchanged, for the reasons of own-3.md. |
| `okInstallCleanup` (frees after a `try` that must fail) | false double free | clean. The summary has the tests the successful paths went through (`ok_when`); `install(&slot, next, false)` closes all of them, so the code after the `try` is dead on that path. `badInstallOrDrop` is correct, as the review says, and clean. |

## One more place that kept a constant

Found while repairing: a store of a tag-like scalar (an enum or a bool) through a pointer the run has no place for (a pointer a callee handed out) may hit any tag the run follows. It now drops what the run knows of every tag, and the summary tells the callers (`clobbers` of every pointer parameter).

## The five projects and zmoltcp

Same packs, same method as own-3.md (std bodies, project functions, 0.17.18 run first, today, same machine). **Project functions reported: 13 before and after; real 8; false positives 5 before and after** (ziggy `textDocument/completion`; libvaxis `_ttyRun`, `Terminal._run`, `FocusHandler.update`; webzocket `test Reader: fuzz`). zls 3 (all real), ziggy 1, libvaxis 7 (4 real), webzocket 2 (1 real), rich_zig 0. None of the fixes cost a project false positive.

What did change: the dependency function lsp-kit `Message.parseFromSliceLeaky` is reported again (zls and ziggy packs). It is the shape of the saved scanner: `var params_source = state.params;` copies a `Scanner`, `parseParamsFromTokenStreamWithKnownMethod(..., &params_source, ...)` advances the copy, and `source` is used afterwards; the copy and `source` share one heap stack, which the advance reallocates when the nesting is deep. A tagged union now splits by variant, so the copy keeps the identity of the stack, and the model (an append invalidates) says what it says everywhere else. I believe it is the second instance of the data-dependent real bug (same as `real.savedScannerAdvances`), not a false positive in the sense of the others, but it is reported and not counted, which phase3.md says the saved scanner itself is not; I did not suppress it.

The decided fraction of ends (zls 1637 of 2262, ziggy lib 344 of 584, libvaxis force 236 of 354, webzocket tests 348 of 494, rich tests 2483 of 2721) is within one percent of 0.17.18.

zmoltcp: 986 functions, 0 findings, 0 unproven, `decided: 6 of 6 ends and 4178 of 4178 uses`, nothing undecided; `own/seeded.expect` matches. Nothing in that repository was written.

Time: unchanged within noise (a full run of both packs of the five projects, 18 minutes on the loaded machine; ziggy lib 17 s).

## What the numbers of the corpus mean

The table of phase3.md (225 seeded mistakes, 211 found, 4 unproven, 7 missed, 219 of 225 not silently accepted) is the seeded set of the first two rounds and does not contain the programs of the reviews 3 and 4, nor the tag reductions; those are pinned apart and are not in the percentage. With the programs of review 4: 38 functions, of which 24 are findings, 5 are bugs the footer counts and does not report (`badMemsetKind`, `badFnPtr`, `badSoftParam`, `badOwnOrFree`, `badKeepFirst`), and the rest are controls and correct programs.

## What is still not decided

The five counted cases above are real faults that a gate which fails only on findings accepts. They stay counted because the program does not say what the tag is (`badSoftParam`), because the write cannot be read (`@memset`), because the call is through a function pointer, because a by-value parameter is freed on some paths only, and because a site that allocated in a loop stands for several blocks.
