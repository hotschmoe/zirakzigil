# Phase 4: permission tokens and a verified core

Phase 4 is the Verus part of the plan: raw-memory code is verified by pairing the memory with a linear ghost token, so the solver never reasons about aliasing, only about small arithmetic goals. M1 (0.17.17) builds the token, the rules `zvc` applies to it, and a bump allocator over a fixed byte buffer that `zvc` proves. The exit gate of the phase is "the core is `.verified` and the `.trusted` count is falling"; this document says what M1 reaches of it and what the rest costs.

```
zv.PointsTo                          src/zv.zig       the token, ghost-only (void in production)
examples/bump.zig                    the allocator    7 functions .verified, a checked shell, 2 laws
tests/zvc/tokens.zig                 23 verdicts      what zvc must refuse about tokens, and their controls
tools/run_zvc.sh                     the suite        tokens.expect, bump.expect
```

## The token

```zig
pub const PointsTo = if (ghost) struct {
    lo: usize,
    hi: usize,
    pub inline fn own(buf: []const u8) Self      // the one source of tokens: [0, buf.len), a premise
    pub inline fn split(self: Self, cut: usize) Pair   // [lo, cut) and [cut, hi); needs lo <= cut <= hi
    pub inline fn join(head: Self, tail: Self) Self    // needs head.hi == tail.lo
    pub inline fn discard(self: Self) void
} else void;
```

A token is the right to use the bytes `[lo, hi)` of one region, owned by whoever holds the value. It is ghost the way `zv.Int` is: in a ghost build it is a struct of two words, elsewhere it is `void`, so a field of this type costs nothing (`@sizeOf(Bump)` is 2 words in production and 4 in a ghost build; a test pins it). It has no pointer in it. As in Verus, the address (here an offset into the region) and the permission are separate values, and the allocator manages the offsets: the bytes stay with the caller, who turns an offset into a slice in the shell.

Specifications talk about positions, not lengths. `split` takes the position of the cut, a block has an `end` and not only a `len`, and "these two blocks are disjoint" is `x.end <= y.off`: a chain of comparisons. This was learned the hard way. The first version used lengths (`off + len`), every proof had an identity of 64-bit modular arithmetic in it, and `pair` took 44 s. With positions, `carve` takes 35 ms and the whole file about 14 s.

### Threading

`zvc` follows no pointer parameters (docs/phase2.md), so M1 is written in the style the fragment allows: the allocator is a value that goes in and comes out, and so is every token.

```zig
pub const Bump = struct { cap: usize, next: usize, free: zv.PointsTo };         // free: [next, cap)
pub const Block = struct { base: usize, off: usize, end: usize, perm: zv.PointsTo };  // perm: [base, end)
pub fn alloc(b: Bump, len: usize, alignment: usize) Result    // Result = { bump: Bump, block: ?Block }
pub fn free(b: Bump, blk: Block) Bump
pub fn reset(b: Bump, used: zv.PointsTo) Bump
```

`alloc` takes the allocator and gives back a new one; the token inside `b.free` is cut in two (`split(end)`): the head goes to the block, the tail to the new allocator. A block's token covers its alignment padding too (`base` is where the allocator was), so every token ever handed out is a piece of one contiguous tiling of `[0, next)`. That is what makes `reset` and `free` checkable: `reset` takes `used`, the join of every outstanding block (`[0, next)`), which is the proof that nobody holds a block any more; `free` of the last block joins its token back to `b.free`, and `join` requires that they meet.

Ghost expressions in the same source use the idiom of `zv.Int`: `const parts = if (zv.ghost) b.free.split(end) else {};` and `.free = if (zv.ghost) parts.tail else {}`. Specifications read token fields behind `!zv.ghost or ...`. In a normal build every token disappears.

A specification may not read a token it already passed on, as in Verus: `roundTrip` copies `p.lo` and `p.hi` before `split(p)` and compares the result with the copies.

## What `zvc` does with a token

The token is an ordinary struct to the solver (two `usize` variables). What makes a proof about it sound is five rules in `src/zvc/vc.zig`, none of which asks the user for anything:

