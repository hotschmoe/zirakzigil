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

## The five projects, 0.17.15 and now

Same packs as own-2 (with std bodies), functions of the project only (the dependencies' are counted apart: zigimg in libvaxis, lsp-kit in zls and ziggy), `FINDINGS` only, a function once however many packs report it. Base is 0.17.15 (master 4733192), built and run on the same machine today.

| Project | Reported 0.17.15 | Reported now | Real now | False positives 0.17.15 / now |
| --- | --- | --- | --- | --- |
| zls | 3 | 3 | 3: `Server.loop`, `Workspace.refreshBuildOnSave`, `TrigramStore.init` | 0 / 0 |
| ziggy | 1 | 1 | 0 | 1 / 1 (`cli.lsp.textDocument/completion`: a buffer grown through the writer's vtable) |
| libvaxis | 5 | 7 | 4: `ListView.drawBuilder`, `ScrollView.drawBuilder`, and two new (below) | 3 / 3 (`Loop._ttyRun`, `Terminal._run`, `App.FocusHandler.update`, as in own-2) |
| webzocket | 10 | 2 | 1: `Reader.decompress` | 9 / 1 (`test Reader: fuzz`: `expected[i].data` after the arena reset of the previous round, the weak store into an element joins the old tombstone) |
| rich_zig | 1 | 0 | 0 | 1 / 0 |
| **all** | **20** | **13** | **8** | **14 / 5** |

False positives 14 to 5 (2.8 times fewer; webzocket 9 to 1). Reported 20 to 13, because two of the 13 are new and true: libvaxis `App.run` and its test `MouseHandler: negative coordinates leave the hovered widget`. `MouseHandler.updateMouse` does `app.allocator.free(self.last_hit_list); self.last_hit_list = try app.allocator.dupe(...)`: when the `dupe` fails the list is freed and still stored, and the caller's `defer handler.deinit(...)` frees it again. It was invisible before (the error path of the call had the success-only write); `tests/own/fp_tags2.zig` `badFreeThenDupeFails` is the reduction, and the DebugAllocator with a `FailingAllocator` crashes on it (segmentation fault in the second free). I reduced it and did not run the library itself under a failing allocator. Nothing was filed anywhere.

Per-pack footers, with std (ends decided of all ends, uses decided of all uses; 0.17.15 first):

| Pack | Ends decided | Uses decided | Unproven |
| --- | --- | --- | --- |
| zls | 1539 of 2279 (68%) / 1627 of 2264 (72%) | 12444 of 12456 / 12394 of 12449 | 0 / 0 |
| ziggy lib | 206 of 585 (35%) / 344 of 584 (59%) | 2645 of 2645 / 2543 of 2646 | 0 / 0 |
| ziggy cli | 61 of 70 / 63 of 67 | 659 of 659 / 659 of 659 | 4 / 4 |
| libvaxis capi / force / tests | 1213 of 1309 / 248 of 354 / 45 of 46 -> 1180 of 1283 / 233 of 348 / 45 of 50 | all but 0 / 0 / 0 -> 3 / 6 / 4 | 0 / 4 / 4 |
| webzocket force / tests | 54 of 60 / 428 of 482 -> 42 of 64 / 347 of 494 | 580 of 604 / 1782 of 1806 -> 579 of 607 / 1775 of 1823 | 0 / 2 |
| rich_zig force / tests | 551 of 1033 / 2249 of 2715 -> 809 of 1042 / 2483 of 2721 | all -> 3603 of 3617 / 4261 of 4275 | 0 / 0 |

The decided fraction of ends rose where the old figure counted ends that were not decided (rich), and fell where the new rule counts an element free or a guarded end under an unknown tag as undecided (webzocket, libvaxis): it is the same number computed more honestly, not a precision gain. I did not shrink the undecided ends of a site that stands for several allocations (item 5 of the plan): see "What was not done".

Time: ziggy's library pack takes 17 s against 6 s (the guards, the facts and the per-scalar values cost three times on the code with the most `switch` loops); the other packs are within 1.5 times. A run of the five projects, both packs each, took 16 minutes on a loaded machine.

## The 8 known real bugs

Found: `ListView.drawBuilder`, `ScrollView.drawBuilder`, `Reader.decompress`, zigimg `OctTreeQuantizer.init`, `Server.loop`, `TrigramStore.init`, `Workspace.refreshBuildOnSave`. Counted, not reported: lsp-kit's saved `Scanner` (`real.savedScannerAdvances`: now one use of a pointer that may lead into freed memory, where it used to be one stale-if-no-room, checked by `tools/run_own.sh`) and `Button.draw` (`lent`). None lost. The saved scanner is not a finding on purpose, see phase3.md M5 (unions).

## zmoltcp

`zv-own` on `own/zmoltcp.zvp` (986 production functions, with the instantiations): 986 clean, 0 findings, 0 unproven, in 0.4 s; the footer: `decided: 6 of 6 ends and 4178 of 4178 uses`, nothing undecided. `own/seeded.zvp`: every verdict matches `own/seeded.expect` (4 seeded mistakes found). Nothing in the zmoltcp repository was written to. If the team wants the gate there: `addOwnershipGate` already runs `zig build own own-seeded` in about 20 s; what is worth adding is `--max-unproven 0` (it has 0 today) and a pin of the footer's undecided counts (all 0 today) so that a change that makes the gate undecided fails the build, not only one that makes it report.

## What was not done

- **The elements a callee stores into a block it allocates, and what a vtable call writes** (item 4): not started. The `lent` count is unchanged (106 in the zls pack).
- **Fewer undecided ends** (item 5): not done. The ends that remain undecided (600 in zls) are the frees of the elements of a set and of a site that allocates in a loop; the review showed that dropping them silently was the bug, and a sound way to decide them needs the identity of the element, which this model does not carry. The decided fraction is more honest than before, not higher.
- **The saved `Scanner` of lsp-kit as a finding**: not reported, because it is not sound: the copy dangles only if the nesting of the input is deep enough to grow the shared stack, which the program does not say. It is counted.
- **`test Reader: fuzz`** (one false positive left in webzocket), **`textDocument/completion`** (a buffer grown through a vtable), `_ttyRun`, `Terminal._run` and `FocusHandler.update`: not changed; their causes are in own-2.
- The error path of a call is the state after the call with the successful-only effects given back; the callee's failing paths are not kept as a state of their own.
