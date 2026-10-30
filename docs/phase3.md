# Phase 3: `zv-own`, the static ownership checker

`zv-own` reads zig-zv AIR packs ([phase1.md](phase1.md)) through the `zv_air` module and reports ownership mistakes where they are made: a `zv.Linear` value consumed twice or not at all, memory used after it was freed, a pointer that outlives what it points into. It is the compile-time form of what the runtime ledger (`zv.Linear`, `zv.Pool`, `zv.Slots`) catches only when a test reaches the path. It links no compiler code (design rule 5) and needs no solver.

```
tools/zvc_export.sh OUT_DIR FILE.zig [--dep NAME=FILE.zig]...   AIR pack of a file (Debug, fixed target)
zig build zv-own                                                 zig-out/bin/zv-own
zv-own [--src DIR] [--module NAME=DIR] [--only PATH] [--files PREFIX] [--project NAME] [--expect FILE] [--pins FILE]
       [--max-unproven N] [--max-trusted N] [--max-undecided N] [--baseline FILE] [--write-baseline FILE]
       [--summary] [--effects] [--dump] PACK|INDEX_DIR...
ZVC_DEEP=1 tools/zvc_export.sh OUT_DIR FILE.zig [--only PATH]...   a whole project: nested containers and imported files too
ZV_AIR_STD=1 tools/zvc_export.sh OUT_DIR FILE.zig                  also the std functions the project reaches (the effects of std's containers are then read from their bodies)
zv-air slice PACK OUT.zvp                                         what `ZV_AIR_STD` does to a pack, on any pack: the project and what it reaches in std
tools/oracle/run.sh                                              generated programs against Debug ground truth: silent-miss and false-positive rates per construct
tools/run_own.sh                                                 the suite: packs from tools/own_packs.sh against pinned verdicts (CI)
zirakzigil.addOwnershipGate(b, .{ .packs = ..., .pins = ... })   `zig build own` in a consumer project
```

