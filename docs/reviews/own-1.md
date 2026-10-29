# zv-own adversarial review 1

A second model reviewed `zv-own` at 0.17.11 with a probe file (`tests/own/review1.zig` is that file, minus its runtime harness) and found 12 mistakes that the checker called `clean` with an empty "assumed, not checked" line, and 9 correct programs it reported. Each of the 12 was confirmed in Debug with `std.heap.DebugAllocator` (a segmentation fault where the allocator unmaps the last slot of a bucket, or a ledger count from `zv.leakedTokens()`); each of the 9 returned the value std promises and ended with `DebugAllocator.deinit` ok. The reviewer also checked what the checker did catch (the controls: use after free, a leak through `switch`, a labeled block, `try`, `errdefer`, a comptime-false branch, a reallocating `insert`, a subslice free) and found no crash.

Resolution is in 0.17.13 ([phase3.md](../phase3.md), M4). Every probe is a pinned case of `tests/own/review1.zig` with its verdict in `tests/own/review1.expect`, checked by `tools/run_own.sh` on a pack of the project alone and on a pack with the std bodies it reaches, so the documented model and the derived effects have to agree on all of them.

The root cause of most findings was one design decision: the effects of std's containers were a hand-written table in `src/own/spec.zig` that sent every method it did not list to "invalidates everything", sent the ones it did list to "reads", and left the result of an invalidating call without owners. A table cannot be right for `pop`, `ensureTotalCapacity` and `put` at once, because what they do depends on the body and on what is already reserved. M4 reads the bodies of std's containers from the pack (`ZV_AIR_STD`), keeps a small table for the allocator primitives and for what no body shows, and tracks room.

## False negatives

| # | Probe | Was | Now | Resolution |
| --- | --- | --- | --- | --- |
| 1 | `badAddOne`, `badAddManyAsSlice`, `badGetOrPutThenGrow`: a pointer returned by an invalidating call is dropped | clean, segfault | finding | The call's summary says which storage the result points into; the result gets an owner for the storage as it is after the call, and the next call that frees or reallocates it ends the owner. Without std bodies the table says per method what the result points into (`addOne`, `addMany*`, `getOrPut*`: the storage). |
| 2 | `badKeyIteratorAfterGrow`, `badMultiSliceAfterGrow`: a struct returned by value that copies raw pointers is "a copy" | clean, segfault | finding | The blanket precision rule is gone. A struct read from a field (the header of a container) holds its pointers and depends on the storage behind them; so does a struct a callee builds from them, as the callee's body shows. An element read out of an array or slice is still a copy. `HashMap.iterator` stores a pointer to the map, so it depends on the map, not on its storage (`badIteratorAfterGrow` stays clean, as the reviewer found). A pointer passed to a call is checked through: what the pointee holds must be alive (`it.next()` after the grow is a use of a stale iterator). |
| 3 | `badFieldParentPtr`: `@fieldParentPtr` drops the place | clean, segfault | finding | The result keeps the parent place when the pointer names a field. When it names nothing the checker can place (a parameter), the operation on the result is applied to everything its owners own (`boxList(&box.list).ensureTotalCapacity` ends the buffers of `box`); if even that names nothing, the operation is counted as `operations on memory it cannot name`. |
| 4 | `badAtomicLoad`, `badAtomicRmw`: atomics do not use their pointer | clean, segfault | finding | `@atomicLoad`, `@atomicRmw` and `@cmpxchg*` check that the pointer is alive (`badCmpxchgAfterFree` in `stdcode.zig`); so do `@prefetch`, `set_union_tag` and the pointer tests of optionals and error unions. Audit of the instruction switch: any other instruction that takes a pointer and has no rule is now `UNPROVEN` ("instruction X takes a pointer") instead of falling into the arm that reads its result as a number; `int_from_ptr`, comparisons and `slice_len` are the address-only exceptions. No construct of the corpus reaches the new `UNPROVEN`. |
| 5 | `badRecFree`, `badRecPool`: a recursive helper that always frees is summarized as not freeing | clean, segfault / ledger panic | finding | A function being analyzed is assumed to free everything and invalidate nothing, and is analyzed again with the summary it ended with, until the two agree (at most eight rounds, else its calls are counted). Mutual recursion is covered: results that depend on a guess are kept only until the guess changes. The guess decides what the function frees on every path and applies no other effect, so the first round cannot invent kills (it did, in a first version, on `maxId`). `okMutual`, `badMutualHeld`, `badMutualFree` in `stdcode.zig`. |
| 6 | `badFromOwnedSlice`: `fromOwnedSlice` does not take the allocation | clean, segfault | finding | The result carries the owners of the slice, `deinit` ends an object together with the allocations it holds, so the `free` that follows is a double free. |
| 7 | `badLinearInList`: a `zv.Linear` appended to a list is sunk silently | clean, 0 counted | clean, 1 counted | The token is handed to memory the checker does not follow, and the footer counts it: `1 linear values handed to memory it does not follow`. With std bodies the count comes from the store in `append`'s body; without them, from the call (`tools/run_own.sh` checks the count on both packs). It is not a finding: following the element would again make the slice look like the elements (phase3.md, dead ends). |

