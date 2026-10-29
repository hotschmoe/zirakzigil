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

Reduced and pinned in `real.zig` (the bugs the review and the validations found in real code, the std types they use, and the shapes of the second round): a list deinitialized and appended to (libvaxis `ListView`), a stack widget returned in a surface (libvaxis `Button`: undecided and counted, see below), the address of a local registered and the local returned by value (zigimg `OctTreeQuantizer`), a `values()` slice kept across `swapRemoveAt` (zls `TrigramStore`, also as a struct that owns the map and fills it in a loop), a `Scanner` copied by value that shares its heap stack (lsp-kit: undecided and counted when the growth depends on room), and the arena `State` passed by value (zls `Server.loop`, missed before). The state of each in the five projects is at the end of this page.

## The five projects again

Same packs as the validations (zls, ziggy, libvaxis, webzocket, rich_zig; with std bodies, the headline of both reports, and without), the 0.17.13 binary, the first 0.17.15 binary (the one of the first version of this page) and the present one, on each pack, functions of the project only (functions of dependencies are counted apart), `FINDINGS` only, a function counted once however many packs of the project report it. `UNPROVEN` is counted apart.

| Project (packs with std) | 0.17.13 | First 0.17.15 | Now | Real now | Unproven 0.17.13 / now |
| --- | --- | --- | --- | --- | --- |
| zls (+ lsp-kit, diffz) | 35 | 2 | 3 | 3: `Server.loop`, `Workspace.refreshBuildOnSave`, `TrigramStore.init` | 5 / 0 |
| ziggy | 3 | 1 | 1 | 0 | 13 / 4 |
| libvaxis | 9 | 6 | 5 | 2: `ListView.drawBuilder`, `ScrollView.drawBuilder` | 0 / 0 |
| webzocket | 6 | 10 | 10 | 1: `Reader.decompress` (fixed on webzocket master by hotschmoe/webzocket#6; a new export of master would not report it) | 2 / 2 |
| rich_zig | 7 | 1 | 1 | 0 | 0 / 0 |
| **all** | **60** | **20** | **20** | **6** | **20 / 6** |
| all, packs without std | 65 | 25 | 19 | 6 | |

False-positive project functions: 55 before, 14 now (3.9 times fewer; 3.0 times fewer functions reported). Of the 8 known real bugs, 6 are found; `Button.draw` and the saved `Scanner` of lsp-kit are not, and are now counted (below). The first version of this page said that `TrigramStore.init` was lost; it is found again. Time: zls in 6 to 35 s, the other packs in 1 to 8 s.

## The second round: the seven points of the review of this page

**1. lsp-kit `parseFromSliceLeaky`, flagged for the wrong reason.** `Scanner.nextAllocMax` returns a token whose string is a slice of the input (`.string`) or a copy of it (`.allocated_string`); its summary says the result comes from `[the input] [fresh 0..3]`, and the checker cannot tell the arms of the union apart, so `.allocated_string => allocator.free(slice)` ended the scanner's input and every later use of the scanner (`skipValue`, `innerParse`, lines 1922 to 1953 and the rest) was a use after free. A value that is either a new block or memory the callee was lent is now a value that *may* be either: ending it ends all of them softly, and it is counted (`maybe_alias`). The reduction is `real.okNameTokens`, which is the token loop of the real function on the real `std.json.Scanner` (a use after free before, clean now). Not fixed in the same function: after the loop, the `state` union holds as one value everything ever stored in any variant (the saved scanner too), so `.response_result => |result| return ...` returns the scanner's stack, which `defer source.deinit()` ends (line 2062). Unions with one place per variant would clear it.

**The real bug of the same function is not reported.** `state = .{ .params = source }` copies the `Scanner`, and `source.skipValue()` then advances the original; the two share the heap stack (`BitStack`, an `ArrayList(u8)`), which grows only when the nesting is deeper than eight levels per byte it holds. For the checker the copy's stack is stale *if the container had no room*, which is what the footer counts as `pointers stale only if a container had no room`, and that rule I kept: reporting every use of a copy after the original may have grown would report each `append` after a copy. `real.savedScannerAdvances` is the faithful reduction (`std.json.Scanner`, the loop, a `union(enum)` that holds the saved scanner, `skipValue`, `next` on the copy), and its pinned verdict is *clean, with that count above zero*, which `tools/run_own.sh` checks. `real.badScannerCopy` (the advance grows for certain: `ensureTotalCapacity`) is reported as before. So this real bug went from lost to undecided and counted.

**2. `TrigramStore.init`: found again.** The loop that fills the store calls `appendDeclaration` from four sites; each grows the maps and `declarations`. A growth whose room the checker cannot read is a soft end, so the storage of each iteration is kept next to its replacement, and a site that runs again with a block alive makes the older name a summary that stands for several blocks. The `swapRemoveAt` after the loop then ended those names softly (38 ends counted for this function) and `lists[index]` was never a finding. But those names are not several blocks, they are the alternatives for the one block the container has in one slot: a hard end of a container's storage in a place that is not an element ends whichever of them the slot holds (`Event.exact`), summary or not. A summary does not hand such an end to its callers as certain (the caller's names for blocks that stand for several are not the callee's to end). `real.badStoreInit` is the reduction (a struct that owns the map and `declarations`, a method that fills them, called in a loop, then `values()` kept across `swapRemoveAt`), and the real function is reported again with the same two findings as the earlier reduction.

**3. `Button.draw`: lost, now counted.** The stack widget reaches the surface through the elements of a slice that `Center.draw` fills, with the child drawn through `Widget.drawFn` (a function pointer); what a callee stores in the elements of a block it allocates is not followed. The footer now says how many places have that shape: `N pointers to locals handed to calls that return a new block or that the summary does not trace (what the result keeps of them is not followed)`, on the "also assumed" line (106 in the zls pack). `real.lostWidgetChild` is `Button.draw` with the std-free types, clean and counted in both packs; `Button.draw` itself counts 1.

**4. webzocket: 10 flagged, and what they are** (the triage table below). The cluster around `Reader.done`, `deinit` and `restoreStatic` is mostly gone with the changes of this round; what is left is dominated by one cause the checker does not model, **ownership that depends on a tag**: `Buffer{ type: enum { static, pooled, dynamic }, data }`, `Text{ owns_plain: bool }`. `Reader.restoreStatic` releases `self.buf` only if `usingLargeBuffer()`, and `self.buf.data` is `self.static` otherwise; the summary has the kill (it happens on a path), the caller's `buf.data` and `static` are one identity (it assigned one to the other), and every later use of `static` is a use after free. Not fixed. What a fix needs: a guard on a kill (`param0.owns_plain == true`), and the constants a struct was built with kept in the caller's memory and in what a callee returns (`slice()` returns `owns_plain = false`). It is the first item of M4 in phase3.md and would clear most of the webzocket and rich ones.

**5. The checker flags itself: 0 findings, with and without std (286 functions).** Seven causes, no rule written for this code.

- A whole struct that nothing in the run had written read as one value (the first field read stood for all of them), and the join of a struct with a value without fields (an element of a list the checker does not follow) dropped the fields of the other side. Both keep the fields now (`readDepth`, `Val.join`); a struct stored whole from a value that does not say which field holds what takes from it only what could belong to the field (`notSiblings`). This is what spread one `State`'s `trail` into the storage of every map in it, and then the ends of those maps through two parameters.
- A read-only pointer to one object (`?*const Trail`) is not storage: a container that moves its buffer, and a callee that ends the slot, leave what it points to alone (`Types.isSingle`; the mutable `IndexHeader` of a hash map is still ended).
- What a callee writes into a slot it also ended, and the result it gives back from a block it also ended, is the new block on the paths where it ended it.
- `invalidate` of a place that is not an element replaces what the slot holds (clear a list, then read it).
- A call ends the same memory through two parameters only if another parameter of the call ended it.
- Container methods that do not insert (`get`, `contains`) do not store their arguments (`calls.call:40` reported a pointer to a local array as stored by a hash-map lookup).
- Two edits of `src/own` itself, because the code did what the checker said: `Run.step` left `r.cur`, a pointer to a caller's stack local, in the interpreter after returning (a `defer` restores it), and `condBr` ran its `then` side on `st.*` itself when the `else` side was dead and on a clone otherwise, so the two sides did not see one state (both clone now).

The self-check needs the exporter and is not in `tools/run_own.sh`: `ZVC_DEEP=1 tools/zvc_export.sh DIR src/own/main.zig --dep zv_air=src/air/air.zig --dep zv_sources=src/zvc/sources.zig`, then `zv-own --src . --module zv=src --module root=src/own --module zv_air=src/air --module zv_sources=src/zvc DIR/main.zvp` (also with `ZV_AIR_STD=1`).

**6. "747 ends of a site that stands for several allocations" (740 in the same pack now).** It counts the ends (`free`, `destroy`, `deinit`, a growth, an `errdefer`) of an identity that, at that point, stands for the summary of several blocks of one allocation site, when one block of the site was ended and the checker cannot say which. It is *undecided*: a use of another block of the same site afterwards is no error, and nothing says which block was freed, so the end is soft, and a use after it is counted (`maybe_stale`), never reported. Does it hide real bugs? It can, in one class: a double free or a use after free of *one element of a set built in a loop*, through an alias of the site; the pinned corpus has that class only through the container idioms (`Store`, `lists[i]`). The share it hides is now printed: `decided: A of B ends and C of D uses` (std packs; ends are every `end` of memory the checker follows, deduplicated by instruction):

| Pack | Ends decided | Ends counted | Uses decided |
| --- | --- | --- | --- |
| zls | 1539 of 2279 (68%) | 740 | 12444 of 12456 (99.9%) |
| ziggy lib / cli | 206 of 585 (35%) / 61 of 70 (87%) | 379 / 9 | 2645 of 2645 / 659 of 659 |
| libvaxis capi / force / tests | 1213 of 1309 / 248 of 354 / 45 of 46 | 96 / 106 / 1 | 4502 / 5244 / 638, all |
| webzocket force / tests | 54 of 60 / 428 of 482 | 6 / 54 | 580 of 604 / 1782 of 1806 |
| rich_zig force / tests | 551 of 1033 / 2249 of 2715 | 482 / 466 | 3605 / 4262, all |
| `src/own` (no std / std) | 420 of 566 / 351 of 566 | 146 / 215 | 3735 of 3735 |

Uses are almost always decided; ends are where precision was bought with counting: a third to two thirds of the ends in the code that allocates in loops (ziggy's parser, rich's renderers) are counted. I looked at what the 740 of zls are: after the change above they are the frees of the elements of a set (`for (items) |x| gpa.free(x)`, the `errdefer` of a loop that builds a list), where a second free of the same element is a real bug the checker would not see. I did not count how many such sites there are, and I cannot say none of them hides a bug.

## The false positives that nobody had looked at, one by one

14 now: ziggy 1, libvaxis 3, webzocket 9, rich 1 (`Vaxis.testResizeAllocationFailures` is no longer reported; I did not find which change removed it, so I count it as unexplained).

| Function | Real? | Cause |
| --- | --- | --- |
| ziggy `cli.lsp.textDocument/completion` | no | `docs: Io.Writer.Allocating = .init(arena)` is a local; `collectDocs(&docs.writer)` grows its buffer through the writer's vtable (an indirect call), and `docs.written()` is returned inside the result: the checker still sees the buffer as the local's. A pointer to a local given to an indirect call; it counts in `lent` |
| libvaxis `Loop._ttyRun` | no | `handleEventGeneric` stores the event in the queue after `mut_key.text = cache.put(text)`, which copies the bytes of the key text into the grapheme cache; the summary of `put` says its argument is stored, as a pointer to the `buf` and to the `parser`, which are locals |
| libvaxis `Terminal._run` | no | the loop over the bytes appends to `self.tab_stops` and reads `self.tab_stops.items` again in the next iteration; the loop head joins the state before the first iteration with the one after the growth. Cause not reduced |
| libvaxis `App.FocusHandler.update` | no | `clearAndFree` on the list, then the recursive `childHasFocus` appends to it on the way back up, then `reverse(items)`: the use reads the identity that `clearAndFree` ended. The recursion summary of `childHasFocus` is the suspect; not reduced |
| webzocket `buffer.test.buffer: grow` | no | tagged ownership: `Provider.grow` of a `.static` buffer calls `release(buffer)`, which frees only `.pooled` and `.dynamic`; the test frees `buf1.data` itself |
| webzocket `Client.readLoop`; `test Client: Handler`; `test Client: write/read` | no | tagged ownership, through `Client.read` → `Reader.read` → `restoreStatic`; the tests say "ends the same memory through two parameters", the callee's two kills of one identity |
| webzocket `Reader.read` | no | tagged ownership (`restoreStatic` and `static`) |
| webzocket `test Reader: fuzz` | no | (1) `defer reader.large_buffer_provider.deinit(); defer reader.deinit();` runs `reader.deinit()` first and then uses the provider; `Reader.deinit` does not touch it (the code says so) but the rule that a `deinit` that gives anything back ends its object does. (2) A read of `expected[i].data` after the arena reset of the previous iteration: not reduced (the same loop on its own is clean) |
| webzocket `NonBlockingBase._dataAvailable` | no | `handleClientData` ends `hc.reader` through the two parameters it is reached by: tagged ownership one call deeper |
| webzocket `NonBlockingBase.cleanupConn`, `shutdownCleanup` | no | `reader.deinit()` and then `reader.static` released separately; the code's comment says `Reader.deinit` deliberately does not touch `reader.static` |
| rich_zig `Panel.splitStyledTextIntoSegmentLines` | no | `var line_text = txt.slice(a, b); defer line_text.deinit();` in the loop: `slice` returns a `Text` with `owns_plain = false`, and `deinit` frees `plain` only if `owns_plain`: tagged ownership |

None of the 14 is real. Causes: tagged ownership (9: the webzocket ones except the `deinit` rule, rich's), the rule that a `deinit` which gives anything back ends its whole object (3, partly overlapping), a pointer to a local given to a call that writes through a vtable or copies bytes (2), a loop-carried growth or a recursion summary (2, not reduced).

## The real bugs, as of this round

Found: `ListView.drawBuilder` and `ScrollView.drawBuilder` (deinit then append), `Reader.decompress` (the stack `dumb` buffer), zigimg `OctTreeQuantizer.init` (the address of a local registered, the local returned by value), `Server.loop` (the arena `State` passed by value; 0.17.13 missed it), `TrigramStore.init` (a `values()` slice kept across `swapRemoveAt`) and `Workspace.refreshBuildOnSave` (confirmed by the review: a double free and a double close on `error.Canceled`, and the log prints the freed `build_root` on the other errors). Not found, counted: the saved `Scanner` of lsp-kit (stale only if the container had no room) and `Button.draw` (a stack widget in the elements of a block a callee fills). The target of this work, at least three times fewer false positives without losing a known real bug, is met on the first half (3.9 times) and on the second for 6 of the 8 known real bugs; the 2 others are undecided and counted, no longer silent.

**What stays assumed**, besides the list in phase3.md: the recursion summaries are a guess until they settle (8 rounds at most); a callee that failed leaves a growing container as it was and nothing else; the writes of a function are certain if they happen on every path that goes on after a `try` (the paths that return an error do not make them uncertain), except for a block it allocates; a function pointer's result depends on nothing (counted, together with the pointer to a local it was given).