A function gets one of four verdicts: `clean` (no finding, and every end and every use the run met was decided: nothing is left open), `COUNTED` (no finding, but at least one end or use is counted as undecided, with the reason printed under the function), `FINDINGS` (at least one mistake, each with `file:line:col`, the source line, notes that point at the related places and the branches taken to get there) or `UNPROVEN` (the function uses a construct outside the supported fragment, with the position and reason; it is neither accepted nor refuted). Exit status is 0 when no function has a finding and none is unproven, or, with `--expect`, when every verdict equals the pinned one (a pinned `counted` also accepts `clean`: a pack with std's bodies may decide what the model leaves open; a pinned `clean` accepts nothing else). `--max-undecided N` and `--baseline FILE` fail the run when it leaves more undecided than allowed, in all and per function (below).

## What a verdict means, and what it does not

`clean` is a statement about the constructs the checker validated, not about the program. It says: on every path the checker followed, every `zv.Linear` value is consumed or handed on exactly once, no memory the run follows is used after the operation that ended it, and no end the run met was left undecided. Whatever is outside that sentence is on a list: the assumptions below (printed with every run), the counted classes, and the known silent classes at the end of this section. A reader of a `clean` should read it together with the footer of the same run.

### The invariant: no event without an outcome (0.17.22)

Four review rounds and an overseer review found silent false negatives, each in a place where a rule dropped an event before anything counted it: a free of a global, a by-value optional freed on one branch, a kill removed by a stale constant, an element end skipped. The footer counted what rules remembered to count, so it could only report what someone had tallied. The structure that replaced it:

- **Events.** An *end* is anything that stops memory from being valid or may have: a `free`, `destroy`, `realloc`, `deinit`, a container growth or shrink, an arena reset, a `toOwnedSlice`, and every kill, free, may-free, move or unexpressible end in a callee's summary applied at a call. A *use* is a read, write or pass of memory the run follows (an identity it knows: an allocation, the storage behind a parameter, an object). Memory the run has no identity for is not "followed"; ends of it are events anyway.
- **Outcomes.** Every event has an outcome: `reported` (a finding was raised), `clean` (decided without a finding, for one of a closed list of named reasons: `applied`, `empty`, `gated`, `no_realloc`, `not_heap`, `deferred`, `assumed_round`, `query`), or `counted` (left open, for one of a closed list of reasons, below). `src/own/outcome.zig` has the types.
- **One writer.** Every function that decides an event returns an `Outcome`, and `Run.settle` is the only code that writes one down (`Run.stats` has no other writer). A return type with no empty case, and an unused result not compiling, are what stop a rule from dropping an event: an early `continue` becomes `return .{ .clean = .gated }` and says why. The reasons are visible: `--effects` prints how many events each clean reason decided.
- **Backstop.** A call whose callee has an end (an allocator primitive, a container method that invalidates, a summary with kills, frees or may-frees) and whose rules settled none counts `dropped` (`ends whose rule decided nothing`). The suite pins it at zero; it exists so that a new rule that forgets the invariant is counted, not clean.
- **What the model cannot say.** A request to end memory is classified by where it points: a global (a place of root kind `global`) is counted `global` whatever was ended, because what a global holds is only partly in the run; a value with no provenance (no identity, no place: it came from memory or a call the run does not follow) is counted `untracked`; an identity the request skipped because the summary could not express it is counted `unexpressed`. A function's summary carries the reasons of the ends it made that a caller cannot see (`Summary.outside`: global, untracked, unexpressed, blind), and the caller counts them at the call: a callee that does `gpa.free(cache)` of a global has no slot to kill and used to give `0 of 0 ends`; it is now one end of a value with no provenance in the callee and in each caller.
- **May-free.** A free of a by-value parameter on one branch of a join (`if (o) |b| gpa.free(b)`) is a may-free: the state keeps the parameters freed on some path as well as on all of them (`freed_some`), where the intersection used to leave nothing and the summary said nothing.
- **Verdicts and the gate.** A function with something counted (other than an assumption) is `COUNTED`, not `clean`. `--max-undecided N` fails when the project's functions leave more than N events undecided; `--baseline FILE` (lines `NAME N`, written by `--write-baseline FILE`) fails when a function leaves more than its line says, and more than 0 when it has none. In a build: `zirakzigil.addOwnershipGate(b, .{ ..., .max_undecided = 0, .baseline = "own/undecided.baseline" })`. A count that goes down is reported as a reason to write the baseline again; it never fails.

### The classes that are counted

| Counted as | What it is | Kind |
| --- | --- | --- |
| `unknown_call` | a call to a function outside the packs, or whose body could not be read, with a pointer or slice among its arguments or result: assumed to end nothing and keep nothing | assumed |
| `transfer` | a linear value handed to memory the function does not own; the checker stops following it | assumed |
| `unmodelled` | a container method with no model and no body: taken to invalidate | assumed |
| `alias_params` | a function that ends or changes memory through two or more pointer parameters of one type: assumed not to overlap (a call that passes one object twice is checked) | assumed |
| `blind` | an operation on memory it cannot name a place for (a pointer a callee handed out): its effect is not applied | undecided |
| `dynamic_len` | `resize`/`remap` by a length it cannot show to be non-zero: assumed not to free | undecided |
| `lent` | a pointer to a local handed to a call that returns a new block or that the summary does not trace: what the result keeps of it is not followed | undecided |
| `maybe_alias` | a use or a free of something ended on some of the things a pointer may lead to | undecided |
| `maybe_stale` | a pointer into storage that an operation reallocates only if there is no room, and the room is not known | undecided |
| `summarized` | an end of an identity that stands for several allocations, one of many, a value that may be one of several, a may-free, a growth that depends on room | undecided |
| `global` | an end or a growth of a global | undecided |
| `untracked` | an end of a value with no provenance | undecided |
| `unexpressed` | an end of memory the caller sees that the function's summary cannot say (a soft end of a parameter's content, a part of a by-value parameter whose identity is merged with another) | undecided |
| `dropped` | the backstop above | undecided |