1. **Identity.** Every token value has an identity (`Obj.token`). A copy of a token is the same token; a token read twice from a parameter is one token (its variable names it); `split`, `join` and `own` make new ones.
2. **Consumption.** `split`, `join` and `discard` consume their arguments, and so does passing a token (or a struct, optional or error union holding one, found through the type) by value to a call. A call is a move: the callee may hand the token back inside its result, which is a new token.
3. **Use after consumption is an obligation.** Reading a field of a consumed token, passing it, returning it or consuming it again is the obligation `not (consumed on this path)`. Consumption is recorded with the path condition, so the answer is exact after a join: `maybeGive` is refuted at `c = true`.
4. **Forging is outside the fragment.** A token is built or changed only inside the bodies of the `zv.PointsTo` operations. A literal, a field store (`perm.hi = 1000`), a struct copy that rebuilds one, or a result of a function that is only `.checked` is UNPROVEN, not a proof. The operations themselves are ordinary Zig that `zvc` interprets, with `requires` that become obligations of the caller: there is no axiom about tokens in the solver.
5. **Loops.** A loop may not consume a token that existed before the iteration (a second iteration would find it gone); tokens carried by a cell the loop stores to are fresh at every head, as other havoced values are.

What this proves of the allocator, with the property and the way it is stated:

| Property | Where it comes from |
| --- | --- |
| in bounds | `carve` requires `off <= end <= cap` and its `split(end)` requires `end <= free.hi == cap`; the block's token is `[base, end)` |
| aligned | `padTo` ensures `(n +% pad) & (alignment - 1) == 0`; `alloc` ensures `blk.off & (alignment - 1) == 0` and `blk.off +% len == blk.end` |
| disjoint from every other live block | blocks are pieces of a tiling: `alloc` ensures `blk.base == b.next` and `r.bump.next == blk.end`, so the next block starts at or after this one's end. `pair` proves it for a caller that knows only `alloc`'s contract: `x.end <= y.off` and `x.perm.hi <= y.perm.lo` |
| free and reset obligations | `free` requires the block to be the last one (`blk.end == b.next`) and joins its token back; `reset` requires the join of all of them. A reused or forged token fails rules 3 and 4 |
| completeness | `alloc` refuses only a request that does not fit with the padding it needs (`refused`) |
| a failed second request undoes the first | `pair` frees the first block, and proves the allocator is as it was |

### Soundness cases

`tests/zvc/tokens.zig`, verdicts in `tokens.expect`. Everything not listed as a control must stay unproved.

