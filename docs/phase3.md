# Phase 3: `zv-own`, the static ownership checker

`zv-own` reads zig-zv AIR packs ([phase1.md](phase1.md)) through the `zv_air` module and reports ownership mistakes where they are made: a `zv.Linear` value consumed twice or not at all, memory used after it was freed, a pointer that outlives what it points into. It is the compile-time form of what the runtime ledger (`zv.Linear`, `zv.Pool`, `zv.Slots`) catches only when a test reaches the path. It links no compiler code (design rule 5) and needs no solver.

```
tools/zvc_export.sh OUT_DIR FILE.zig [--dep NAME=FILE.zig]...   AIR pack of a file (Debug, fixed target)
zig build zv-own                                                 zig-out/bin/zv-own
zv-own [--src DIR] [--module NAME=DIR] [--only TEXT] [--files PREFIX] [--expect FILE] [--pins FILE]
       [--max-unproven N] [--max-trusted N] [--summary] [--effects] [--dump] PACK|INDEX_DIR...
ZVC_DEEP=1 tools/zvc_export.sh OUT_DIR FILE.zig [--only PATH]...   a whole project: nested containers and imported files too
ZV_AIR_STD=1 tools/zvc_export.sh OUT_DIR FILE.zig                  also the std functions the project reaches (the effects of std's containers are then read from their bodies)
zv-air slice PACK OUT.zvp                                         what `ZV_AIR_STD` does to a pack, on any pack: the project and what it reaches in std
tools/run_own.sh                                                 the suite: pinned packs against pinned verdicts (CI)
zirakzigil.addOwnershipGate(b, .{ .packs = ..., .pins = ... })   `zig build own` in a consumer project
```

A function gets one of three verdicts: `clean` (the checker found nothing and nothing was outside what it models), `FINDINGS` (at least one mistake, each with `file:line:col`, the source line, notes that point at the related places and the branches taken to get there) or `UNPROVEN` (the function uses a construct outside the supported fragment, with the position and reason; it is neither accepted nor refuted). Exit status is 0 only when every function is clean, or, with `--expect`, when every verdict equals the pinned one.

## What a verdict means, and what it does not

`clean` means: on every path the checker followed, every `zv.Linear` value is consumed or handed on exactly once, and (from M2) no memory is used after the operation that ended it. It is relative to a model with stated limits, listed here and printed at the end of every run:

- Calls to functions that are not in the packs, or whose body the checker could not read to the end, and that it has no model of, are assumed to neither end owners nor keep their arguments. `zv-own: assumed, not checked: N calls ...` counts them.
- A linear value handed to memory the function does not own (`out.* = token`, a store through a pointer parameter, an `append` or `put` into a container) is a transfer: the function is no longer responsible for it, and the checker stops following it. The count is printed too.
- Three more assumptions have their own count, printed on a second line when it is not zero: a container method that is neither in the packs nor in the table (taken to invalidate), an operation on memory the checker cannot name a place for (a pointer a callee handed out; its effects are not applied), and a `resize` or `remap` by a length it cannot show to be non-zero (taken not to free).
- Joins are path-insensitive: facts from two paths are united, so a finding means "on some path". Two branches on the same condition are not correlated.
- Aliasing is by identity of the pointer value, not by address: two pointers to the same object that the checker cannot tell apart are two objects. Distinct pointer parameters are assumed not to overlap.

## M1: linearity

### The annotation syntax: the types

A signature says who owns what; nothing else is written.

| In the signature | Meaning | Checked in the function | Checked at the call |
| --- | --- | --- | --- |
| `fn f(t: zv.Linear(T))` | takes ownership | consumed or handed on on every path | the argument is consumed |
| `fn f(t: *const zv.Linear(T))` | borrows | cannot consume it | the argument must still be owned |
| `fn f() zv.Linear(T)` | hands ownership to the caller | returns a live token | the result is a new token |
| `struct { tok: zv.Linear(T), ... }` | linear too | every field consumed or handed on | consumed as a whole |
| `?zv.Linear(T)`, `E!zv.Linear(T)` | exists where the value does | refined at `if (x) \|t\|`, `try`, `catch` | |

`zv.holdsLinear(T)` is the comptime form of the same question, for a generic container that must not silently accept a type whose ownership it does not model (`examples/ledger.zig` pins its answers with `comptime` asserts). The sink is `Linear.consume`, the source `Linear.init`; both are ordinary functions whose bodies are not checked (the checker skips module `zv`).