Documented limit, confirmed exploitable by the reviewer: `limitResizeZero` and `limitRemapZero` (a `resize` or `remap` to length 0 is a free) were clean with one counted unknown call each. Both are findings: `resize` and `remap` are primitives of the table; a constant 0 frees, `remap` ends the old allocation only where it succeeded, and a length the checker cannot show to be non-zero is counted (`resizes by a length it cannot show to be non-zero`). `badLinearBytes` was and stays `UNPROVEN`.

## False positives

| Probe | Was | Now | Resolution |
| --- | --- | --- | --- |
| `fpPopKeepsFirst`, `fpShrinkKeepsFirst`, `fpExpandToCapacity`, `fpLockPointers` | finding | clean | Their bodies free and reallocate nothing, so their summaries kill nothing. The table, for packs without std bodies, lists them as moving no storage. |
| `fpEnsureNoGrow`, `fpPutAfterEnsure` | finding | clean | Room is tracked: a container made of `.empty` has capacity 0 and length 0; `ensureTotalCapacity(n)` for a constant `n` raises the capacity known; an insertion into room that is there, and an `ensureTotalCapacity` for what is already there, reallocate nothing. A count that differs between two paths is dropped. |
| `fpGetOrPutAssume` (and `okPutAssumeCapacity`) | finding (clean) | clean | Every `AssumeCapacity` and `Bounded` method never reallocates (the contract); `getOrPutAssumeCapacity` was missing from the exception list. |
| `fpToOwnedAssert` | finding | clean | `toOwnedSliceAssert` moves the buffer without freeing; pointers read before it stay valid until the result is freed. |
| `ctrlGetPtrThenPut` | finding | finding, pinned as a known false positive | The program is correct only because std's first allocation of a hash map has spare slots, which is a growth policy, not a rule. The checker models the contract: `put` may reallocate. |
| `fpComptimeDeadDouble` | clean | clean | Not a false positive (the reviewer's note); pinned. |

A related correct program written after the review, `fpOwnedAssertThenDeinit` (a `toOwnedSliceAssert` result used after the list is deinitialized), is reported for the same reason as `fpToOwnedAssert` would be without the exception: the result is taken to be the list's storage. It is pinned as a known false positive.

## What changed in the numbers

| | Before (0.17.11) | After |
| --- | --- | --- |
| Review probes: silent misses | 12 | 0 (11 findings, 1 counted) |
| Review probes: false positives | 9 | 1 (pinned) |
| Seeded mistakes in the corpus | 98: 90 found (91.8 percent), 3 unproven, 5 missed | 140: 128 found (91.4 percent), 4 unproven, 8 missed |
| Not silently accepted | 93 of 98 | 133 of 140 |
| Ordinary allocator-heavy code written without the checker | not measured | 47 correct functions, 0 reported (2 were reported by the first version with std bodies and fixed); 1 reported later and pinned |
| This repository, about 550 function checks | 0 reported | about a dozen reported by the first version of the new rules, 0 after the fixes |
| zmoltcp production pack (986 functions, no allocator) | 0 reported | 0 reported; `own-seeded` verdicts unchanged |
| Pack for the probe file | 181 KB | 842 KB with the std functions it reaches (10.8 MB with all of std) |
| `zv-own` on the probe pack | about 30 ms | about 30 to 40 ms |

The 0 false positives of the old figure were measured on zmoltcp (no allocator) and on this repository after the rules had been fitted to it. That was true and uninformative, as the reviewer says. The new figures are on code the checker was not fitted to, and the first runs of the new rules on this repository's own source are recorded in phase3.md (M4, "Running it on code that is not a test").

## Remaining known misses

- A helper that frees on one path only (`gapConditionalFree`, `gapConditionalFreeInHelper`): not a free a caller can rely on.
- A `remap` whose result is ignored (`gapRemapIgnored`): the result says whether the memory moved, and nothing looks at it.
- What is stored inside a std container is not followed: an element of a list of heap pointers freed while the list still holds it; a token appended to a list (counted, not found); the pointer of a removed hash map entry.
- `toOwnedSliceAssert` followed by `deinit` and a use of the result (a false positive, pinned).
- The growth policy of std (spare slots on the first allocation), reallocation hidden behind a `resize` by a non-constant length (counted).
- Aliasing the checker cannot name: an operation on a pointer a callee handed out into storage with no place of its own is counted, not applied. In allocator-heavy code this is common (`gop.value_ptr.append(gpa, x)` on the value of a map entry): `tests/own/stdcode.zig` counts 3 or 4 (all in `okAdjacency`).