### The classes that are silent (a `clean` that is wrong), as of 0.17.22

| Class | Why it is silent | Found | Status |
| --- | --- | --- | --- |
| a call outside the packs with no pointer or slice among its arguments and result | `unknown_call` is only counted when a pointer is involved; such a call can end a global | overseer, 0.17.22 | open: assumed, not counted |
| a kill removed because a constant the run holds says the callee's condition is false (`gated`) | the constant may be stale; the decision is a named reason, counted in `--effects`, but a wrong constant is a wrong `clean` | review 4 | open: the pair `{a, b}` and "a constant that is not known to be current never deletes a kill" are the guards |
| a use of memory with no identity (a global, a pointer from a call the run does not follow) | not a use "of memory it follows"; the end that would make it a bug is counted when the run sees it | overseer, 0.17.22 | by design, so that `decided: N of N uses` reads as "of the followed ones" |
| what is stored inside a std container, or behind a map slot | an element is one of many | review 2 | by design |
| heap leaks | the debug allocator's job | design | by design |
| a free through a global, a growth of a global container | no end was recorded | overseer, 0.17.22 | fixed: counted `global`, `untracked`, and in callers through `Summary.outside` |
| a by-value optional (or a part of one) freed on its payload branch in a callee | the join intersected the freed parameters and the summary said nothing | overseer, 0.17.22 | fixed: may-free, counted `summarized` at the caller |
| a soft end of a parameter's content dropped from a summary | skipped without a trace | 0.17.22 | fixed: `unexpressed` |
| a `free`-like call with no argument to free | the rule fell through | 0.17.22 | fixed: the backstop counts `dropped` |

A differential oracle (generated programs, Debug run against `zv-own`) is the intended measure of the silent rate by construct; this table is the list of what the reviews have found, not a measure.

### What the assumptions are

- Calls to functions that are not in the packs, or whose body the checker could not read to the end, and that it has no model of, are assumed to neither end identities nor keep their arguments. `zv-own: assumed, not checked: N calls ...` counts those with a pointer or slice among their arguments or result.
- A linear value handed to memory the function does not own (`out.* = token`, a store through a pointer parameter, an `append` or `put` into a container) is a transfer: the function is no longer responsible for it, and the checker stops following it. The count is printed too.
- More assumptions have their own count, printed on a second line when it is not zero: a container method that is neither in the packs nor in the table (taken to invalidate), and the functions that end or change memory through two or more pointer parameters (assumed not to overlap).
- What the checker cannot decide is counted on a third line and never reported: the undecided classes of the table above.
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

### What is not followed (counted at the end of every run; the classes that still are not are listed under "What a verdict means")

- Calls to functions outside the packs with no entry in the table are assumed to neither end identities nor keep their arguments. The count is printed.
- What is stored inside a std container is not followed (an element is one of many); a linear value appended to a list is counted as handed to memory the checker does not follow.
- Heap leaks (an allocation neither freed nor handed on) are the debug allocator's job, not this checker's.
- Pointer parameters (of any type, slices included) are taken not to overlap inside a function; a call that passes one block to two of them is checked at the call (`freeBoth(&list, &list)`, `freeOther(gpa, p, p)`), and a function that ends or changes memory through two or more counts in the footer (`alias_params`).
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

0.17.18 added to the corpus the third review's 30 programs (`review3.zig`, `review3b.zig`: 31 functions with findings, among them the controls the identity model was built for; the bugs the footer counts instead of reporting are pinned by `tools/run_own.sh`), the tag reductions (`fp_tags.zig`: 5 correct programs that were reported and are clean, 4 seeded mistakes found) and `fp_tags2.zig`. They are not in the table above, which is the seeded set the percentage was measured on; with the review's programs in, the silent misses are the ones `docs/reviews/own-3.md` lists as counted.

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

The probe pack is 181 KB (project only), 842 KB (project and the std it reaches) or 10.8 MB (all of std). The packs of `tests/own` are exported twice (`tests/own/std/`).