The decision to let types carry the ownership, and not a parameter annotation, follows from what AIR gives: a by-value parameter of a linear type is the signature fact, and it is checked in both directions (in the callee that it discharges it, at the caller that it gives it up).

### The model

The function is run abstractly over its AIR: structured control flow (`block`, `cond_br`, `switch_br`, `try`, `loop`), joined at the end of each construct. A value is a set of **tokens** (and, field by field, a tree of them); a token is born at a `Linear` value's creation (a call that returns one, a parameter, a load that finds one) and is **live** until a **sink** ends it: passing it by value to a call, returning it, or storing it into memory the function does not own. A token that is ended and used again, or still live where the function returns, is a finding.

The facts a path carries are two sets, *may be live* and *may be ended*, plus the contents of the function's stack slots. At a join they are united; the finding names the path (`path: 26:9 else;`: the branches taken since the function started). A use of an optional or error union is refined by the test that guards it, so `if (slot) |t| consume(t)` does not leak on the path where `slot` is null, and `try` does not leak a result that does not exist.

AIR is the right level for this: `errdefer` and `defer` are already expanded into every exit, so an error path that returns early shows its cleanup (or its absence) in the instruction stream.

Loops run to a fixed point on the facts and once more to report. When a join has merged two different tokens into one value (a token carried round a loop and replaced), consuming it while one of them was already consumed cannot be decided without knowing which, and the function is `UNPROVEN` (`advLoopCarried*` in `tests/own/linear.zig`).

### What is outside the fragment (UNPROVEN, with the reason printed)

- a linear value read out of memory the function does not own (`const t = out.*` through a parameter): taking a value out of borrowed memory leaves two owners;
- a pointer to a linear value passed to a function that is not in the packs;
- an array or vector of linear values, a union holding one, `memcpy` of linear values;
- inline assembly, labeled switch loops, calls through function pointers, instructions of a type the exporter does not decode.

### Cases

`tests/own/linear.zig` holds 12 clean cases (`ok*`), 17 mistakes (`bad*`) and 7 adversarial ones (`adv*`: a token copied through a variable, a struct and an optional, carried round a loop, read through a pointer). `tests/own/linear.expect` pins every verdict. The runtime test `tests/should_panic/double_consume.zig` is now also rejected at compile time:

```
FINDINGS double_consume.main
    tests/should_panic/double_consume.zig:12:19: consumed twice: linear value `w` was already consumed
         12 |     ledger.deposit(&pool, b, copy); // money printed from nothing -> must panic
            |                   ^
      note    tests/should_panic/double_consume.zig:11:19: first passed on here (`ledger.deposit`)
      note    tests/should_panic/double_consume.zig:9:34: `w` was created here
```

## Schema v3

`zv-own` needs to know which structs hold a `Linear`, so the pack gained a `fields` table (`schema.FieldRec`: owner type, index, name, type). The compiler exports the fields of the types a function uses by value, and of what they hold by value: those are the types whose layout the function's own analysis resolved, so the table does not depend on which other functions the compile analyzed. A type without records has no known fields (empty, or only ever behind a pointer); two types the pack cannot tell apart by their printed name that disagree on a field are marked `conflict` and read as unknown. Readers accept schema 2 (no table) and 3; `tests/zvc/*.zvp` were exported again and `zvc` is unchanged.

## M2: allocator regions, pointer invalidation, stack escapes

### What the checker follows

Besides linear tokens, a value carries the **owners** its pointers depend on. An owner is born where the AIR shows it and ends where an operation ends it; using a value that depends on an ended owner is a finding.

