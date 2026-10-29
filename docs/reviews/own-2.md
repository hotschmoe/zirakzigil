# Review 2 of zv-own and the validation on five projects: resolution (0.17.15)

Three reports came in after 0.17.13: a second adversarial review (35 programs that `zv-own` called clean and Debug showed to be bugs, 7 correct programs it reported, std and no-std packs that disagreed), and two validations on real code (zls and ziggy, libvaxis and webzocket and rich_zig), where 37 of 38 and 26 of 30 reported project functions were false positives. They have one root cause, and 0.17.15 replaces the model instead of patching it. The new model is in [phase3.md](../phase3.md) (M2); this file records what became of each finding. Every program of the reports is pinned: `tests/own/review2.zig` and `review2b.zig` (the review's `probe.zig` and `probe2.zig`), `fp_zls*.zig` and `fp_idioms.zig` (the reductions of both validations), `real.zig` (the real bugs, and the one that was missed), `switchloop.zig` (labeled switch loops and two idioms); each is exported twice, without and with the std bodies it reaches, and both packs are checked against one set of verdicts by `tools/run_own.sh`.

## The cause

Owners were keyed by place, the slot a value is stored in, and not by what the value is. A copy of a container, an arena or a struct is a new place, so ending the copy did not end the original (every by-value false negative of the review: 24 of 35), and several allocations reached through one place or one by-value struct, or one call site run twice, were one owner (the false positives of both validations). A callee summary applied the callee's invalidation of `self.items` to the result of the callee when it returned `self`, which is class A of the zls report (28 of its 36 false positives) and builder chains in libvaxis.

Now a value carries the set of identities it may lead into, a copy carries the same set, and a struct is stored field by field, so that two fields, two call sites and two results of one helper are different identities. Ending an identity replaces it by its tombstone in every value of the path that holds it: the copy, the original, the slice read before and the one read after. A callee summary is a list of effects over access paths rooted at its parameters (what it ends, what the memory below each pointer holds afterwards, where its result comes from), which the caller substitutes with its own identities. The details, and what stays assumed, are in phase3.md.

## The 35 false negatives of the review

Every `bad*` program of `review2.zig` and `review2b.zig` is now `FINDINGS` on both packs, except the three that depend on the data (below) and `badInitBufferReturn`, which is not a bug. The mechanisms:

| # | Mechanism | Programs | Resolution |
| --- | --- | --- | --- |
| 1 | By-value copy of a container header | `badCopyDeinit`, `badCopyUseAfter`, `badHashCopy`, `badArrayHashCopy`, `badMultiCopy`, `badOptionalCopy`, `badPqCopy`, `badPdqCopy`, `badDequeCopy`, `badEatByValue`, `badEatGeneric`, `badEatDoc`, `badHeaderHelper`, `badErrdeferCopy`, `badDerefCopy`, `badManagedHashCopy` | Found: the copy holds the identities of the original, and `deinit` of either ends both. `badFieldCopy` and `badArraySlotCopy` (a copy through a field, and through a constant index: each constant index is a place of its own, only a variable index is one place for all) are found too. |
| 2 | `insert`, `push`, `pop` under proved room still move elements | `badInsertWithin`, `badInsertAssume`, `badMultiShift`, `badLastAfterSwap`, `badOrderedRemoveShift`, `badArrayHashShift` | Found: shifting is a separate effect from growing, and room excuses only growing. A heap that sifts (`badPqSift`, `badPdqSift`, `badPqPopMoves`) moves an element that depends on the values: the pointer is counted as maybe stale (`tools/run_own.sh` checks the count) and not reported, because the next correct program of the review (`okPqWithinNoSift`) has the same shape and is clean. |
| 3 | `@atomicStore` of a pointer | `badAtomicStoreFree`, `badAtomicStoreEscape`, `badAtomicStoreOut` | Found: the atomic store is a store, and the address of a global is a place that outlives the function. |
| 4 | `fromOwnedSlice`, grow, use the original slice | `badAdoptGrowUse`, `badAdoptSelfSlice` | Found: the list and the slice hold one identity, so the grow ends the slice. `appendSlice` of the list's own items is found as an argument that points into the storage the call reallocates. |
| 5 | Arena by value, reset of a copy | `badArenaByValue`, `badArenaResetCopy` | Found: an arena and its copy are one object. The real instance, zls `Server.loop` (`real.badLoopIteration`, an arena `State` passed by value and deinitialized by the callee and again by the caller's errdefer) was missed in 0.17.13 and is found. |
| 6 | Deque and MemoryPool outside the ending rule | `badDequeSameDeinit`, `badDequeCopy`, `badDequeInitBuffer`, `badDequePtrAcrossGrow`, `badPoolUse`, `badPoolCopy`, `badPoolCopyUse`, `badInitBufferEscape` | Found on both packs: a `deinit` whose body gives anything back ends its object (so does a body that sets `self.* = undefined`), `deque.` is a container family, `MemoryPool.create` hands out blocks that end with the pool, `initBuffer` keeps the stack buffer the list was lent. |
| 7 | Two pointer parameters that alias | `badAliasParams` | Found at the call (`freeBoth(&list, &list, gpa)` ends one object twice). A function that ends or changes memory through two pointer parameters of one type counts in the footer (`functions that assume two pointer parameters of one type do not overlap`); no assumption is silent. |

False positives of the review: `okInitCapacityHold` (`initCapacity` seeds the room), `okAppendSliceWithin` (a literal of known length counts against the room), `okDynamicEnsure` (a reserve of a size the checker cannot read makes a later growth soft: counted, not reported), `okDequeWithin`, `okManualSwap` (a copy through three assignments), `okMultiToOwned` (a body that moves the buffer out and empties the container is read as it is), `okSlotsDoubleCancel` (`Slots.free` of a stale handle is an error the caller may swallow: reported only where the error is propagated with `try`), `okPqWithinNoSift`. All clean on both packs.

Std against no-std: the two packs of every case give the same verdict (the suites run against one expectation file). Where the body derives less than the table says, the table is kept (`ends` of a container, `releases` only without a body, because with the body the move is exact).

## False-positive classes of the validations

| Class | Resolution | Pinned in |
| --- | --- | --- |
| zls A: summary "returns `p`" plus "kills `p.f`" applied to its own result; values copied out of a map slot | The result is the argument's identities, the kill is on the storage identity below `f`: they are different identities. A value copied out of a slot holds what the slot held, not the slot's storage | `fp_zls.zig`, `fp_zls2.zig`, `fp_zls3.zig` |
| zls B: one owner per allocation site (stdout and stderr of `process.run`); an allocator passed on reads as freed | Two allocations of one callee are two fresh identities in its summary; an allocator is never owned by what it allocated | `fp_zls.runAndFree` |
| zls C: fields of a by-value struct share one owner | A by-value parameter is a struct of identities, one per field | `fp_zls.Pieces.deinit` |
| zls D: two results of one helper | Different call sites, different identities | `fp_zls.pickLonger` |
| zls E: `Writer.Allocating.toArrayList` moves and clears its source | `toArrayList` moves the buffer and empties the writer (table: the pack does not hold the body) | `fp_zls.render`, `fp_idioms.fp9` |
| zls F: container declared in a loop is one place | A slot made again holds a new object: the previous incarnation is demoted to the summary of its site | `fp_zls.perIteration`, `fp_idioms.fp13` |
| zls G: `x.field = undefined` after deinit through an alias | Poisoning the whole of a parameter's pointee ends the object, a field of it ends that field | `fp_zls.Lazy` |
| zls H: freeing a popped element attributed to the container | `pop` moves nothing and returns the element, which the container no longer holds | `fp_zls.Queue` |
| zls I: unproven callee assumed to return pointers into its args | Labeled switch loops are interpreted (a fixed point like loops); an indirect call result is unknown and counted | `switchloop.zig`, `fp_idioms.fp10` |
| vaxis 1: builder chain returning `self` | As zls A | `fp_idioms.fp2Chain`, `fp2bChain` |
| vaxis 2: guarded free then null | `if (x) \|p\| { free(p); x = null; }` and the next guarded free: a test refines what the place holds on the branch where it is null | `fp_idioms.fp4`, `fp4b` |
| vaxis 3: re-init in place after `deinit`; `child_allocator` read from an arena | A store of a whole object starts a new incarnation; an allocator field is not owned by the arena | `fp_idioms.Store.compact`, `fp7` |
| vaxis 4, 5: whole-`self` owner overlaps every field; copy with one field overwritten | Field-sensitive memory | `fp_idioms.fp1GrowCopy` |
| vaxis 6: `\|*cell\|` cleanup loop | An end through an element place is one of many: soft | `fp_idioms.fp5` |
| vaxis 7: indirect-call result depends on its arguments | Unknown, counted | `fp_idioms.fp10` |
| vaxis 8: `Thread.spawn` per-iteration argument | Per-iteration identities | `fp_idioms.fp11` |
| vaxis 9: `toOwnedSlice` then deinit of the emptied container | The container is empty after the move | `fp_idioms.fp9` |
| vaxis 10: callee frees on the error path, returns the allocation otherwise | A free only counts when it is on every path that returns | `fp_idioms.fp6` |
| vaxis 11: `free` through `arena.allocator()` ends the arena | Only the pointer freed ends | `switchloop.okFreeThroughArena` |
| vaxis 12: struct returned by a method of `self`, another field's container mutated | Field-sensitive | `fp_idioms.fp12` |

Tool defects: a multi-pack run gives the verdict of each function that a run of its own pack gives, plus the callee bodies the other packs add (functions are told apart by name, file, line and parameter types; a function exported into several packs is one function); the footer counts the project's functions apart from the dependencies' (`--project`, default `target` and `root`), and the numbers about assumed calls are the project's.

## The real bugs

All found, pinned in `real.zig` (and in the packs of the projects, see the table): a list deinitialized and appended to (libvaxis `ListView`), a stack widget returned in a surface (libvaxis `Button`), the address of a local registered and the local returned by value (zigimg `OctTreeQuantizer`), a `values()` slice kept across `swapRemoveAt` (zls `TrigramStore`), a `Scanner` copied by value that shares its heap stack (lsp-kit), and the arena `State` passed by value (zls `Server.loop`, missed before).

## The five projects again

Same packs as the validations (zls, ziggy, libvaxis, webzocket, rich_zig; with std bodies, the headline of both reports), the 0.17.13 binary and the 0.17.15 one on each pack, functions of the project only (functions of dependencies are counted apart: the footer now does it), `FINDINGS` only, a function counted once however many packs of the project report it. `UNPROVEN` is counted apart.

| Project | Flagged before | Real before | Flagged now | Real now | Plausibly real | Other (false positives, not all triaged one by one) | Unproven before / now |
| --- | --- | --- | --- | --- | --- | --- | --- |
| zls (+ lsp-kit, diffz) | 35 | 1 (`TrigramStore.init`) | 2 | 1 (`Server.loop`, missed before) | 1 (`Workspace.refreshBuildOnSave`) | 0 | 5 / 0 |
| ziggy | 3 | 0 | 1 | 0 | 0 | 1 (`cli.lsp.textDocument/completion`: new, a pointer to a local returned) | 13 / 4 |
| libvaxis | 9 | 3 (`ListView.drawBuilder`, `Button.draw`, `ScrollView.drawBuilder`) | 6 | 2 | 0 | 4 (`Loop._ttyRun` and `Terminal._run` are causes 1 and 12 of the report, `Vaxis.testResizeAllocationFailures` and `App.FocusHandler.update` are new) | 0 / 0 |
| webzocket | 6 | 1 (`Reader.decompress`) | 10 | 1 | 0 | 9 (a cluster around `Reader.done`, `deinit` and `restoreStatic`, and the tests that use them) | 2 / 2 |
| rich_zig | 7 | 0 | 1 | 0 | 0 | 1 (`Panel.splitStyledTextIntoSegmentLines`: a `Text` made in each iteration and freed by a `defer`; new) | 0 / 0 |
| **all** | **60** | **5** | **20** | **4** | **1** | **15** | **20 / 6** |

False-positive project functions: 55 before, 15 now (3.7 times fewer; 3.0 times fewer functions reported); the 15 are the ones nobody has looked at one by one, and the 11 that were not flagged before are new verdicts, none of them confirmed. Dependencies: the same real bugs are found in them (zigimg `OctTreeQuantizer.init`, lsp-kit `Message.parseFromSliceLeaky`); the dependencies' own false positives are not counted. Time: zls in 6 to 35 s (0.17.13: 9.6 s), the other packs in 1 to 8 s.

**The known real bugs.** Found: `ListView.drawBuilder` and `ScrollView.drawBuilder` (deinit then append), `Reader.decompress` (the stack `dumb` buffer), zigimg `OctTreeQuantizer.init` (the address of a local registered, the local returned by value), lsp-kit `parseFromSliceLeaky` (the scanner copied by value), and `Server.loop` (the arena `State` passed by value), which 0.17.13 missed. **Not found any more: `TrigramStore.init` (a `values()` slice kept across `swapRemoveAt`) and `Button.draw` (a stack widget returned in a surface).** The reduction of the first is found (`real.badValuesAcrossSwapRemove`, also with a struct that owns the map and a method that fills it in a loop), the real function is not; I did not find out why (the run counts one operation on memory it cannot name, and the loop that fills the store makes its storage identities summaries, whose ends are only counted). The second reaches the surface through a call to a function pointer (`Widget.drawFn`): 0.17.13 saw it because the result of an indirect call depended on its arguments, which is also the cause of the false positive `fp10`; the two cannot be told apart without resolving the function pointer, and the review asked for the unknown result. So the target of this work, at least three times fewer false positives without losing a known real bug, is **met on the first half and missed on the second**: two of the eight known real bugs are lost. A plausible real bug is new: `BuildOnSave.init` frees `options.build_root` itself when it fails (its `errdefer`), and `Workspace.refreshBuildOnSave` frees the same path in its own `errdefer`, closes the same handle, and prints it in the `catch` that logs the failure; that wants a maintainer's read.

**What stays assumed**, besides the list in phase3.md: the recursion summaries are a guess until they settle (8 rounds at most), a callee that failed leaves a growing container as it was and nothing else, and a function pointer's result depends on nothing. `src/own` itself, 276 functions, gives 8 findings without std and 7 with it, all of one kind (a state handed to a recursive interpreter that grows its maps and used again afterwards: `Run.block`, `loop`, `loopSwitch`, `switchBr`, `condBr`, `tryOp`, `execute`); 0.17.13 gave none, because it was fitted to this code. That is the honest figure for code that was not written for the checker.
