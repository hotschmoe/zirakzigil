# Review 3 of zv-own and the tag work: resolution (0.17.18)

A third adversarial review of 0.17.15 (read-only, 30 programs in two files, each exported with and without std bodies) and the work that cleared most of the false positives left on the five projects. Both are pinned: the review's programs are `tests/own/review3.zig` and `review3b.zig` (verbatim, so that the review can be replayed), the reductions of the tag cases are `tests/own/fp_tags.zig`, and `tools/run_own.sh` checks every verdict on both packs, and that the programs that stay undecided say so in the footer.

I ran the review's executables in Debug first: every claim of a fault below reproduced (`badVarIndex`, `badOwnOrFree`, `badDropAndRead`, `badAliasGpaFirst`, `badAliasSliceFirst`, `badGrowPast`: segfault; `badConstIndex`, `badSavedElem`, `badKeepFirst`, `badPrevBuf`, `badInstallCatch`: a double free reported by the DebugAllocator; `badInstallOrDrop`: a read of a freed block, `0xAA`; `okInstallCleanup`: returns `error.Rejected`, no fault). `badEnsureThenFail` and `badAppendThenFail` read `1`: nothing moved.

## The review, one item at a time

| Case | Debug | 0.17.15 | Now |
| --- | --- | --- | --- |
| `badVarIndex` | segfault | clean, `decided: 1 of 1 ends` | clean, counted: the free of the element is a soft end (`1 ends ... not happened`, 1 maybe-alias). `endIds` dropped the end of "one of many" values without a tally; it is now a soft end. Not a finding: which element was freed is not known. |
| `badConstIndex` | double free | clean, 0 ends | counted (4 ends, 3 maybe-alias). The two places of an element (constant index, variable index) were read apart, so the free had nothing to end; they are read together now. |
| `badSavedElem` | double free | clean | counted (2 ends, 1 maybe-alias) |
| `badDropAndRead`, `badAliasGpaFirst`, `badAliasSliceFirst` | segfault | clean, not counted | **findings**: "argument 2 of `f` points into memory the call ends through argument 1". The call is checked for every pair of parameters whose callee reads through one and ends through the other (not only parameter 0), and a slice passed by value is a read of its block (it was not recorded). The functions that end or change memory through two or more pointer parameters of any kind are counted in the footer (were: two struct pointers of one type name). |
| `badInstallOrDrop` | read of freed block | clean | **finding**. The error path of the call is the state before it, plus what its failing paths end (`Kill.on_fail`), minus what only its successful paths write or end; also for `catch` and `if (x) |_| else |_|` (the error side of `is_err`). |
| `badOwnOrFree` | segfault | clean, silent | clean, counted: a by-value parameter freed on some paths only ends softly in the caller (`Summary.maybe_frees`). |
| `badKeepFirst`, `badPrevBuf` | double free | counted, but `badPrevBuf` said `decided: 2 of 2 ends` | counted, and the decided line is true: every soft end (a value that may be one of several, one of many, a site that stands for several, a growth that depends on room) is an end not decided. Not findings: the checker cannot say which of the blocks of one site the variable holds. |
| `badGrowPast` | segfault | counted | counted, unchanged. The growth after a reserve of an unread size may or may not move; a constant `ensureTotalCapacity(200_000)` after it moves only if the earlier reserve was smaller, which the program does not say. It is not decidable, and the footer says so (1 pointer stale only if a container had no room; `diagSoft`, which does not move, counts the same). |
| `badInstallCatch` | double free | counted (maybe-alias) | **finding** (a true double free): the success-only write is not made on the error path any more. |
| `okInstallCleanup` | no fault | false double free | clean. Same cause. |
| `badInstallList` | double free | one true and two false findings | one true finding (`saved` and `slot` are one list); the false report on `next` is gone (object writes are restored on the error path too). |
| `badEnsureThenFail`, `badAppendThenFail`, `diagEnsure`, `diagAppend` | no fault | use after free | unchanged, and I do not call them false positives: the program keeps `items` across an `ensureTotalCapacity` or `append` that the contract allows to move, and does not move only because std allocates 129 bytes for the first element. This is the pinned `ctrlGetPtrThenPut` family. Modelling the growth policy would hide the same bug on any other element size and allocator. Pinned as findings. |
| `badReplaceOrFree` | `index out of bounds`, an empty slice (not a use of a freed block) | clean | clean |

Two things the review pointed at that I did not change: `docs/reviews/own-2.md` said the frees of elements were summarized ends; they were silent, as the review says (the sentence "I cannot say none of the 740 hides a bug" was too weak). And the 93.8 percent of phase3.md is about the seeded set, as the review notes; the corpus now has the review's 30 programs and the tag cases on top of it.

## The tag work

[phase3.md](../phase3.md), M5. In one paragraph: a scalar can be a known constant, a branch on a field refines it, a kill in a summary carries the tests it depends on (`param0.buf.data when param0.buf.type == dynamic`), results and writes say which constant they leave, a `deinit` ends what its summary ends, and a union has one place per variant. The cases are `tests/own/fp_tags.zig`: `okStaticGrow` (webzocket `buffer: grow`), `okReaderDone` and `okReaderGrow` (`Reader.done`, `read`), `okSliceLines` and `okSliceThenOwner` (rich `Text`), with `badDynamicRelease`, `badStaticFreeTwice`, `badReaderDynamic` and `badOwnedUse` as the same shapes with the bug in them; the five `ok*` were reported before and are clean, the four `bad*` are findings on both packs. Each reduction was checked against the real function: the verdict of the real function changes with it (below).

## The five projects

NUMBERS

## The 8 known real bugs

NUMBERS_REAL

## zmoltcp

`zv-own` on `own/zmoltcp.zvp` (986 production functions, with the instantiations): 986 clean, 0 findings, 0 unproven, in 0.4 s; the footer: `decided: 6 of 6 ends and 4178 of 4178 uses`, nothing undecided. `own/seeded.zvp`: every verdict matches `own/seeded.expect` (4 seeded mistakes found). Nothing in the zmoltcp repository was written to. If the team wants the gate there: `addOwnershipGate` already runs `zig build own own-seeded` in about 20 s; what is worth adding is `--max-unproven 0` (it has 0 today) and a pin of the footer's undecided counts (all 0 today) so that a change that makes the gate undecided fails the build, not only one that makes it report.