| Owner | Born at | Ends at | Finding |
| --- | --- | --- | --- |
| an allocation | a call that allocates: `mem.Allocator.alloc/create/dupe/realloc`, `fmt.allocPrint`, `toOwnedSlice`, any function with an allocator parameter whose result points somewhere, a function whose summary says it returns an allocation | `free`, `destroy`, `realloc`, `toOwnedSlice`; the arena it came from is deinitialized or reset | use after free, double free |
| a pool slot | `zv.Pool.alloc`, `zv.Slots.alloc` (the handle is the owner) | `free` of that handle | stale handle, double free, pointer from `get(h)` used after `free(h)` |
| the storage behind a field | every load of a pointer or slice out of memory (`list.items`), and of a struct made of such fields (an iterator, a slice view) | an operation that frees or reallocates that storage (read from the callee's body: the `free` or `remap` of what it loaded from the field), or one the documented model says moves elements (`orderedRemove`, `insert`), or `deinit` | use after invalidation |
| an object | `arena.allocator()` and kin | `deinit` | use of the object or of what it handed out |
| a stack slot | `alloc` | the function returns | pointer to a local returned, stored into memory that outlives it, or put into a container that keeps it |

**Inference, not annotation.** The allocator flow is read off the calls: a result that comes from a function with a `mem.Allocator` argument is an allocation from it (and from the arena behind that allocator, so `arena.deinit()` ends it); a function in the packs is read for what it does (its **summary**: which parameters its result depends on and below which field, which places it invalidates, which parameters it frees, whether it returns an allocation, whether it stores a parameter into another), so a user helper that frees or reallocates needs no word either. **std's containers are read the same way** when the pack holds their bodies (`ZV_AIR_STD=1`, see M4): `append` is known to invalidate `list.items` because its body calls `remap` or `free` on what it loaded from there, and `pop`, `shrinkRetainingCapacity`, `lockPointers` and the `AssumeCapacity` methods are known not to because their bodies do not. Only the true primitives are a table (`src/own/spec.zig`): the methods of `mem.Allocator`, the arena and the other allocator objects, `zv.Pool`/`zv.Slots`, `mem.swap`, and the few documented semantics a body cannot show (`orderedRemove` shifts elements without freeing anything; `deinit` ends the object). For a pack without std bodies the same table also holds a model of the container methods; a method in neither is counted, never silently accepted. What remains is a project's own invalidation rule: one line in the `ownership` manifest of the type.

```zig
pub const Registry = struct {
    pub const ownership = .{ .remove = .invalidates };   // pointers handed out by get() are stale after remove()
    comptime { zv.requireOwnership(Registry); }          // a typo or an unknown kind is a compile error
    ...
};
```

Kinds: `.invalidates`, `.ends`, `.resets`, `.releases`, `.reads`, `.handle`, `.free`, and `.trusted`, which exempts a function from the check and counts it (`--max-trusted`, `max_trusted` of the gate). `tests/own/registry.zig` shows the effect: with the line `badRegistryStale` is a finding, without it (`gapPlainStale`) the checker cannot know and says clean. That is the annotation burden of a project-specific rule: one line per method, and none for code that only uses std, allocators and the pools of zv.

### Precision decisions (each one came from a false positive on real code)

- A pointer into the buffer of a field is `list.items`-shaped: it depends on that field's storage, not on the stack slot that holds the container, and not on the whole object (`Buf(place)` is per field, so appending to `v.relied` does not stale a pointer into `v.arena_state`).
- A struct read out of an array or slice is a copy of what was stored there: its pointers lead elsewhere. A struct read from a field (the header of a container, an iterator) holds the pointers of its fields and depends on the storage behind them, and so does a struct a callee builds out of them (`keyIterator`, `MultiArrayList.slice`); which it is comes from the callee's body (what it loaded and where), not from a blanket rule. An iterator that stores a pointer to the map (`HashMap.iterator`) depends on the map object, not on its storage, so a later `put` does not stale it.
- Room is followed. A container made of a constant (`.empty`) has capacity 0 and length 0; `ensureTotalCapacity(n)` with a constant `n` raises the capacity known; an insertion into room that is known to be there does not reallocate, and neither does `ensureTotalCapacity(n)` when `n` is already available. A length that differs between two paths, or an `appendSlice`, is not followed; the first reallocation of an empty list or map is assumed to move everything (std's spare slots on the first allocation are its growth policy, not a rule).
- `getOrPut` hands back the slot for the caller to fill in, which is where a key is replaced by an owned copy: the key it is given is not kept. The entry put into a container by `put(&local)` is pending until the function returns, and a removal ends it (the registry idiom).
- `realloc` and `remap` end the old allocation when they succeed, and not on the path where they failed: `if (gpa.remap(buf, n)) |bigger| ... else gpa.free(buf)` is correct code.
- `appendSlice` copies elements: a pointer to a local array passed to it does not escape.
- A pointer to a local stored into a container that outlives the call is only an escape if it is still there when the function returns: `put(&ctx)` followed by `remove` is the registry-for-the-duration-of-a-call idiom, and a `try` that failed stored nothing.
- A call through a function pointer is a call to a function nothing is known of; it is counted in the assumptions, not refused.
- `reset` ends what the arena handed out, not the arena; a second `reset` is not a use after deinit.
- An element read out of an array or slice is one of many: an allocation site names all of them, so freeing it does not say the next one is freed (a loop that cancels `handles[k]` for some k).
- A callee is assumed to have freed a parameter only if it frees it on every path that returns; `isLive` is a question about a handle, not a use of it; a number read out of a stale handle is data. A recursive function is analyzed to a fixed point (starting from "frees everything, invalidates nothing" and repeating until the summary it ends with is the one it assumed), mutual recursion included; a function that does not settle in eight rounds is not read and its calls are counted.

### What is not followed (printed at the end of every run, never silent)

- Calls to functions outside the packs with no entry in the table are assumed to neither invalidate nor keep their arguments. The count is printed.
- A pointer converted to an integer and back (`ptr_from_int`) is `UNPROVEN`. So is any instruction that takes a pointer and that the checker has no rule for (the atomic operations are checked for a live pointer; `@cmpxchg`, `@atomicRmw`, `@atomicLoad`, `@prefetch` and the pointer tests of optionals and error unions are used like a load).
- What is stored inside a std container is not followed: an element is one of many (a `zv.Linear` appended to a list is counted as handed to memory the checker does not follow).
- A pointer to a local that a callee stores somewhere the caller cannot see (a global, a field behind another pointer) is not seen: a summary does not yet record stores into parameters.
- A pointer read in one iteration and used in a later one is revived when the same load runs again, so a stale copy kept across iterations of the same site is not seen; it is reported when the pointer is used on the iteration that follows the invalidation.
- Heap leaks (an allocation neither freed nor handed on) are the debug allocator's job, not this checker's.
- A pointer into a container that goes into a struct field of a different local is followed by value only through the places the checker names; deeper aliasing (two pointers to one object) is not tracked.

### Running it on code that is not a test (false positives found and removed)

The first run over `src/air`, `src/zvc` and `src/own` of this repository (about 520 functions of real, allocator-heavy Zig, exported with `ZVC_DEEP=1 tools/zvc_export.sh`) reported 23 findings and 9 unproven functions; every finding was a false positive (one was the registry idiom, which the code does on purpose and which is now recognized), and the changes above removed them. After them: 0 findings, 0 unproven on all of them, and `tests/own/memory.zig` still reports its 46 seeded mistakes (80 cases pinned in `tests/own/memory.expect`).

The same run after M4 (review 1, below), on `src/zvc`, `src/own` and `tools/zv_air_cli.zig` with their imports (about 550 function checks, each pack exported twice: the project alone, and with std): the first run reported about a dozen findings, all false positives, from the rules that were new (a scope entered again in a loop kept its arena dead; a `get` on a hash map that copies a struct out of its storage was taken to point into it; the key `getOrPut` is given was taken to be kept; a `put(&local)` that is taken out again by `defer remove` was reported at the `put`; the optimistic assumption for a recursive call freed and invalidated the parameters of the real call; storage that was merely copied into an object was killed with it). Each is removed by a rule recorded in M4 and none of the pinned verdicts was changed to get there. After them: 0 findings, 0 unproven.

## M3: the gate

### Pinned types

A struct that holds a `zv.PinCheck` by value records its own address, so copying it by value is a bug (`tests/should_panic/pin_copy.zig` panics at run time). `zv-own` reports a load of a pinned type from a named local, a parameter's pointee or any pointer (`const moved = original;`, `byValue(n.*)`, `return w.inner;`); the compiler's own temporary for a fresh `return .{ ... }` is not a copy of anything the program named and is not reported (`tests/own/pinned.zig`).

### Aliasing writes

`@memcpy` needs disjoint memory. Two ranges of one array whose offsets and sizes are constants (`buf[0..6]` onto `buf[2..8]`) are decided: overlapping is a finding. A dynamic range is left to the safety check, which Zig compiles into every Debug and ReleaseSafe build and which reports it at run time; only ReleaseFast loses it, and there it stays unseen (`okMemcpyDynamic`).

### What is checked where

| Mistake | `zv-own` (static, every path, every build mode) | Runtime ledger and safety checks (only what a test runs, only in safe builds) |
| --- | --- | --- |
| a `zv.Linear` consumed twice, not at all, or used after | yes, with the path | `zv.Linear` ledger panic, `zv.leakedTokens()` |
| use after free, double free of an allocation | yes | DebugAllocator |
| use after free of a `zv.Pool` or `zv.Slots` handle | yes (a pointer taken through the handle dies with it) | generational check: panic / `StaleHandle` |
| pointer stale after `append`, `put`, `remove`, ... | yes (std; one manifest line for a project's own type) | nothing (silent in every mode) |
| arena memory used or returned after `deinit` / `reset` | yes | DebugAllocator, if the arena's child frees the pages |
| pointer to a local returned or kept | yes | nothing in release; sometimes a compile error |
| pinned struct copied by value | yes | `zv.PinCheck.check()` on the next method call |
| `@memcpy` of overlapping constant ranges | yes | safety panic in safe builds |
| a leak of an allocation | no | DebugAllocator, `std.testing.allocator` |
| anything through a pointer converted to an integer; memory a callee hands to a global | unproven / assumed (printed) | as above |

The runtime layer stays: it covers what the static one does not follow (leaks, dynamic indices, data-dependent paths the abstraction merges), and it is what a build that compiles out checks needs a test for. `zv-own` replaces it only where the table says "yes".

### Measurements

Corpus (all pinned in `tests/own/*.expect`, run by `tools/run_own.sh`; CI on Linux and Windows):

| Class of seeded mistake | Seeded | Finding | Unproven | Missed |
| --- | --- | --- | --- | --- |
| linearity: copy of a token, leak on a branch, on an error path, in a loop, overwrite, field, optional, use after consume | 20 | 18 | 2 (a token carried round a loop and left in it; a token copied out of `*T`) | 0 |
| allocation: use after free, double free, free of a subslice, realloc, free in a branch or loop, defer order, through an alias, struct, optional, variable | 18 | 18 | 0 | 0 |
| containers: pointer or slice kept across `append`, `put`, `orderedRemove`, `deinit`, in a loop, through a helper, through a parameter | 14 | 14 | 0 | 0 |
| arenas and regions: escape after `deinit`, allocator after `deinit`, stale after `reset`, list in an arena | 5 | 5 | 0 | 0 |
| stack: returned slice of a local, stash through `*[]u8`, fixed-buffer allocation, local pointer in a container, a buffer lent to a socket that outlives it, a socket returned with a local buffer, a global | 10 | 10 | 0 | 0 |
| handles: `zv.Pool` and `zv.Slots` stale, double free, pointer after free, take then get | 7 | 7 | 0 | 0 |
| pinned copies, aliasing `memcpy` | 5 | 5 | 0 | 0 |
| a project's own invalidation rule | 2 | 1 (with the manifest line) | 0 | 1 (the same type without it) |
| one-line mutations of a realistic program (`tests/own/realish_bugs.zig`) | 7 | 5 | 0 | 2 (use after free through a hash-map slot; through an element of a list) |
| a pointer laundered through an integer | 1 | 0 | 1 | 0 |
| freeing through an array element twice; a helper that frees only on one path | 2 | 0 | 0 | 2 |
| zmoltcp-shaped (a stale DNS query handle, a socket kept over local buffers, stored or returned; `own/seeded.zig` in zmoltcp) | 4 | 4 | 0 | 0 |
| the first adversarial review (`tests/own/review1.zig`, [reviews/own-1.md](reviews/own-1.md)): a pointer an invalidating call hands out (`addOne`, `addManyAsSlice`, `getOrPut`), a view that copies raw pointers (`keyIterator`, `MultiArrayList.slice`), `@fieldParentPtr`, `@atomicLoad`/`@atomicRmw`, recursive free of an allocation and of a handle, `fromOwnedSlice`, `resize(0)`, `remap(0)`, a reallocating `insert`, a subslice free, a token handed to `append`, bytes copied over tokens, and the path machinery (labeled block, `switch`, `try`, `errdefer`, a comptime-false branch) | 23 | 21 | 1 (bytes copied over tokens) | 1 (a token appended to a list: clean, and counted in the footer) |
| ordinary allocator-heavy code (`tests/own/stdcode.zig`): a slice, value pointer, `getOrPut` pointer or key slice kept across growth, use after `deinit`, `toOwnedSlice`, `remap`, a freed tree, a pointer into a slab kept across `acquire`, intrusive `@fieldParentPtr` after `destroy`, atomics after free, `cmpxchg` after free, a mutually recursive free, a list adopted twice, a pointer into an interner's names, an old buffer used after a wrapper around `realloc`; a helper that frees on one path only; a `remap` whose result is ignored | 19 | 17 | 0 | 2 (the helper, the ignored result) |
| **total** | **140** | **128 (91.4 percent)** | **4** | **8** |

Before the review the table had 98 seeded mistakes and 90 found (91.8 percent); the 42 added since were chosen by a reviewer and by me after reading the review, not before the rules they exercise, which is why the percentage barely moves while 11 of the 12 silent misses became findings (the twelfth is counted). Not silently accepted: 133 of 140 (95.0 percent: found, unproven or counted in the footer; it was 93 of 98). The eight misses are documented limits (`gap*` in the corpus and the appended token): a rule the checker was not told, what is stored inside a container or behind a map slot, an element of an array (one of many), and a callee that frees on one path only. Two correct programs are reported and pinned as known false positives: `fpCorrelatedBranches` (two branches on one condition are not correlated) and `ctrlGetPtrThenPut` (a pointer into a hash map is kept across one `put` that happens not to reallocate, because std's first allocation has spare slots; the checker models the contract, not the growth policy).

Correct code, which must stay clean:

| Code | Functions | Findings | Unproven |
| --- | --- | --- | --- |
| `tests/own`: the correct cases (`ok*`) and the idiomatic allocator-heavy program `realish.zig` (lexer, parser, interning, LRU, writer) | about 90 | 0 | 0 |
| this repository: `src/air`, `src/zvc`, `src/own`, `examples/` (before M4) | 540 | 0 | 0 |
| this repository after M4: `src/zvc`, `src/own`, `tools/zv_air_cli.zig`, each exported without and with std | about 550 | 0 | 0 |
| `tests/own/stdcode.zig`: 31 `ok*` functions and the methods of an interner and a slab over `ArrayList`, `HashMap`, `StringHashMap`, `AutoArrayHashMap`, `MultiArrayList` and arenas (each ran clean under `std.heap.DebugAllocator`), without and with std | 47 | 0 | 0 |
| the 9 correct programs of the first review | 9 | 1 (`ctrlGetPtrThenPut`) | 0 |
| `fpOwnedAssertThenDeinit` (`tests/own/stdcode.zig`), written after the review | 1 | 1 | 0 |
| zmoltcp 0.5.4, production code with its generics instantiated (`own/zmoltcp.zvp`) | 986 | 0 | 0 |
| zmoltcp 0.5.3 as `zig build test` reaches it, tests and laws included (measured before M4, not re-run) | 5297 | 0 | 0 |

During development the same code produced about 40 false positives and 9 unproven functions before the precision decisions above were made; each is recorded there. The review showed what that 0 was worth: the old figure was fitted to zmoltcp, which has no allocator, and to this repository, and 9 of the ordinary `ArrayList` and `HashMap` programs the reviewer wrote were reported. The rate on code that was not fitted is now measured on `tests/own/stdcode.zig` (47 correct functions, 0 reported, though the first run with std bodies reported two of them, `okCache` and `okWordCount`, for a reason that was a bug in the checker, recorded in M4; one more correct program written after the review is reported and pinned, `fpOwnedAssertThenDeinit`) and on the review's 9 (1 reported, and pinned as such). The 0 on zmoltcp is a statement about code without containers that own memory; it says little about the rest. Seeded cases are written by people who know what the checker does; most of the earlier ones were written before the rules they exercise; four were corrected when the checker was right and the case was wrong (a loop that I thought was a gap and was a real stale pointer, a `memcpy` case that was correct, a carried token case, an unreachable `return &x` that Zig itself rejects), and none was weakened to pass.

Annotation burden: zero lines in all of the above, except the one-line manifest of `tests/own/registry.zig`. zmoltcp, which has no allocator at all and takes every buffer from its caller, needed none and gets no findings; the interesting surface there is the DNS socket's `zv.Slots` handles and the lending of local buffers to sockets, both in the corpus.

Cost: `zv-own` checked the 986 production functions of zmoltcp in 0.3 s and the 5297 reached by its tests in 1.9 s (Debug build of the checker, Windows, 0.17.11). After M4, ReleaseSafe on Windows: the 225 functions of `src/own` take 0.13 s before and 0.23 s after (the fixed point and the extra bookkeeping), with or without std in the pack; the 986 of zmoltcp run through `zig build own` in the time of the build. The price of reading std is the pack: see M4.

### Assumptions the verdict rests on (printed with every run)

- Calls to functions outside the packs, or whose body could not be read to the end, with no entry in the table neither invalidate nor keep their arguments. zmoltcp: 223 such calls in the production pack (it was 879 in the pack of everything the tests reach), almost all into std's formatting, math and memory functions.
- A container method that is neither in the packs nor in the table is taken to invalidate and counted; an operation on memory the checker cannot name (the pointer came from a call and points into storage with no place of its own) is not applied and counted; `resize` and `remap` by a length it cannot show to be non-zero do not free, and are counted.
- The first reallocation of an empty container moves everything: std's growth policy (spare slots) is not a rule the checker knows.
- Room is followed only where a constant says it: `ensureTotalCapacity(n)` for a constant `n`, on a container made from `.empty` in the same function.
- Distinct pointer parameters do not overlap.
- A callee is assumed to have freed a parameter only if it frees it on every path that returns; a conditional free (a handle consumed when the query completed) is not one a caller can rely on.
- Joins are path-insensitive (two branches on one condition are not correlated); a carried linear value that the join merged is unproven, not guessed.
- What is stored inside a container or behind a map slot is not followed.
- An allocation is one owner per allocation site: a pointer freed once on each iteration of a loop is a double free to the checker.

### Dead ends

- Tracking the owners of the elements a container holds (`list.append(gpa, x)` then `list.items[0]`) made the slice itself look like the elements: freeing `loaded.items[i]` in a loop killed the slice, with a false positive in `src/air/reader.zig`. Removed; it is the cause of two of the three misses.
- Carrying a pointer's owners through every load made `self.items` depend on `self`, and `gpa.free(self.buf)` end the parameter itself.
- A coarse owner for the result of every call (the whole object the callee was given) staled the arena allocator whenever any field was appended to: 14 of the false positives in `src/zvc`; summaries now say below which field a result depends.
- Writing the elements a container appends into its place (so that `list.items[0]` after `list.append(gpa, ptr)` would carry `ptr`) was tried again for M4, now that std's bodies make it possible, and removed again for the same reason: freeing an element is not freeing the slice. What a std callee stores is only used for the escape check and the summary.
- Killing storage that was copied into an object when the object ends (`prog.gpa = gpa; prog.deinit()` ended the caller's `gpa`). Only storage a call moved (`mem.swap`) goes with the object it moved into.
- A schema-3 `fields` table with a flag per type was dropped for one that lists only the types used by value: the others' layout may not be resolved when the exporter runs, and the table would then depend on which other functions the compile analyzed.

### Upstream-looking bugs found on the way (not filed anywhere)

- Zig 0.17.0 `std.Io.File.Writer` on Windows: writing to a pipe whose reader has exited (`zv-own --dump | head`) reaches `unreachable` in `writeFilePositionalWindows` and `fileWriteStreamingWindows` (`.PENDING => unreachable`, "wrong File nonblocking flag") instead of returning `error.BrokenPipe`.
- `return &x` of a local `var` is a compile error, but the same address passed through any function (`firstOf(&buf)`) is accepted silently; this is the case `zv-own` exists for.

## M4: hardening after the first adversarial review

[reviews/own-1.md](reviews/own-1.md) reports 12 Debug-confirmed mistakes that `zv-own` called clean with an empty "assumed, not checked" line, and 9 correct `ArrayList` and `HashMap` programs it reported. Most came from one place: the hand-written table of what std's containers do (`spec.zig`), classifying every method it did not list as "invalidates everything" and the few it did as "reads", and leaving the result of an invalidating call without owners. The root-cause changes:

**std's effects are read from std.** `ZV_AIR_STD=1 tools/zvc_export.sh` exports std with the project (about 10.8 MB for the review's probe file: 2,428 functions, most of them the test runner and the stack-trace printer); `zv-air slice` cuts the pack to the project and the std functions its calls reach (it does not follow panics and the parts of std that talk to the system) and compacts every table: 842 KB for the probe, against 181 KB without std and 10.8 MB before cutting. The checker analyzes those bodies on demand like a user function. A call is matched to a generic instance by the types of its arguments (instances of one function share a name; before M4 the first one found stood for all of them). What the bodies show:

- `free(x)`, `realloc`, `remap` and `resize(x, 0)` of a value read from a field end the storage behind that field, wherever the value came from: `append`, `ensureTotalCapacity`, `put`, `getOrPut`, `insert`, `shrinkAndFree`, `toOwnedSlice`, `deinit` get their kills from `remap` and `free` in their bodies, and `pop`, `shrinkRetainingCapacity`, `expandToCapacity`, `lockPointers`, `unlockPointers`, `clearRetainingCapacity` and every `AssumeCapacity` and `Bounded` method get none. `realloc` and `remap` end the old allocation only where they succeeded.
- What a result points into: `addOne`, `addManyAsSlice`, `getOrPut`, `getPtr` hand out pointers into the storage and keep them valid until the next kill; `keyIterator`, `valueIterator` and `MultiArrayList.slice` copy the raw pointers of the container's fields, so they depend on its storage; `HashMap.iterator` stores a pointer to the map and depends on the map.
- `fromOwnedSlice` gives the container the allocation of its argument, so `deinit` followed by `free` is a double free. `mem.swap` (and so `HashMap.grow`, which swaps a fresh map with the old one and deinits the old) moves storage from one object to another.
- Recursion: a summary of a function being analyzed is a guess, `frees everything and invalidates nothing`, and the analysis repeats until the summary it ends with is the guess. A guess is used only to decide what the function frees on every path; its calls apply no other effect.

**What bodies cannot show is documented, small, and counted when missing.** `spec.zig` keeps the allocator primitives and these documented semantics: `deinit` ends the object, `orderedRemove`, `swapRemove`, `insert`, `sort` and `clearRetainingCapacity` shift or drop elements without freeing, a hash map's `remove` moves nothing, `ensureTotalCapacity(n)` and `ensureUnusedCapacity(n)` make room for a count, the `AssumeCapacity` and `Bounded` methods never reallocate, and which methods hand out pointers into the storage (the hash maps' header, metadata, keys and values are one block reached by pointer arithmetic, which the abstract domain does not follow; the model supplies it). For a pack without std bodies the table holds the same facts for each method of `ArrayList`, `MultiArrayList`, `HashMap` and `ArrayHashMap`; a method that is in neither is taken to invalidate and counted in the footer (`container methods with no model`).

**Other holes of the review.** `@fieldParentPtr` keeps the place of the parent when the pointer names a field, and otherwise the owners, on which an operation then acts (`boxList(&box.list).ensureTotalCapacity`); an operation on a pointer with no place and no owner to name is not applied and counted (`operations on memory it cannot name`). `@atomicLoad`, `@atomicRmw`, `@cmpxchg*`, `@prefetch` and the pointer tests of optionals and error unions check that the pointer is alive; any other instruction that takes a pointer and has no rule is `UNPROVEN` instead of being read as a number. A token passed to `append` or `put` is counted as handed to memory the checker does not follow (a std callee's own run is not counted, so the count is once per call site).

**Cost.** The probe pack is 181 KB (project only), 842 KB (project and the std it reaches) or 10.8 MB (all of std); `zv-own` takes about 30 ms on each of the first two and 125 ms on the last, which includes analyzing every std function a call reaches. Exporting with `ZV_AIR_STD` costs the same compile; the pinned packs of `tests/own` doubled in number (`tests/own/std/`, 3 MB for eleven sources) and `tools/run_own.sh` runs every suite twice against the same pinned verdicts, so the table and the derived effects have to agree on the whole corpus (they do, on all 140 seeded mistakes and 47 ordinary functions). zv-own is 0.13 s to 0.23 s on its own source (above).

**What is still the table's.** The first reallocation of an empty container, and any growth policy; the hash maps' result aliasing; element ownership inside containers; `toOwnedSliceAssert` followed by `deinit` and a use of the result is reported (`fpOwnedAssertThenDeinit`: the result is taken to be the container's storage); pointers into a removed hash map entry are not stale; a `resize` by a length that is not a constant does not free. Each is in the assumptions above or in the corpus as a `gap*`.
