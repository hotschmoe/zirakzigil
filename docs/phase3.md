# Phase 3: `zv-own`, the static ownership checker

`zv-own` reads zig-zv AIR packs ([phase1.md](phase1.md)) through the `zv_air` module and reports ownership mistakes where they are made: a `zv.Linear` value consumed twice or not at all, memory used after it was freed, a pointer that outlives what it points into. It is the compile-time form of what the runtime ledger (`zv.Linear`, `zv.Pool`, `zv.Slots`) catches only when a test reaches the path. It links no compiler code (design rule 5) and needs no solver.

```
tools/zvc_export.sh OUT_DIR FILE.zig [--dep NAME=FILE.zig]...   AIR pack of a file (Debug, fixed target)
zig build zv-own                                                 zig-out/bin/zv-own
zv-own [--src DIR] [--module NAME=DIR] [--only TEXT] [--files PREFIX] [--expect FILE] [--pins FILE]
       [--max-unproven N] [--summary] [--dump] PACK|INDEX_DIR...
tools/run_own.sh                                                 the suite: pinned packs against pinned verdicts (CI)
zirakzigil.addOwnershipGate(b, .{ .packs = ..., .pins = ... })   `zig build own` in a consumer project
```

A function gets one of three verdicts: `clean` (the checker found nothing and nothing was outside what it models), `FINDINGS` (at least one mistake, each with `file:line:col`, the source line, notes that point at the related places and the branches taken to get there) or `UNPROVEN` (the function uses a construct outside the supported fragment, with the position and reason; it is neither accepted nor refuted). Exit status is 0 only when every function is clean, or, with `--expect`, when every verdict equals the pinned one.

## What a verdict means, and what it does not

`clean` means: on every path the checker followed, every `zv.Linear` value is consumed or handed on exactly once, and (from M2) no memory is used after the operation that ended it. It is relative to a model with stated limits, listed here and printed at the end of every run:

- Calls to functions that are not in the packs and that the checker has no model of are assumed to neither end owners nor keep their arguments. `zv-own: assumed, not checked: N calls ...` counts them.
- A linear value handed to memory the function does not own (`out.* = token`, a store through a pointer parameter) is a transfer: the function is no longer responsible for it, and the checker stops following it. The count is printed too.
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
| the storage behind a field | every load of a pointer or slice out of memory (`list.items`) | an invalidating operation on the object: `append`, `put`, `orderedRemove`, `resize`, `clearAndFree`, `deinit`, ... | use after invalidation |
| an object | `arena.allocator()` and kin | `deinit` | use of the object or of what it handed out |
| a stack slot | `alloc` | the function returns | pointer to a local returned, stored into memory that outlives it, or put into a container that keeps it |

**Inference, not annotation.** The allocator flow is read off the calls: a result that comes from a function with a `mem.Allocator` argument is an allocation from it (and from the arena behind that allocator, so `arena.deinit()` ends it); a function in the packs is read for what it does (its **summary**: which parameters its result depends on and below which field, which places it invalidates, which parameters it frees, whether it returns an allocation), so a user helper that frees or reallocates needs no word either. std's containers and allocators and `zv.Pool`/`zv.Slots` are a table in `src/own/spec.zig`. What remains is a project's own invalidation rule: one line in the `ownership` manifest of the type.

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
- A struct returned by value from a callee that holds pointers is a copy of what was stored: its pointers lead elsewhere, so it does not depend on the container it was copied from.
- `appendSlice` copies elements: a pointer to a local array passed to it does not escape.
- A pointer to a local stored into a container that outlives the call is only an escape if it is still there when the function returns: `put(&ctx)` followed by `remove` is the registry-for-the-duration-of-a-call idiom, and a `try` that failed stored nothing.
- A call through a function pointer is a call to a function nothing is known of; it is counted in the assumptions, not refused.
- `reset` ends what the arena handed out, not the arena; a second `reset` is not a use after deinit.

### What is not followed (printed at the end of every run, never silent)

- Calls to functions outside the packs with no entry in the table are assumed to neither invalidate nor keep their arguments. The count is printed.
- A pointer converted to an integer and back (`ptr_from_int`) is `UNPROVEN`.
- A pointer to a local that a callee stores somewhere the caller cannot see (a global, a field behind another pointer) is not seen: a summary does not yet record stores into parameters.
- A pointer read in one iteration and used in a later one is revived when the same load runs again, so a stale copy kept across iterations of the same site is not seen; it is reported when the pointer is used on the iteration that follows the invalidation.
- Heap leaks (an allocation neither freed nor handed on) are the debug allocator's job, not this checker's.
- A pointer into a container that goes into a struct field of a different local is followed by value only through the places the checker names; deeper aliasing (two pointers to one object) is not tracked.

### Running it on code that is not a test (false positives found and removed)

The first run over `src/air`, `src/zvc` and `src/own` of this repository (612 functions of real, allocator-heavy Zig, exported with `ZVC_DEEP=1 tools/zvc_export.sh`) reported 23 findings and 9 unproven functions; every finding was a false positive (one was the registry idiom, which the code does on purpose and which is now recognized), and the changes above removed them. After them: 0 findings, 0 unproven on all 612, and `tests/own/memory.zig` still reports its 46 seeded mistakes (80 cases pinned in `tests/own/memory.expect`).