| Case | Verdict | Why |
| --- | --- | --- |
| `take`, `give`, `roundTrip`, `leak`, `twoMints`, `giveBoth2` | proved | controls (a leak is zv-own's to report; `twoMints` names two premises) |
| `forgeLiteral`, `forgeField`, `forgeAgain` | UNPROVEN | a token built or changed outside `zv.PointsTo` |
| `forgeViaChecked` | UNPROVEN | the token came from a `.checked` function |
| `giveTwice`, `copyThenGive`, `readAfterGive`, `returnConsumed`, `giveBoth`, `splitTwice` | REFUTED | a token used after it was consumed (twice in one call, through a copy, in a spec, in a result) |
| `maybeGive` | REFUTED | consumed on one path of a join, counterexample `c = true` |
| `takeStuck`, `takeKeepsOld` | REFUTED | overlapping blocks: the region does not advance; the old region is returned with a token that was cut |
| `takeOutside` | REFUTED | the cut is past the capacity (precondition of `split`) |
| `takeMisaligned` | REFUTED | the postcondition claims an alignment the code did not produce |
| `joinGap` | REFUTED | tokens that do not meet |
| `loopConsume` | UNPROVEN | a loop consumes a token it did not build |

Found by these cases while building: the dead set of a path was a slice that pointed into a stack temporary, and `takeKeepsOld` was `proved` until that was fixed (a regression pin now). Unrelated to tokens but needed by the allocator, and fixed in passing: a function that returns a call's result or a parameter, whole (`return carve(...)`, `.bump = b`), promised nothing about the fields it did not set explicitly; `agrees` now equates the result with the fields that were read from it. No pinned verdict of the earlier suites changed, the checked-in packs are byte-identical when exported again, and zmoltcp still proves its 7 functions.

## What `zv-own` must check (a later round)

`src/own` is not touched in M1. `zvc` enforces linearity on the functions it verifies, which is what its proofs need. It does not cover a token in a function that is only `.checked`: the shell `Arena` moves tokens into and out of fields, and nothing but the runtime tests sees a mistake there. What `zv-own` has to add, in the order of cost:

1. Recognise `zv.PointsTo` the way it recognises `zv.Linear`: a value of that type, or a struct, optional or error union holding one, is consumed or handed on exactly once on every path. `holdsLinear` gets the type (its name is `zv.PointsTo__struct` in a pack, as in `value.token_type` of `zvc`). `own` is a source, `split`/`join`/`discard` and a by-value parameter are sinks. This finds a dropped token (a leak that `zvc` proves harmless) and a copy that is used twice in unverified code.
2. A token read out of memory the function does not own (`self.used` through `*Arena`) is today "outside the fragment" for `Linear`. The shell needs it, so the rule becomes: a field of `*Self` holding a token may be replaced (`self.used = self.used.join(x)` consumes the old value and stores a new one), not copied out and kept.
3. Borrowing, `*const PointsTo`: read-only, cannot be consumed, which `zv-own` already has for `*const Linear(T)`. `zvc` would need a pointer-to-struct parameter first (M2).
4. The token as a contract of the type: `zv.PointsTo` is `void` in production, so the check runs on ghost-build packs only. The manifest gate has to say so (`zv.requireOwnership` with a note that ownership of tokens is checked on the ghost export).

Open questions for the integration: (a) do both checkers run on the same ghost pack (`zvc_export.sh` already exports with ghost on) or does `zv-own` need a production pack for the shell? (b) a token inside a container the checker does not follow (`ArrayList(Block)`) is "handed to memory it does not follow"; for tokens that should be an error, not a count. (c) the by-value-parameter-is-a-move rule is the same in both tools, so one table (`src/zvc/value.zig`'s `token_type` and the operation names) should be shared through `zv_air` rather than written twice.

## What stays `.trusted`, and why

| Item | Count | Why it is not proved |
| --- | --- | --- |
| `zv.PointsTo.own` | 1 premise in `bump.init`, named in every verdict that rests on it (`assuming zv.assume at examples/bump.zig:94`) and counted by `--max-assume` | "nothing else uses these bytes" is a fact about the caller; Zig does not check aliasing. Verus has the same boundary, in the creation of a `PPtr` from an allocation. `run_zvc.sh` pins that `--max-assume 0` refuses it |
| the rules of `zvc` above | the trusted base of the token | they are code, pinned by 23 verdicts; a verdict that changes is reviewed as a soundness change |
| offset to slice in `Arena` (`@alignCast(self.region[blk.off..blk.end])`) | 1 shell, `.checked` | the base address alignment is a type (`[]align(64) u8`), the cast is checked in safe builds and by `blocks_hold` on real addresses. `zvc` cannot return a slice yet |
| memory from the system, the `align(64)` of a stack array | outside the code | the trusted edge of the design (FFI, syscalls) |
| Z3 | | as for every proof |

M1 numbers: 7 `.verified` functions (`init`, `padTo`, `carve`, `alloc`, `free`, `reset`, `pair`), 3 `.checked` (`Arena`), 2 laws, 0 `.trusted` functions, 1 premise. The repository's `.trusted` count was 0 and stays 0, so the "falling" half of the exit gate is not measured by M1; the first measurement is the pilot below.

## Limits found building M1

- **Solver time.** 14 s for the file, of which `alloc` 6.5 s and `pair` 7 s. The cost is 64-bit identities of modular arithmetic in the obligations (`next + pad + len <= cap` from two guards). Positions instead of lengths and a helper per bit trick (`padTo`) took it from 46 s to 14 s; `run_zvc.sh` gives this pack `--timeout 60000` (the default is 10 s per obligation). Trying `smt.bv.solver=2` (Z3's integer translation) first made `carve` 100 times faster and crashed Z3 on a query with arrays in the existing suite, so it was not adopted; a portfolio that runs it only on array-free queries is a candidate.
- **No pointer parameters** (`*Self`, `*Arena`): the state goes in and out as a value. M2.
- **A `zv.requires` cannot contain an operation that has an overflow check**, because the check is an obligation that comes first; specs use `-%` and `+%` after a guard (`isPow2`, `refused`).
- **No region identity.** Tokens of two allocators of the same shape are interchangeable to `zvc`; an allocator instance is distinguished only by the values the proof has about it. A cross-allocator `free` is caught only when the offsets disagree. M4 below.
- **`reset` takes every token back.** The shell holds them (`used`), a client holding raw slices does not. A revoke-all `reset` needs an epoch.
- **A dropped token is proved harmless** and reported by nothing until `zv-own` knows the type.
- **Minting twice from one buffer** is two premises, not an error.

## Milestones

| | Scope | Gate |
| --- | --- | --- |
| **M1** (0.17.17) | `PointsTo` over byte ranges, linearity and forging rules in `zvc`, bump allocator proved, soundness cases | this document |
| **M2** | `zvc` takes `*Self` and `*const T` parameters (in/out summaries: the final value of the pointee is a new result variable, bound at the call), so allocators are written as `fn alloc(self: *Bump, ...)`; a fixed-size block pool (free list threaded through the blocks) | `blocks.zig` proved; `Arena` verified rather than checked |
| **M3** | typed `PointsTo(T)` with a value and an initialization flag: `write(perm, ptr, v)` needs the permission and sets the value, `read` needs it initialized; `Tracked(T)` for ghost parameters; frame: a function that does not take a token cannot change its memory | a raw-pointer ring buffer proved with its read/write laws |
| **M4** | region identity and epochs: a token belongs to one allocator instance; `reset` bumps the epoch and revokes outstanding tokens without collecting them | cross-allocator misuse refuted; shell needs no `used` |
| **M5** | `zv-own` knows `PointsTo` (previous section); CI runs both on the ghost pack | tokens in `.checked` code are linear too |
| **M6** | proof agents in CI (below) on the core | the pilot in the next section |

## Proof agents in CI (not built)

"Proof agents" means: when `zvc` fails on a `.verified` function in a pull request, an automated contributor gets one bounded chance to repair the proof, and `zvc` is the only judge. Concretely:

- **Trigger.** A CI job on pull requests runs `tools/run_zvc.sh`-style verification for the changed `.verified` functions (`zvc --only`, the callees they rely on are proved too). On REFUTED or UNPROVEN it starts the agent job with: the diff, the `zvc` output (the obligation, the source line, the counterexample), the pack of the failing function, and the repository checkout.
- **What it may change.** Proof material: `zv.invariant` and `zv.decreases` of loops, `inline fn` helpers and `zv.assume`-free lemma functions, the order and structure of a function (the `padTo` and `carve` splits of M1 are exactly this kind of edit), a stronger intermediate `ensures` on a private helper. **What it may not:** the `requires`/`ensures` of any function that is `pub` or listed in a `LAWS` namespace, the manifest levels, `.expect` files, the ceilings (`--max-trusted`, `--max-assume`), the AIR packs, `zvc` itself and the CI configuration. CODEOWNERS guards those paths, so a patch that touches them cannot be merged without a person.
- **Judge and ratchets.** The agent's patch is a commit on the pull request branch. CI re-exports the pack from the patched sources and runs the whole `zvc` suite; the patch is accepted only if every pinned verdict is unchanged, the new function is proved, and the counts of `.trusted` functions and `zv.assume` premises are not higher. A contract that changed is detected by comparing the contracts of the changed functions with the base (`zvc --survey` already lists them), and is held for a person.
- **Budget and record.** A fixed number of attempts and wall-clock time per function; every attempt, its `zvc` output and the solver seconds are kept as a CI artifact. The numbers to watch are the fraction of failures repaired, the rounds needed, and the solver time of the repaired proof (a proof that passes in 9.8 s of a 10 s timeout is not accepted).
- **Isolation.** The agent runs where it can write only the allowed paths, run `zvc` and Z3, and reach the model API; it cannot see secrets or push to protected branches.
- **First experiment (the AutoVerus question for Zig).** Take `examples/bump.zig`, remove the helper split of `alloc` (inline `padTo` and `carve`) and measure whether an agent, given only the `zvc` output, recovers a proof under the 10 s timeout, and how many rounds it needs. The M1 history in this document is the human baseline: three restructurings.

## A pilot, to measure the second half of the gate

Laminae's allocator and page-table code is the Verus showcase domain and the first non-toy user (design.md). The measurement of "the `.trusted` count is falling" starts there: count the `.trusted` entries in its manifests before the port, and after each milestone. M1 gives them a bump allocator whose spec they can read, and a rule (a token must not be forged or reused) that `zvc` enforces on code they write.