**What is still the table's.** The first reallocation of an empty container, and any growth policy; the hash maps' result aliasing; element ownership inside containers; a `resize` by a length that is not a constant does not free. Each is in the assumptions above or in the corpus as a `gap*`.

**Next (after 0.17.18).** (1) The elements a callee stores into a block it allocates (the `lent` count) and what a vtable call writes: not started. (2) The undecided ends: most of them are the frees of the elements of a set and of a site that allocates in a loop; deciding them needs the identity of the element (an index that is the loop counter), which the places do not carry. (3) A non-inline predicate (`fn isLarge(self) bool`) as a summary fact: the guards read tests inside the function, not the result of a call.

## M5: ownership that depends on a tag (0.17.18)

The first item of the list above, the two after it, and the third adversarial review ([reviews/own-3.md](reviews/own-3.md)).

### Scalars, tests and guards

A number, bool or enum is a value that can be known: `Val.con` is the constant it is (an enum by the hash of its name, so that two packs agree), taken from constants, from a store, and from a branch that tested it. A scalar also remembers the place it was read from and a test of it (`cmp_eq`, `cmp_neq`, `not`; a bool read from a field is the test `field == true`), for as long as nothing wrote memory since: the run counts the instructions that may write (`epoch`), a loop starts a new one, and a scalar read in an older epoch tests nothing. A field of a parameter passed by value cannot change, so it stays good, and keeps its name when the struct is copied into a local.

