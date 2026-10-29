# Phase 3: `zv-own`, the static ownership checker

`zv-own` reads zig-zv AIR packs ([phase1.md](phase1.md)) through the `zv_air` module and reports ownership mistakes where they are made: a `zv.Linear` value consumed twice or not at all, memory used after it was freed, a pointer that outlives what it points into. It is the compile-time form of what the runtime ledger (`zv.Linear`, `zv.Pool`, `zv.Slots`) catches only when a test reaches the path. It links no compiler code (design rule 5) and needs no solver.

```
tools/zvc_export.sh OUT_DIR FILE.zig [--dep NAME=FILE.zig]...   AIR pack of a file (Debug, fixed target)
zig build zv-own                                                 zig-out/bin/zv-own
zv-own [--src DIR] [--module NAME=DIR] [--only PATH] [--files PREFIX] [--project NAME] [--expect FILE] [--pins FILE]
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

- Calls to functions that are not in the packs, or whose body the checker could not read to the end, and that it has no model of, are assumed to neither end identities nor keep their arguments. `zv-own: assumed, not checked: N calls ...` counts them.
- A linear value handed to memory the function does not own (`out.* = token`, a store through a pointer parameter, an `append` or `put` into a container) is a transfer: the function is no longer responsible for it, and the checker stops following it. The count is printed too.
- More assumptions have their own count, printed on a second line when it is not zero: a container method that is neither in the packs nor in the table (taken to invalidate), an operation on memory the checker cannot name a place for (a pointer a callee handed out; its effects are not applied), and a `resize` or `remap` by a length it cannot show to be non-zero (taken not to free).
- What the checker cannot decide is counted on a third line and never reported: a use of a pointer that may lead into freed memory without the checker being able to tell which it leads into, a pointer that is stale only if a container had no room (a reserve of a size it cannot read; a heap that sifts), an end of an allocation site that stands for several allocations, and the functions that assume two pointer parameters of one type do not overlap.
- Joins are path-insensitive in what they remember of conditions: facts from two paths are united, so a finding means "on some path". Two branches on the same condition are not correlated, except the test of an optional or an error union, which refines what the place it was read from holds.
- The footer counts the project's functions (`--project`, by default the modules `target` and `root`) apart from the functions of its dependencies, which are checked, printed and counted on a line of their own.

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

## M2: ownership by identity

### What the checker follows

A value carries the set of **identities** it may lead into, and a copy of the value carries the same set. An identity is a thing that has a lifetime, and it is named by what it is, not by where it is stored:

| Identity | Born at | Ends at | Finding |
| --- | --- | --- | --- |
| a stack slot | an `alloc` | the function returns | pointer to a local returned, stored into memory that outlives it, or put into a container that keeps it |
| an allocation (a block, a pool handle, the storage a container grew) | a call that allocates: `mem.Allocator.alloc/create/dupe/realloc`, `fmt.allocPrint`, `MemoryPool.create`, `initCapacity`, any function with an allocator parameter whose result points somewhere, or a callee whose summary says a fresh block flows out | `free`, `destroy`, `realloc`, a container operation that reallocates or releases it, the object or region it belongs to ending | use after free, double free |
| what the caller gave | a parameter: the value of the parameter (`init`, `b == 0`), the memory behind a pointer parameter (`b == 1`), the elements kept inline (`b == 2`) | the same operations, in the callee | the callee's summary says what it ended |
| an object (an arena, a container, a pool) | the first time the aggregate stored at a place is used as one | `deinit`, a body that sets `self.* = undefined`, a function named `deinit` that gives anything back | use after deinit; every allocation made from it ends with it |

Ending an identity replaces it, in every value of the path that holds it (the memory, the values already computed), by its **tombstone**; using a value that holds a tombstone is the finding. Because the tombstone is in the values, it is exactly as correlated as they are: a loop whose head joins the state before the first iteration with the state after a growth no longer thinks that the storage of the first iteration is stale when it is read. A tombstone is *soft* when the checker cannot tell: the identity stands for several allocations (see below), or an end through an element of many, or a growth that depends on room it could not read, or the end of a value that may be one of several. A soft tombstone is counted and never reported.

**Memory is field by field.** A struct whose fields the pack knows is stored as one place per field, so a copy of it copies the identities of every field (a copy of an `ArrayList` header shares the storage identity; `deinit` of either ends it), a store to one field leaves the others as they were, and `fn deinit(self: T, gpa)` that frees `self.a` and `self.b` frees two identities. An aggregate also has an object identity of its own, stored beside its fields; a copy carries it, and a whole-value store of a fresh value (`x = .empty`, `self.* = next`) removes it, so the next use starts a new incarnation. Each constant index of an array is a place of its own (a copy `lists[1] = lists[0]` is a copy); a variable index is one place for all the elements, and an end through it is soft.

**Allocations are named by site, with two names.** A site has a name for its most recent block and a name for the summary of every older one. When a site runs again while its block is alive (a loop, a second call of a helper's wrapper), the first name is demoted into the summary in the state and in the values the path has computed, and the new block takes the first name: a pointer to an old block never reads as the new one, and a loop that grows a list in every iteration settles after two rounds with the storage of the last iteration alive and the ones before it stale. The summary stands for several blocks, so an end of it is soft. A block that was ended is a tombstone wherever it is held, so its name is free to use again. Distinct call sites are distinct identities, and a callee that returns two allocations returns two identities (`fresh` 0 and 1 of its summary).

**Containers are read from their bodies.** With std in the pack, `append` is known to replace the storage identity of `list.items` by a fresh one and to end the old one because its body does (`remap`, `free`, a `self.items = new`); `pop`, `shrinkRetainingCapacity`, the `AssumeCapacity` methods do not. Without std bodies the same facts come from the table `src/own/spec.zig`: which methods grow (replace the storage), which shift (elements move: `insert`, `orderedRemove`, `swapRemove`; room excuses a growth and not a shift), which sift in a data-dependent way (a heap: soft), which move the buffer out (`toOwnedSliceAssert`, `toArrayList`: the container is empty afterwards), which release it (`toOwnedSlice`: a new block, the old pointers stale), which start with room (`initCapacity`, `initBuffer`), and what a result points into (`getPtr`, `items`, iterators). The model of a method is used only where the pack has no body, except `deinit` and the documented semantics a body cannot show (the hash maps' header and keys are one block reached by pointer arithmetic), which are kept in both. The two packs agree on every pinned case.

**Room** is followed on a container made of a constant (`.empty`), of `initCapacity(n)` or `initBuffer(&array)`: `ensureTotalCapacity(n)` and `ensureUnusedCapacity(n)` with a constant `n` raise the capacity known, an insertion or `appendSlice` of a literal of known length counts against it, a removal lowers the count, and an operation into room that is known to be there reallocates nothing. A reserve of a size the checker cannot read (`ensureTotalCapacity(gpa, n)`) makes a later growth of that container soft.

**A summary is a list of effects over access paths rooted at the parameters**, computed from the function's own run and substituted by the caller with its own identities:

- what it ended: the value or the memory below a parameter (`content` at a path, an `object`), and which parameter values it freed on every path that returns;
- what the memory below a pointer parameter holds when it returns (`writes`, with the source of every identity: a slot of an argument, or the `k`th fresh allocation of the callee), and whether on every path;
- where the result comes from, field by field, and which pointer parameter it is;
- which fresh allocations end with which object (an arena the callee allocated from).

The caller reads what the result and the writes hold as they are **before** it applies the callee's ends, so a callee that returns `self` and reallocates `self.items` returns the identities of `self` and invalidates the storage below it: different identities, no interference (class A). A write that did not happen on every path joins with what the place held, minus what the call itself ended. A free is the callee's only when it is on every path that returns. A recursive function starts from "frees everything, does nothing else" and repeats until its summary is the one it assumed (eight rounds at most, then its calls are counted).

### Precision decisions (each one came from a false positive on real code)

- A pointer into the storage of a field depends on that storage's identity, not on the stack slot that holds the container, and not on the object: appending to `v.relied` does not stale a pointer into `v.arena_state`.
- A struct read out of an array or slice is a copy of what was stored there: its pointers lead elsewhere. The elements a container holds are not part of its storage (freeing an element is not freeing the slice); a store through a pointer into a container's storage is recorded in the summary and is not followed in memory.
- `getOrPut` hands back the slot for the caller to fill in, which is where a key is replaced by an owned copy: the key it is given is not kept. The entry put into a container by `put(&local)` is pending until the function returns, and a removal ends it (the registry idiom).
- `realloc` and `remap` end the old allocation when they succeed, and not on the path where they failed.
- `appendSlice` copies elements: a pointer to a local array passed to it does not escape. An argument that points into the storage the call reallocates is a finding (`list.appendSlice(gpa, list.items)`).
- A pointer to a local stored into a container that outlives the call is only an escape if it is still there when the function returns: `put(&ctx)` followed by `remove` is the registry-for-the-duration-of-a-call idiom, and a `try` that failed stored nothing.
- A call through a function pointer is a call to a function nothing is known of: counted, and its result depends on nothing. An unknown call that is given an allocator and hands out a pointer hands out an allocation from it; one that returns a struct keeps the allocator in the field made for it.
- An element read out of an array or slice is one of many: an allocation site names all of them, so freeing it does not say the next one is freed.
- The test of an optional or error union refines what the place it was read from holds on the branch where it is null: `if (x) |p| { free(p); x = null; }` and the next guarded free do not meet.
- `isLive` is a question about a handle, not a use of it; a number read out of a stale handle is data; `Slots.free` of a stale handle fails with `error.StaleHandle`, which is a double free only where the error is propagated with `try`, not where it is swallowed (`catch {}`, the cancel idiom).
- Moves that clear their source are modelled: `toOwnedSlice`, `toArrayList`, `fromOwnedSlice` (the list and the slice are one identity), `mem.swap` (each place keeps its own incarnation), a plain copy followed by a reinitialization.
- Labeled switch loops (`continue :sw`) are interpreted like loops: every case runs from the state at the head, a dispatch is a back edge, the head is the join of everything that reaches it. A loop settles when the state at its head stops growing.
- A global is a place that outlives the function; the address of a pointer converted to an integer and back is `UNPROVEN`, as before.

- A read-only pointer to one object (`?*const Trail`) borrows: a container that moves its buffer and a callee that ends the slot leave what it points to alone. The mutable single pointers (the `IndexHeader` of a hash map) are owned and end.
- A struct nothing in the run has written reads as its fields, each one the caller's own memory; a struct stored whole from a value that does not say which field holds what takes from it only what could belong to the field; the join of a struct with a value without fields keeps the fields.
- A result that is either a new block or memory the callee was lent (the payloads of a union such as `std.json.Scanner.Token`) is a value that may be either: ending it is soft.
- What a callee writes into a slot it also ended, and what it returns from a block it also ended, is the new block on the paths where it ended it; `invalidate` of a place that is not an element replaces what the slot holds; a hard end of a container's storage ends whichever of the names that stand for the block the slot holds (`Event.exact`), and a summary does not hand that end to its callers as certain.
- The writes of a function are certain if they happen on every path that goes on after a `try`: the paths that return an error (a `wrap_errunion_err` or an error constant) do not make them uncertain, except for a block the function allocates, which the failing paths do not make.
- A call ends the same memory through two parameters only if another parameter of the call ended it.

### What is not followed (printed at the end of every run, never silent)

- Calls to functions outside the packs with no entry in the table are assumed to neither end identities nor keep their arguments. The count is printed.
- What is stored inside a std container is not followed (an element is one of many); a linear value appended to a list is counted as handed to memory the checker does not follow.
- Heap leaks (an allocation neither freed nor handed on) are the debug allocator's job, not this checker's.
- Two pointer parameters of one type are taken not to overlap inside a function; a call that passes one object twice is checked at the call (`freeBoth(&list, &list)`), and a function that ends or changes memory through two such parameters counts in the footer (`alias_params`).
- A site that runs again before its previous block was ended stands for several blocks from then on: ending one of them is counted (`summarized`), not reported.
- A value that may be one of several identities (a join of two pointers) that is freed ends them all softly; the use of a pointer that may lead into freed memory, where the checker cannot tell which, is counted (`maybe_alias`), and so is a pointer that is stale only if a container had no room (`maybe_stale`).
- Operations on memory the checker cannot name a place for (a pointer a callee handed out, with no place) are not applied and counted (`blind`).
- A pointer to a local handed to a call that returns a new block or that the summary does not trace (the elements of a block a callee fills, a function pointer) is counted (`lent`); what the result keeps of it is not followed.
- The footer prints how much was decided: `decided: A of B ends and C of D uses of memory it follows`; an end of an identity that stands for several blocks is the one that is not (`summarized`).

### Running it on code that is not a test

The first design of M2 was fitted to this repository and to zmoltcp, and the two validations (zls and ziggy, libvaxis and webzocket and rich_zig) showed what that was worth: 37 of the 38 and 26 of the 30 functions of the projects that were reported were false positives. The rewrite is measured on them in [reviews/own-2.md](reviews/own-2.md).

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
| freeing through an array element twice; a helper that frees only on one path | 2 | 1 (the element: a constant index is a place of its own) | 0 | 1 (the helper) |
| zmoltcp-shaped (a stale DNS query handle, a socket kept over local buffers, stored or returned; `own/seeded.zig` in zmoltcp) | 4 | 4 | 0 | 0 |
| the first adversarial review (`tests/own/review1.zig`, [reviews/own-1.md](reviews/own-1.md)): a pointer an invalidating call hands out (`addOne`, `addManyAsSlice`, `getOrPut`), a view that copies raw pointers (`keyIterator`, `MultiArrayList.slice`), `@fieldParentPtr`, `@atomicLoad`/`@atomicRmw`, recursive free of an allocation and of a handle, `fromOwnedSlice`, `resize(0)`, `remap(0)`, a reallocating `insert`, a subslice free, a token handed to `append`, bytes copied over tokens, and the path machinery (labeled block, `switch`, `try`, `errdefer`, a comptime-false branch) | 23 | 21 | 1 (bytes copied over tokens) | 1 (a token appended to a list: clean, and counted in the footer) |
| ordinary allocator-heavy code (`tests/own/stdcode.zig`): a slice, value pointer, `getOrPut` pointer or key slice kept across growth, use after `deinit`, `toOwnedSlice`, `remap`, a freed tree, a pointer into a slab kept across `acquire`, intrusive `@fieldParentPtr` after `destroy`, atomics after free, `cmpxchg` after free, a mutually recursive free, a list adopted twice, a pointer into an interner's names, an old buffer used after a wrapper around `realloc`, a pointer into a list of lists kept across growth, a pointer from a user method held across a call that grows, a slice kept across a helper that appends, a loop of `put`s, `addOne` across `insert`, `append` inside `for (list.items) |*p|`, a double `deinit`; a helper that frees on one path only; a `remap` whose result is ignored | 26 | 24 | 0 | 2 (the helper, the ignored result) |
| the second adversarial review (`tests/own/review2.zig`, `review2b.zig`, [reviews/own-2.md](reviews/own-2.md)): by-value copies of every container, of an arena and of a struct, `insert` under proved room, `@atomicStore` of a pointer, `fromOwnedSlice` then grow, deque and pool, two parameters that alias, and the review's controls | 70 | 67 | 0 | 0 (3 are counted: a heap sifts an element that depends on the data) |
| the mistakes found in the five projects, reduced (`tests/own/real.zig`), and labeled switch loops (`switchloop.zig`) | 8 | 8 | 0 | 0 |
| **total** | **225** | **211 (93.8 percent)** | **4** | **7** |

Before the first review the table had 98 seeded mistakes and 90 found (91.8 percent); the 49 added by that review and the 78 added by the second were chosen by a reviewer and by me after reading the review, not before the rules they exercise, which is why the percentage barely moves. Not silently accepted: 219 of 225 (97.3 percent: found, unproven, or counted in the footer; it was 140 of 147). The seven misses are documented limits (`gap*` in the corpus and the appended token): a rule the checker was not told, what is stored inside a container or behind a map slot, and a callee that frees on one path only. Two correct programs are reported and pinned as known false positives: `fpCorrelatedBranches` (two branches on the same condition are not correlated) and `ctrlGetPtrThenPut` (a pointer into a hash map is kept across one `put` that happens not to reallocate, because std's first allocation has spare slots; the checker models the contract, not the growth policy). Of the verdicts pinned before 0.17.15, two changed: `gapDoubleFreeOfElement` is now found, and `fpOwnedAssertThenDeinit` (a known false positive) is clean.

Correct code, which must stay clean:

| Code | Functions | Findings | Unproven |
| --- | --- | --- | --- |
| `tests/own`: the correct cases (`ok*`) and the idiomatic allocator-heavy program `realish.zig` (lexer, parser, interning, LRU, writer) | about 90 | 0 | 0 |
| this repository: `src/air`, `src/zvc`, `src/own`, `examples/` (before M4) | 540 | 0 | 0 |
| this repository after M4: `src/zvc`, `src/own`, `tools/zv_air_cli.zig`, each exported without and with std | about 550 | 0 | 0 |
| `tests/own/stdcode.zig`: 49 `ok*` functions and the methods of an interner and a slab, over `ArrayList`, `HashMap`, `StringHashMap`, `AutoArrayHashMap`, `MultiArrayList`, `PriorityQueue`, nested containers, arena-backed containers and `mem.swap` (each ran clean under `std.heap.DebugAllocator`), without and with std | 68 | 0 | 0 |
| the 9 correct programs of the first review | 9 | 1 (`ctrlGetPtrThenPut`) | 0 |
| `fpOwnedAssertThenDeinit` (`tests/own/stdcode.zig`), written after the review | 1 | 0 | 0 |
| the correct programs of the second review (`ok*`, `eat*`, `finishArena`, ...) | 29 | 0 | 0 |
| the reductions of the false positives on zls, ziggy, libvaxis, webzocket and rich_zig (`fp_zls*.zig`, `fp_idioms.zig`, `fp_loops.zig`): 12 classes of the first report, 12 causes of the second | 75 | 0 | 0 |
| zmoltcp 0.5.4, production code with its generics instantiated (`own/zmoltcp.zvp`, checked with the 0.17.15 checker; the seeded verdicts of `own/seeded.zig` match too) | 986 | 0 | 0 |
| this repository, `src/own` (the checker itself, 286 functions), exported without and with std | 286 | 0 and 0; the first version of this work gave 8 and 7 (a recursive interpreter handing a state it keeps using to a callee that grows its maps); the causes are in [reviews/own-2.md](reviews/own-2.md), point 5 | 0 |
| zmoltcp 0.5.3 as `zig build test` reaches it, tests and laws included (measured before M4, not re-run) | 5297 | 0 | 0 |

During development the same code produced about 40 false positives and 9 unproven functions before the precision decisions above were made; each is recorded there. The review showed what that 0 was worth: the old figure was fitted to zmoltcp, which has no allocator, and to this repository, and 9 of the ordinary `ArrayList` and `HashMap` programs the reviewer wrote were reported. The rate on code that was not fitted is now measured on `tests/own/stdcode.zig` (68 correct functions, 0 reported, though the first run with std bodies reported two of them, `okCache` and `okWordCount`, for a reason that was a bug in the checker, recorded in M4; one more correct program written after the review is reported and pinned, `fpOwnedAssertThenDeinit`) and on the review's 9 (1 reported, and pinned as such). The 0 on zmoltcp is a statement about code without containers that own memory; it says little about the rest. Seeded cases are written by people who know what the checker does; most of the earlier ones were written before the rules they exercise; four were corrected when the checker was right and the case was wrong (a loop that I thought was a gap and was a real stale pointer, a `memcpy` case that was correct, a carried token case, an unreachable `return &x` that Zig itself rejects), and none was weakened to pass.

Annotation burden: zero lines in all of the above, except the one-line manifest of `tests/own/registry.zig`. zmoltcp, which has no allocator at all and takes every buffer from its caller, needed none and gets no findings; the interesting surface there is the DNS socket's `zv.Slots` handles and the lending of local buffers to sockets, both in the corpus.

Cost: `zv-own` checked the 986 production functions of zmoltcp and its seeded cases in about 20 s of `zig build own own-seeded` (a build of the checker included; Windows, 0.17.15). The 1,277 functions of zls with std take 6 s to 35 s in ReleaseSafe depending on the load of the machine (0.17.13: 9.6 s). The model costs more per function than the one it replaced: a state is a larger structure and an end rewrites the values that hold the identity; three things keep it in bounds (a branch whose failing side never returns is not run, a state that cannot be used again is moved and not copied, and a summary whose result may be any of more than twelve allocations of its callee stands for them all) and a recursion of mutually calling functions still takes a few seconds on zls (`analysis.resolveUnionTag` with the functions it recurses through: 6.8 s).

### Assumptions the verdict rests on (printed with every run)

- Calls to functions outside the packs, or whose body could not be read to the end, with no entry in the table neither end identities nor keep their arguments. zmoltcp: 149 such call sites in the production pack (once per call site), almost all into std's formatting, math and memory functions.
- A container method that is neither in the packs nor in the table is taken to invalidate and counted; an operation on memory the checker cannot name (the pointer came from a call and points into storage with no place of its own) is not applied and counted; `resize` and `remap` by a length it cannot show to be non-zero do not free, and are counted.
- The first reallocation of an empty container moves everything: std's growth policy (spare slots) is not a rule the checker knows.
- Room is followed on a container made from `.empty`, `initCapacity` or `initBuffer` in the same function, and where a constant says it: `ensureTotalCapacity(n)` for a constant `n`, an insertion, an `appendSlice` of a literal. A growth after a reserve of a size it cannot read is counted, not reported.
- Two pointer parameters of one type do not overlap inside a function (counted per function); a call that passes one object twice is checked.
- A callee is assumed to have freed a parameter only if it frees it on every path that returns; a conditional free (a handle consumed when the query completed) is not one a caller can rely on. What it ended on some path is applied (a pointer into what a callee may reallocate is stale).
- A call that failed with an error left a container it was growing as it was; any other call is taken to have done what it did before it failed.
- Joins are path-insensitive in what they remember of conditions (two branches on one condition are not correlated, except the test of an optional or an error union); a carried linear value that the join merged is unproven, not guessed.
- What is stored inside a container or behind a map slot is not followed.
- An allocation site that runs again while its previous block is alive stands for both from then on (the most recent block and a summary of the older ones): an end of the summary is counted, not reported.
- A call through a function pointer returns a value that depends on nothing (counted). A real bug that flows through one (a stack widget whose `draw` is called through its table, libvaxis `Button`) is not seen, and the pointer to a local given to such a call is counted (`lent`).

### Dead ends

- Tracking the owners of the elements a container holds (`list.append(gpa, x)` then `list.items[0]`) made the slice itself look like the elements: freeing `loaded.items[i]` in a loop killed the slice, with a false positive in `src/air/reader.zig`. Removed; it is the cause of two of the three misses.
- Carrying a pointer's owners through every load made `self.items` depend on `self`, and `gpa.free(self.buf)` end the parameter itself.
- A coarse owner for the result of every call (the whole object the callee was given) staled the arena allocator whenever any field was appended to: 14 of the false positives in `src/zvc`; summaries now say below which field a result depends.
- Writing the elements a container appends into its place (so that `list.items[0]` after `list.append(gpa, ptr)` would carry `ptr`) was tried again for M4, now that std's bodies make it possible, and removed again for the same reason: freeing an element is not freeing the slice. What a std callee stores is only used for the escape check and the summary.
- Killing storage that was copied into an object when the object ends (`prog.gpa = gpa; prog.deinit()` ended the caller's `gpa`). Only storage a call moved (`mem.swap`) goes with the object it moved into.
- A schema-3 `fields` table with a flag per type was dropped for one that lists only the types used by value: the others' layout may not be resolved when the exporter runs, and the table would then depend on which other functions the compile analyzed.

- Keying owners by the place a value is stored in (0.17.13): a copy is a new place, so ending the copy did not end the original, and several allocations behind one place were one owner. It was the cause of 24 of the 35 misses of the second review and of the false positives of both validations; replaced by identities.
- One dead set for the whole path, with a pointer made alive again when the load that read it runs again (0.17.13, and the first version of this one): a loop head that joins the state before the first iteration with the state after a growth then holds both the storage of the first iteration and its end. The end is now a tombstone in the values that hold the identity, so it joins with them.
- Two alternating names per allocation site, the one that is not alive being the new one: the names are reused while old values still hold them, and a loop that grows a list does not settle. A site has a most recent name and a summary name instead, and the values are renamed when it is demoted.
- A summary that mints every allocation of its callee at every call: a result that may be any of 32,457 allocations took 5 GB for 693 instructions. Only the allocations that flow out are named, and more than twelve in one result stand for one.
- Checking what is reachable from a pointer passed to a callee ("reached through a pointer passed to a call"): most reports were false positives (a freed `source` next to a tree that is freed without it). The callee's summary now says what it dereferences, and the caller checks that.

- Reporting every use of a by-value copy of a container after the original may have grown (the saved `Scanner` of lsp-kit, a real bug that depends on the nesting depth): every `append` after a copy would be a finding; kept as `pointers stale only if a container had no room`, counted.
- A pointer given to a function and returned inside a container the callee fills (libvaxis `Button.draw`): following the elements of a block a callee allocates was tried and removed for the reason above (freeing an element is not freeing the slice); counted (`lent`) instead.

### Upstream-looking bugs found on the way (not filed anywhere)

- Zig 0.17.0 `std.Io.File.Writer` on Windows: writing to a pipe whose reader has exited (`zv-own --dump | head`) reaches `unreachable` in `writeFilePositionalWindows` and `fileWriteStreamingWindows` (`.PENDING => unreachable`, "wrong File nonblocking flag") instead of returning `error.BrokenPipe`.
- `return &x` of a local `var` is a compile error, but the same address passed through any function (`firstOf(&buf)`) is accepted silently; this is the case `zv-own` exists for.

## M4: reading std

[reviews/own-1.md](reviews/own-1.md) reported 12 Debug-confirmed mistakes that `zv-own` called clean and 9 correct programs it reported, most of them from a hand-written table of what std's containers do. Since 0.17.13 the effects of std's containers are read from std: `ZV_AIR_STD=1 tools/zvc_export.sh` exports std with the project (about 10.8 MB for the review's probe file: 2,428 functions, most of which its calls never reach); `zv-air slice` cuts the pack to the project and the std functions its calls reach (it does not follow panics and the parts of std that talk to the system, which is why `Io.Writer.Allocating` has an entry in the table) and compacts every table: 842 KB for the probe, against 181 KB without std and 10.8 MB before cutting. The checker analyzes those bodies on demand like a user function, and a call is matched to a generic instance by the types of its arguments.

What the bodies show, with the identity model of M2: `append`, `ensureTotalCapacity`, `put`, `getOrPut`, `insert`, `shrinkAndFree`, `toOwnedSlice` and `deinit` replace or end the storage identities of the container because their bodies do; `pop`, `shrinkRetainingCapacity`, `clearRetainingCapacity`, `lockPointers` and every `AssumeCapacity` and `Bounded` method do not; `toOwnedSlice` of a `MultiArrayList` moves the buffer to its result and leaves the container empty, which is exactly how its body reads. `src/own/spec.zig` keeps the allocator primitives of std, the pool types of zv and `MemoryPool`, and the documented semantics a body cannot show: `deinit` ends the object, `orderedRemove` and `insert` shift, a heap sifts in a way that depends on the data, `ensureTotalCapacity(n)` makes room for a count, the `AssumeCapacity` and `Bounded` methods never reallocate, and which methods hand out pointers into storage (the hash maps' header, metadata, keys and values are one block reached by pointer arithmetic). For a pack without std bodies the table holds the same facts for each method of `ArrayList`, `MultiArrayList`, `HashMap`, `ArrayHashMap`, `Deque`, `PriorityQueue` and `Io.Writer.Allocating`; a method in neither is taken to invalidate and counted (`container methods with no model`). Where a body derives less than the table says, the table is kept (`ends`), so the pack with the std bodies is a superset of the table; `tools/run_own.sh` runs every suite on both packs against the same verdicts.

The probe pack is 181 KB (project only), 842 KB (project and the std it reaches) or 10.8 MB (all of std). The pinned packs of `tests/own` are exported twice (`tests/own/std/`).

**What is still the table's.** The first reallocation of an empty container, and any growth policy; the hash maps' result aliasing; element ownership inside containers; a `resize` by a length that is not a constant does not free. Each is in the assumptions above or in the corpus as a `gap*`.

**Next, in the order of the functions it would clear (from the 14 false positives left on the five projects, [reviews/own-2.md](reviews/own-2.md)).** (1) *Ownership that depends on a tag*: a `Buffer{ type: enum { static, pooled, dynamic }, data }`, a `Text{ owns_plain: bool }`; the callee's kill is guarded by a condition on a field of a parameter, and the caller knows the constant the struct was built with. It needs the guard in the summary (`param0.f == c`), the constants kept in memory and in the descriptions of results (`slice()` returns `owns_plain = false`), and a branch on a field refining what is known; about 9 of the 14. (2) A `deinit` that gives anything back ends the whole object, however little it releases (`Reader.deinit` leaves `static` and the provider alone); it should end the fields it ends. (3) Unions with one place per variant (the saved scanner in the `state` union of lsp-kit). (4) The elements a callee stores into a block it allocates (the `lent` count), and what a vtable call writes.