- **Branches.** A branch whose test is a known constant runs only the side that can happen (it did that for constants of the program only). `if (x == c)` makes `x == c` known on the then side; a `switch` on a scalar runs the one case a known subject picks, and refines the subject in a case of one item. The facts live in the state beside the memory (`facts`), die when the place is written, and are the intersection at a join. A place that only one path wrote holds no constant after the join.
- **Guards.** The trail of the branches taken (the one findings print) carries the tests made on a scalar of the caller's memory that nothing in the run wrote yet (`touched`: only below pointer parameters; by-value fields are always good). An end is recorded with them: the summary has kills of the form `param0.buf.data when param0.buf.type == dynamic and param0.buf.type != static`, and the caller drops the kill when a test is false for what it knows (the constant its struct was built with, or a test made before the call), and keeps the others as conditions of its own parameters. `a and b` and `a or b` are blocks that return a bool: the block says which tests hold when it is true and which when it is false, so that `if (self.owns and self.len > 0)` guards the free by `owns`. Two tests of one value that cannot both hold make the path not exist.
- **Constants through calls.** A result or a write of a scalar says the constant, or the by-value scalar parameter it was copied from (`setKind(&buf, kind)` leaves what `kind` was), when every path that *returns a value* made it the same (`Reader.init` returns `buf.type = .static`; `Text.slice` returns `owns_plain = false`; `restoreStatic` leaves `static` on both paths, one by a store and one by the test it went on past). That is the constant of the success exit only. `returnsError` knows the constant `error.X` of an error union and `return err` of a local.
- **Two exits.** What the paths that return an error leave is its own fact: a write that a failing path also makes carries the constant all failing paths agree on (`Write.fail_con`), and the error side of `try` and `catch` sets that constant, or nothing known, instead of the success one (0.17.18 judged the error path by the success constant: `armTry` sets `.owned`, fails, and rolls back to `.borrowed` only on success, and the caller's `catch` was told `.borrowed`). A write only the success makes is restored on the error side; one only the failures make is the failures' constant.
- **Joins of two constants.** A scalar that is one of two constants (`if (c) k = .a else k = .b`, a loop that sets a mode) is kept as the pair: a guarded end can happen if either says so, and is then as certain as a branch in the function is (`ctrlLoopInline`, `badLoopRelease`). More than two is unknown, and an end under an unknown tag is a soft end, counted.
- **A call that cannot succeed.** The tests the paths that return a value went through are in the summary (`ok_when`); when the caller knows every such path is closed (`install(&slot, next, false)` when `!ok` returns the error), the code after its `try` is dead on that path.
- **Failed calls.** A call that fails did not do what only its successful paths do. `try` and the error side of `is_err` restore what the callee writes only when it succeeds (`Write.on_fail` says whether a path that fails writes it too), end what its failing paths end (`Kill.on_fail`) and give back what only its successful paths end. A block the callee makes is therefore a certain write on the success path, and the old block is back on the error path.
- **Writes the run cannot read.** Any write that is not a store of a constant makes the scalar unknown, never the old constant (0.17.18 kept it, and the old constant deleted the kill): `@memset`, `@atomicRmw` other than an exchange with a constant, `@cmpxchg` of a place not known to hold the expected constant, a store through a pointer cast to another type (`*u8` to a discriminant: the value is an integer, the place an enum), a store of a tag-like scalar through a pointer the run has no place for (everything it knows of tags is dropped), and a call with no summary (it may write any scalar below the pointers it was given). The summary says so (`clobbers`), so that the caller's tag dies too: `callFlip(f, &buf)` through a function pointer makes `buf.kind` unknown in the caller. An exchange with a constant and a compare-exchange of a known value are reads of a constant. Elements and lengths never hold a constant (a variable index can be any of the constant ones).

### What a `deinit` ends

A function called `deinit` that gives something back used to end its whole object. It ends what its summary ends, no more: `Reader.deinit` that leaves `static` and the provider alone no longer ends them; `Text.deinit` frees `plain` only under `owns_plain`. The object still ends when the body says so (`self.* = undefined`, a kill of the object slot).

### Unions

A union with known variants is stored and read one place per variant (`union_init` fills one part, a read of the whole union has one part per variant, the payload read of one variant sees what was stored in that variant). lsp-kit's `Message.parseFromSliceLeaky` no longer returns the scanner's stack as `.response_result`. The saved scanner of the same function (`real.savedScannerAdvances`) is not reported: whether the copy's stack was reallocated depends on the nesting of the input, and reporting it would report every append after a copy. It is counted: the call that grows the copy's stack after the original already grew it is a use of a block that may be gone (`maybe_alias`; it was counted by accident before, because a union held everything at once). A union passed by value is a struct of its variants, so that a `switch` that frees one payload (`freeSlot(u)`) says in its summary which variant it ended; naming a variant of a local union (`set_union_tag`, then a store through the variant pointer) ends the content of the others.

### Review 3

[reviews/own-3.md](reviews/own-3.md) lists the claims and what became of each. The rules that changed:

- Ending an element of an array or a slice (`gpa.free(bufs[i])`) is a soft end: it is counted (`summarized`), not dropped; a second free of an element is `maybe_alias`. A constant index and a variable index are read together (a store through `bufs[i]` may have written `bufs[0]`).
- An end that is soft for any reason (a site that stands for several allocations, one of many, a value that may be one of several, a growth that depends on room) was not decided: the footer's `decided:` no longer counts it, and the label says so.
- Overlapping pointer parameters: a function that ends or changes memory through two pointer parameters of any kind (slices, a list and a slice, the allocator in any position) counts in the footer, and a call that gives one block to two parameters, one of which the callee ends while it reads through the other (`freeOther(gpa, p, p)`, `dropAndRead(gpa, &list, list.items)`), is a finding. A slice passed by value is a read of its block.
- A by-value parameter freed on some paths only (`take(p)` that frees `p` and returns an error) ends it softly in the caller.

### Assumptions added

- Tests of scalars are trusted until a write the run can see: a call with a summary is trusted to list what it writes, a call without one clears what it can reach through pointers, and another thread or an alias the run does not know (two pointers of one type, assumed apart) can change a tag unseen.
- The state on the error path of a call is the state after the call with the successful-only writes restored, the failing paths' constants set (`fail_con`), the failing-only ends applied and the successful-only ends given back. It is not the state of the callee's failing paths, which the summary does not keep.
- A guard is exact for tests of entry values; a test made after a write to the same field is not part of it.

### Dead ends

- A scalar that remembers where it was read without the epoch: a value read, then its field written, then the old value tested, refined the memory with a stale fact.
- A fact kept as a value in the memory: a refinement then looked like a write of the callee, and the summary said the function wrote the field.
- Reporting a kill of an already invalidated block as a finding (the saved scanner): a loop that ends the same block in two rounds, and a weak write that leaves the old name next to the new one, made false double frees (`realish.internAll`); it is counted.
- A constant that is good for the success exit used for the error exit: the whole of review 4 (`docs/reviews/own-4.md`). A constant that is not known to be current must never delete a kill; the choices are unknown (soft, counted) or a set of the possible values (the pair).
- Keeping the old constant after a write the run cannot read, on the ground that "it is still the last thing we saw": `@memset`, an atomic update, a cast store, a function pointer.

### Review 4 (0.17.20)

[reviews/own-4.md](reviews/own-4.md). The rule of the repair: a constant that might be stale never suppresses a kill. The corpus numbers of the table in "Measurements" (225 seeded, 211 found) are the seeded set of the first two rounds; the programs of the reviews 3 and 4 and the tag reductions are pinned apart (`review3.zig`, `review3b.zig`, `review4.zig`, `fp_tags*.zig`), and are not in those figures.

## Overseer review (0.17.22)

An independent review of 0.17.21 wrote two files of programs (17 and 8 entry points) avoiding the mechanisms of the four earlier rounds and found seven that fault in Debug while `zv-own` said `clean` with a fully decided footer, in two ordinary classes. All of them are pinned verbatim (`tests/own/overseer.zig`, `overseer2.zig`, exported with and without std, verdicts in the `.expect` files). The repair was structural (see "The invariant: no event without an outcome"), not a new precision rule.

| Program | Debug | 0.17.21 | 0.17.22 |
| --- | --- | --- | --- |
| `badGlobalDrop`, `badGlobalDropCallee` (`gpa.free(cache)` of a global in a callee) | segfault | clean, `0 of 0 ends` | `COUNTED`: the callee `dropCache` counts an end of a value with no provenance, and so does each caller through `Summary.outside` |
| `badGlobalStructDeinit` (`state.deinit(gpa)` of a global struct) | segfault | clean | `COUNTED`: end of a global |
| `badGlobalListGrow`, `badGlobalListDeinit` (a global `ArrayList`, `items` kept across a growth or `deinit`) | segfault | clean (std bodies too) | `COUNTED`: growth and end of a global |
| `badOptionalCallee`, `badOptionalPtrCallee` (`if (o) \|b\| gpa.free(b)` with `?[]u8`, `?*Node`) | segfault | clean, `frees=0`, no count | `COUNTED`: a may-free in the summary; the caller's later read is a pointer stale only if the callee freed it |
| `badOptionalOrelse` | segfault | clean, counted | unchanged: `COUNTED` |
| `ctrlOptionalUnwrap`, `ctrlOptionalThroughPtr`, `badOptionalFieldByValue`, `badStdEql`, `badStdIndexOf`, `badBytesAsSlice`, `badMemcpySrc`, `badAnyopaque`, `badComptimeFn`, `badByValueDeref`, `badByPtrDeref`, `badReturnedGone`, `badCopyDrop`, `ctrlUseAfterFree` | segfault | FINDINGS | unchanged: FINDINGS |

`okGlobalRefill` (a global refilled after a free) is now `COUNTED` too: the checker does not follow a global, and says so. The cost is that every function that touches a global container is open; the baseline file is how a project ratchets that down.

`tools/run_own.sh` pins each of the seven with the reason the footer must give, runs the gate flags against a baseline made from the run, and fails if any run in the suite counts `dropped`.

Not done, on purpose: following a global as a place of the run (a lazily created identity for the storage behind it, strong updates, a clobber at every call that may write it, a summary slot that names it). That is a precision rule, it would turn the global cases into findings, and it would add a class of false positives for every call the run cannot read; this round counts instead. The cases are pinned as `counted` so that the day a global is followed they change to findings and the pin says so.

### What it cost (measured on the packs of the five projects and zmoltcp, 0.17.21 against 0.17.22)

No finding appeared or went away: the project findings are the same in every pack. What changed is how much is left open. The ends that used to vanish (a free of an element of a container, of a global, of a value from a call the run does not follow) are events now, and a callee's `blind` ends reach its callers. Packs with std's bodies (`ZV_AIR_STD`); the project's own functions; `decided` is ends decided of ends met.

| Project (pack) | findings | clean in 0.17.21 | clean now | COUNTED now | ends decided, 0.17.21 | ends decided, now | largest additions |
| --- | --- | --- | --- | --- | --- | --- | --- |
| zls | 3 -> 3 | 1046 | 621 | 425 | 1637 of 2262 (72%) | 1172 of 2995 (39%) | 626 ends of a value with no provenance, 1315 operations on memory it cannot name (143 before: callers now count a callee's) |
| ziggy lib | 0 -> 0 | 98 | 83 | 15 | 344 of 584 (58%) | 332 of 687 (48%) | |
| ziggy cli | 1 -> 1 | 65 | 48 | 17 | 63 of 67 (94%) | 40 of 102 (39%) | 38 ends of a value with no provenance |
| libvaxis (force) | 6 -> 6 | 503 | 442 | 61 | 236 of 354 (66%) | 215 of 443 (48%) | 34 no provenance, 2 global |
| libvaxis (capi) | 5 -> 5 | 711 | 589 | 122 | 1188 of 1294 (91%) | 1041 of 1383 (75%) | 164 no provenance |
| webzocket (tests) | 2 -> 2 | 321 | 236 | 85 | 348 of 494 (70%) | 194 of 620 (31%) | 179 no provenance, 38 global, 26 unexpressed |
| rich_zig (tests) | 0 -> 0 | 1340 | 1044 | 296 | 2483 of 2721 (91%) | 2397 of 3083 (77%) | 380 no provenance |
| zmoltcp (986 functions) | 0 -> 0 | 986 | 986 | 0 | 6 of 6 | 6 of 6 | none: it has no allocator and no global memory |

Reading: the "no provenance" ends are almost all the idiom `for (list.items) |e| allocator.free(e.field)`: an element of a container is one of many and is not followed, so a double free of an element (freed in the loop, freed again by a `deinit` that walks the same list) was invisible and is now counted. The project functions that fall from `clean` to `COUNTED` are the ones that free or grow what the run does not follow; a project ratchets them with `--baseline`. No rule was added to win precision back. `dropped` is zero in every pack. Time: about 25% more on zls under a loaded machine (2m12s to 2m45s, nostd pack, both runs sharing the CPU with other jobs).

## Tokens (0.17.19)

`zv.PointsTo` is a linear value for `zv-own` too, with the same rules as `zv.Linear` plus one for tokens in memory the caller owns (a read takes the token out, a write puts one back, and a token taken out and not put back is a finding). The names of the type and its operations come from `src/air/tokens.zig`, shared with `zvc`. Cases in `tests/own/tokens.zig`; the account of what is and is not followed is in [phase4.md](phase4.md). One verdict of the earlier corpus changed: `linear.advViaPointer` (a `Linear` read out of `*Tok` and consumed) was unproven and is an error.

## The differential oracle (0.17.25)

`tools/oracle/run.sh` generates small allocator-heavy programs from a seed, decides by running them in Debug whether each one has a memory error, runs `zv-own` on the same programs (with and without `ZV_AIR_STD`), and publishes the silent-miss and false-positive rate per construct with the minimized silent misses. A silent miss is a faulting program that `zv-own` calls `clean` with nothing counted in that function's footer. It measures the property the hand-written reviews sample, with a fixed seed so the numbers compare across versions. First report: [reviews/oracle-1.md](reviews/oracle-1.md); nightly in `.github/workflows/oracle.yml`.
