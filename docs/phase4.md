# Phase 4: permission tokens and a verified core

Phase 4 is the Verus part of the plan: raw-memory code is verified by pairing the memory with a linear ghost token, so the solver never reasons about aliasing, only about small arithmetic goals. M1 (0.17.17) built the token, the rules `zvc` applies to it, and a bump allocator over a fixed byte buffer that `zvc` proves; M2 (0.17.19) makes the allocator a method on `*Bump`, with its token in a field, and has `zv-own` check tokens in code `zvc` does not verify. The exit gate of the phase is "the core is `.verified` and the `.trusted` count is falling"; this document says what M1 reaches of it and what the rest costs.

```
zv.PointsTo                          src/zv.zig       the token, ghost-only (void in production)
src/air/tokens.zig                   the names of the token and its operations, shared by zvc and zv-own
examples/bump.zig                    the allocator    7 methods .verified, a checked shell, 2 laws
examples/pool.zig                    a pool of blocks 4 methods .verified, a checked shell, 2 laws
examples/freelist.zig                an intrusive free list of 8 blocks, 4 methods .verified (quantified invariants)
tests/zvc/lists.zig                  free-list corruption, the quantifier encoding, array stores
tests/zvc/cells.zig                  zv.Cell(T)
tests/zvc/pools.zig                  17 verdicts      BlockSet: reuse, other pools, free-set corruption, forging
tests/zvc/tokens.zig                 23 verdicts      what zvc must refuse about tokens, and their controls
tests/zvc/pointers.zig               *Self cases      what a call may rely on of a pointee, aliasing, tokens in a field
tests/own/tokens.zig                 zv-own cases     dropped, copied, reused tokens in code zvc does not verify
tools/run_zvc.sh, tools/run_own.sh   the suites       tokens.expect, pointers.expect, bump.expect
```

## The token

```zig
pub const PointsTo = if (ghost) struct {
    from: usize,
    to: usize,
    pub inline fn lo(self: Self) usize           // read in specifications; in a build without ghost code it returns 0 and marks the contract unchecked
    pub inline fn own(buf: []const u8) Self      // the one source of tokens: [0, buf.len), a premise
    pub inline fn split(self: Self, cut: usize) Pair   // [lo, cut) and [cut, hi); needs lo <= cut <= hi
    pub inline fn join(head: Self, tail: Self) Self    // needs head.hi() == tail.lo()
    pub inline fn discard(self: Self) void
} else struct { ...the same operations, which do nothing };
```

A token is the right to use the bytes `[lo, hi)` of one region, owned by whoever holds the value. It is ghost the way `zv.Int` is: in a ghost build it is a struct of two words, elsewhere it is `void`, so a field of this type costs nothing (`@sizeOf(Bump)` is 2 words in production and 4 in a ghost build; a test pins it). It has no pointer in it. As in Verus, the address (here an offset into the region) and the permission are separate values, and the allocator manages the offsets: the bytes stay with the caller, who turns an offset into a slice in the shell.

Specifications talk about positions, not lengths. `split` takes the position of the cut, a block has an `end` and not only a `len`, and "these two blocks are disjoint" is `x.end <= y.off`: a chain of comparisons. This was learned the hard way. The first version used lengths (`off + len`), every proof had an identity of 64-bit modular arithmetic in it, and `pair` took 44 s. With positions, `carve` takes 35 ms and the whole file about 14 s.

### Threading

The allocator is a method on `*Bump`, and its token is a field of it. A method takes the token out of the field, cuts it, and puts the rest back before it returns; the head goes to the block it hands out.

```zig
pub const Bump = struct {
    cap: usize,
    next: usize,
    spare: zv.PointsTo,                                  // [next, cap)
    pub fn alloc(self: *Bump, len: usize, alignment: usize) ?Block
    pub fn free(self: *Bump, blk: Block) void           // joins the block's token back into spare
    pub fn reset(self: *Bump, used: zv.PointsTo) void
};
pub const Block = struct { base: usize, off: usize, end: usize, perm: zv.PointsTo };  // perm: [base, end)
```

A block's token covers its alignment padding too (`base` is where the allocator was), so every token ever handed out is a piece of one contiguous tiling of `[0, next)`. That is what makes `reset` and `free` checkable: `reset` takes `used`, the join of every outstanding block (`[0, next)`), which is the proof that nobody holds a block any more; `free` of the last block joins its token back to `spare`, and `join` requires that they meet.

Specifications of a method name the state before and after: `const old = self.*;` at the top, `granted(old, len, alignment, self.*, blk)` in `zv.ensures`. A copy of a struct that holds a token is the same token, so `old.spare` is not usable after `self.spare` was cut, and the specification reads only the plain fields of `old` (`old.next`, `old.cap`).

A token is a type in every build: the real struct under ghost code, a struct with no fields and the same operations otherwise. Code calls `self.spare.split(end)` and assigns `self.spare = parts.tail` with no condition, and specifications read `b.spare.lo()`. Reading a token in a build without ghost code returns zero and marks the running contract unchecked (`zv.holds`), so a contract that talks about tokens is proved by `zvc` and checked in ghost builds only. Ghost values that are not tokens (an array of the blocks on a list) are fields of type `zv.Ghost(T)`.

A specification may not read a token it already passed on, as in Verus: `roundTrip` copies `p.lo()` and `p.hi()` before `split(p)` and compares the result with the copies.

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

### Pointer parameters (M2)

A parameter `p: *T` where `T` is a struct is a cell of its own: the function reads and writes it like a local, and its summary says how a caller may think of it afterwards.

- **Summary.** At entry the pointee is a symbolic struct. At every return, `zvc` equates a placeholder for the pointee after the call (`$out`) with the value the cell has there, field by field (the fields that were written, and the ones that were read), and it records which top-level fields the function may have changed on any path. A loop that stores through the pointer, or a callee whose result is not the pointee it started from, counts as changing all of them.
- **Call.** The argument must be the address of a variable or of a field of one. The callee's entry pointee is bound to what the caller has there; afterwards the fields it may have changed are replaced by the callee's `$out` fields, and every other field is what the caller had, so a callee that sneaks in a write beyond its contract costs the caller exactly that knowledge (`useSneaky`, `useLoopWrites`: refuted). Two pointer arguments to the same variable, or to one and to a field of it, are outside the fragment (`callSame`, `callSameField`); two fields, or two variables, are two places (`callFieldsApart`). The callee is verified on the assumption that its pointer parameters do not alias, as `noalias` says.
- **Tokens in the pointee.** The token in a field the callee may change is the callee's for the call: the caller's copies of it are consumed (`holdAcrossCall` refuted), and the callee must put a live token back in the field before it returns (`dropSpare`, `readSpareTwice` refuted: a token taken out of the struct and consumed is not there for the caller). A field the callee does not touch keeps its token and its identity. `forgeSpare` (a token literal stored through the pointer) is outside the fragment as before.
- **Not in the fragment.** Pointers to anything but a struct (`*u32`), pointer arguments that are not an address of a variable, and the two-pointer overlap above. A `return` of a constant that the compiler folded out of the `zv.ensures` that checked it (`null`) is tied to that `zv.ensures` again: without it `alloc` promised nothing on its refusal path.

Verification of `bump.zig` as methods takes about 16 s, as before (`alloc` 9.4 s, `pair` 6.4 s).

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

## What `zv-own` checks (0.17.19)

`zvc` enforces linearity on the functions it verifies, which is what its proofs need. It does not cover a token in a function that is only `.checked`: the shell `Arena` moves tokens into and out of fields. `zv-own` now treats `zv.PointsTo` as a linear value, with the names shared with `zvc` through `src/air/tokens.zig` (the type, the operations, which of them consume):

- `own` makes a token; `split` and `join` consume their arguments and make new ones; `discard` and passing a token by value to a call consume it. Their bodies are not run. A token that is not consumed or handed on on some path (`badDrop`, `badDropHalf`, `badLeakOnBranch`, `badDropHolder`), consumed twice (`badSplitTwice`, `badCopyBothUsed`, `badJoinReuse`, `advCopyViaStruct`), read after it was consumed (`badUseAfterConsume`: a field of a consumed token), consumed in a loop (`badConsumeInLoop`) or returned after it was consumed (`badReturnAndConsume`) is a finding.
- A token in memory the function does not own (`self.t` through a `*Self`): a read takes it out, a write puts one back. A token taken out and not put back is a finding (`badTakenNotPutBack`: `self.t.discard()`; `badReadTwice`), and the replacement `self.t = self.t.join(more)` is clean (`okReplaceInPlace`, `okReplaceDirect`). This replaces "a linear value read out of memory this function does not own" for a value that is itself a `zv.Linear` or a `zv.PointsTo`; `linear.advViaPointer` was unproven and is now an error (it takes the token out and consumes it with nothing put back).
- Limits, pinned: overwriting a token in the caller's memory without taking it out first looks like an initialization and is counted (`gapOverwriteLive`, "handed to memory it does not follow"); a copy of a whole struct that holds a token read out of memory the function does not own is unproven (`advWholeStructRead`), so the verified methods of `bump.zig`, which spell `sound(self.*)`, are unproven for `zv-own` and proved for `zvc`.

`tests/own/tokens.zig` pins 13 clean verdicts (two are helpers, one is the gap above), 13 findings and 1 unproven, run on both packs by `tools/run_own.sh`; zmoltcp stays at 986 functions, 0 findings.

Open questions: (a) a token inside a container the checker does not follow (`ArrayList(Block)`) is "handed to memory it does not follow"; for tokens that should be an error, not a count. (b) The whole-struct read of the second limit would need a ghost-read notion (a copy that cannot be consumed) shared with `zvc`'s `old = self.*`.

## A pool of blocks (M3, 0.17.21)

A pool hands out any free block and takes any block back, in any order. What its proof needs that the bump allocator's did not: the allocator owns **a collection of permissions** (one per free block) and must give one out and take one back by index. The options, and why the third:

1. **Arrays or a ghost `Seq` of `PointsTo`.** A token per block, kept in a field. `zvc` has no arrays of structs, and a token in an array element is a place a call could read twice; the linearity rules (identity per value, consumption on passing) would need per-element tracking, and "give out the token of block `i`" needs `at(i)` on a sequence of linear values. The proof that the sequence holds no token twice is a quantified statement. Rejected: it needs both a new kind of place and quantifiers.
2. **A typed token `PointsTo(T)`** (the usual Verus answer: one token per cell, with a value). It does not remove the collection: the pool still holds N of them.
3. **A token over a set of blocks**, `zv.BlockSet { id, mask }` (at most 64 blocks): one linear value that stands for every block whose bit is set. `cut(bits)` splits off a subset, `join` puts two back (they must share no block and name one pool), and a block handed out is a `BlockSet` with one bit. The pool keeps the free blocks in one token (`spare`), so no collection exists, and the algebra is bit operations, which the solver is good at: no arithmetic identities, which is what made the bump proofs slow. Picked because it is the smallest thing that is sound: the same five rules of `zvc` (identity, consumption, use after consumption, forging, loops) apply unchanged to a second token type, and there is one new fact, the lemma below.

**The lemma.** Disjointness of two blocks held at once is not an arithmetic fact of the allocator (the bump allocator had `next` for that); it is the statement "two live tokens of one pool share no block". That is Verus' `points_to_disjoint`, here `zv.BlockSet.apart(a, b)`: it returns the two tokens again and `zvc` assumes `a.id != b.id or a.mask & b.mask == 0` of them, after checking that they are two tokens and not the same one twice. It is sound under the premises already counted: a pool's token comes from `own` (one per pool, a premise; `zvc` gives it a fresh `id`), the operations only split and join, and linearity is enforced (a copy of a token cannot be alive next to its original: `dupBlock`, `copyAndHandOut` and `dupResult` are refused). Run in a ghost build, `apart` is a `requires`, so every law of the pool checks the lemma on real executions.

`free` uses it internally: `lemma = apart(self.spare, blk.perm)` and then `join`, which requires the masks to be disjoint and the ids equal. So the caller proves nothing about disjointness; it only needs a block of this pool (`owns`: the id of its token is the pool's), and a block it already gave back has no token. The double free of `giveTwice` is refused at the caller as a token used after it was consumed; a block of another pool (`foreignFree`) fails the id equality; a block with no check at all (`giveUnchecked`) fails it too.

**What is proved** (`examples/pool.zig`, 4 methods, 2.3 s): `alloc` returns the lowest free block `idx < count` with `off == idx << 6`, in bounds (`off + 64 <= cap`), aligned to the block size; `free_bits` loses exactly that bit; the pool stays well formed (`free_bits` is a subset of the blocks that exist, and equals the mask of the ghost token); an empty pool is refused unchanged. `free` joins the token back and sets exactly that bit, and the bit was clear before (the block was out). `pair` allocates twice: the two blocks are different, 64 bytes apart or more, aligned and in bounds, and if the second does not exist the first is freed and the pool is as it was. The shell `Heap` turns blocks into `*align(64) [64]u8` and keeps the permissions in `held`; `blocks_hold` runs it against real addresses and bytes, `pair_holds` runs `pair`.

**What is not the intrusive free list the task named.** The free blocks are a bitmap, not a chain through the blocks. A chain needs two things `zvc` does not have: stores into array elements or into the bytes of a block (a slice's memory is a term of the solver whose update would have to reach every other slice of it, and the pointee model of M2 covers structs only), and an invariant over the whole chain (every link in range and no block twice), which is quantified; the bitmap states it as `free_bits == spare.mask`, a single equation. The route to the chain is the typed token (M4) for the stores, and a ghost predicate over arrays with a quantifier in the solver for the invariant; neither is built.

**Soundness cases** (`tests/zvc/pools.zig`, 17 verdicts). Controls proved: `take`, `give`, `pairDistinct` (two takes give different blocks), `roundTrip` (`cut` then `join`), `twoMints`. Refused: `giveTwice` (token reuse), `foreignFree` and `giveUnchecked` (a block of another pool, a block nobody checked), `dupBlock` and `copyAndHandOut` (a token returned next to the one in the struct), `takeNoClear` (the free set says free, the token is gone), `takeFromEmpty` (a take from an empty pool), `giveWrongBit` (the wrong bit marked free), `apartSame` (the lemma on one token twice), `forgeSet`, `forgeMask` (a token written out or changed). A real gap found by writing these: a function could hand a live token out twice (`return .{ .a = p, .b = p }`); `zvc` now obliges everything a function gives back (its result and the pointees of its pointer parameters) to hold no token twice (`tokens.dupResult`, pinned).

Two smaller changes of `zvc` that the pool needed: a null optional is a constant whatever its payload (a `return null` that follows no `zv.ensures` made the function promise nothing), and a shift by an amount of type `std.math.Log2Int` is not obliged to be small (the type says it).

**What `zv-own` needs** (`src/own` was not touched this round). It does not know `zv.BlockSet`: a block's token is an ordinary struct to it, so a dropped or doubly-given block in `.checked` code is not reported. To do: (a) `isLinear` also for `zv.BlockSet__struct`; `src/air/tokens.zig` already has the name, the operations (`SetOp`) and `setConsumes`. (b) `tokenOp` for the set operations, where `cut` and `apart` consume their arguments and make two new tokens and `own` makes one; `opOf` returns null for them today on purpose, so the checker runs their bodies and sees no token. (c) The two rules for tokens in `*Self` (take out, put back) apply as they are. (d) `Heap.alloc` and `Heap.free` of `examples/pool.zig` are the first `.checked` code that moves a `BlockSet` through a `*Self`, and should be the seeded cases (`held` joined, taken, a double free, a forgotten `join`).

## Quantified invariants, array stores and a typed cell (M4, 0.17.25)

The M3 pool kept its free set in a bitmap because a chain through the blocks needs three things `zvc` did not have. M4 adds them, and the intrusive free list is proved (`examples/freelist.zig`).

### Quantifiers without a quantifier

The overseer's advice was to stay quantifier-free; the decision was to go deep. The encoding picked is the one that stays predictable: **a bounded `forall` is a conjunction written out at comptime**.

```zig
pub inline fn forall(comptime bound: usize, n: usize, ctx: anytype, comptime pred: fn (@TypeOf(ctx), usize) bool) bool {
    if (n > bound) return false;
    inline for (0..bound) |i| if (i < n and !@call(.always_inline, pred, .{ ctx, i })) return false;
    return true;
}
```

`zvc` sees `bound` guarded instances of `pred` as ordinary straight-line AIR. Nothing about it is special to the verifier and nothing reaches Z3 as a `forall`:

- **No triggers to get wrong.** There is no E-matching, so a badly chosen trigger cannot make a proof pass or hang; the worst case of a big `bound` is a big query, and a query that takes too long is a timeout. Timeouts are never proofs: a function whose obligation times out is UNPROVEN (or REFUTED when another obligation has a counterexample), and `run_zvc.sh` pins that a 1 ms solver timeout on `FreeList.alloc` does not print `proved`.
- **Sound by construction.** The conjunction is what `forall` means for `n <= bound`; for `n > bound` it is `false` (instances would be missing), so a proof has to show the count is within the bound (`lists.forallShort`, with a bound of 4 over a pool of 8, is refuted).
- **The price** is that a quantified fact is as big as its range. The pool has 8 blocks and three quantified invariants of 8 instances each; `alloc` takes 4 s and `free` 4.5 s. A `slots` of 64 would not be practical this way. A real `forall` with a trigger would scale with the instances used instead of the range; it is not built, and it is the place where a wrong trigger could matter, which is why it was left out of the soundness argument.

A loop invariant can quantify the same way (`zv.invariant(zv.forall(...))`); the pool needs none, because every method is straight-line.

### Arrays and stores

`zvc` models an array in a struct (or a local) as an SMT array; an element is a place of its own (`ptr_elem_ptr` of a pointer to an array gives a place with an index), so `self.links[i] = v`, a ghost `self.order[n] = i` and `self.links[i]` in a specification are all in the fragment, and `*Self` summaries carry the array across a call (`agrees` equates two arrays, a call binds the callee's array to the caller's). Details that mattered:

- A change below a field the function never set starts from what the field was (`update` materialises the symbolic field); without it a store into `self.order` replaced the whole array by a fresh one, and an invariant over it failed.
- `undefined` for an array of integers is a fresh array.
- Two pointers into one array may point at the same element (`overlap` treats two index steps as overlapping).
- Not done: slices as places (a store into a `[]u8` would have to reach every other slice of the same memory) and arrays of structs. This is why the link words are an array of the pool and not the first bytes of the blocks: **the list is intrusive in the sense that the link of a block is stored for that block and is meaningful only while the block is free, but the words are `links[i]` of the pool, not bytes of the block.** Moving them into the bytes is a layout change that needs byte stores through the block's permission.

### The free list

`FreeList` has 8 blocks. Real state: `head`, `links[8]`, `nfree`, `used`. Ghost state: `spare`, a `BlockSet` for the free blocks, and `order` (the blocks on the list, the head last) with its inverse `posn`. The invariant, each line unrolled over the blocks:

| | |
| --- | --- |
| list length | `nfree <= 8`, `nfree + used == 8`, `popcount(spare.mask) == nfree`, `spare.mask >> 8 == 0` |
| head | `head == nil` when empty, else `order[nfree - 1]` |
| nodes | for `k < nfree`: `order[k] < 8`, block `order[k]` is in `spare`, `posn[order[k]] == k` |
| coverage | for every block `i` in `spare`: `posn[i] < nfree` and `order[posn[i]] == i` |
| links | for `k < nfree`: `links[order[k]] == order[k - 1]`, and `nil` for `k == 0` |

Acyclic follows from the links going strictly down `order`; every node is in bounds and free; no block is on the list twice because `posn` is an inverse; and `used = 8 - nfree` is the live count. `alloc` pops the head (`self.links[head]` is the new head) and cuts its bit from `spare`; `free` takes a block with its permission, proves with `apart` that it is not on the list, writes its link, and pushes it. `init` builds the list by freeing the eight blocks in turn. `reuse` (alloc then free) leaves `nfree` as it was. A double free is the token of the second `free` having been consumed by the first: refused at the caller.

Times (Windows, Z3 4.16.0): `alloc` 4.0 s, `free` 4.6 s, `init` 0.8 s, `reuse` 8.9 s; 19 s for the file, run with `--timeout 120000`. `popcount` and the three unrolled quantifiers are the cost; the bitmap pool takes 2.3 s.

### The typed token, `zv.Cell(T)`

`Cell(T) { slot, value }` is the permission for one cell with the value it holds, ghost like the others. `write(c, v)` consumes the token and returns the one for the cell after the store; `own(slot, v)` is a counted premise. A struct that keeps a real field and a cell token states `cell.value == field` as its invariant (`cells.zig`: `set`, `get`, `swap` are proved; `setNoWrite` is refuted because the cell still says the old value). It is typed in `T` but the pack prints one name for every instantiation (`zv.Cell__struct`), so a pack can hold one `T` per cell type; `zvc` reads the field types from the pack and a second `T` would be a conflict (unknown fields).

Cases: a cell written after it was given away (`writeAfterGive`), a token written twice (`writeTwice`), the old value read after the write (`readStale`), a token kept in two places (`dupCell`), a cell stolen from another struct (`stealCell`), forged (`forgeCell`) and changed (`forgeValue`).

### Axioms, in one list

Everything `zvc` takes without proving about tokens is here. Each is a premise a verdict names or an intrinsic whose pinned cases are listed.

| Axiom | What it says | Where counted |
| --- | --- | --- |
| `PointsTo.own`, `BlockSet.own`, `Cell.own` | the memory (or pool, or cell) is exclusively the caller's | one premise per call site, `assuming zv.assume at file:line`, `--max-assume` |
| `BlockSet.apart` | two live tokens of one pool share no block (`zvc` assumes it of two distinct tokens) | an intrinsic of `zvc`; `pools.apartSame` pins the only misuse it checks; a pool's `own` gives a fresh name, so tokens of two pools are never claimed disjoint |
| linearity rules | identity, consumption, no use after consumption, no forging, distinct results, loops | `src/zvc/vc.zig`; `tokens.expect` (34 verdicts) enumerates how a token can flow (optional, two fields, stored twice, error union, pointee and result, array, loop) |

No other fact about a token is assumed. The overseer's concern that the rules were found by cases rather than derived is answered in part: the flow cases of `tokens.zig` found no new gap this time, but the rules are still an enumeration, not a theorem; `distinctTokens` came from a case, and a proof that the enumeration is complete is not written.

### What did not work, or is not there

- **The hash map** (stretch) is not done. It needs a map as a ghost type or a quantifier over a slot array with a hash function, and open-addressing probing needs a loop invariant that quantifies over the probe sequence; the pieces (array stores, unrolled quantifiers, loop invariants) exist, the proof was not attempted.
- **Link words in the block bytes**, as above.
- **An obligation in a `zv.requires` argument** still stops a function from verifying ("`zv.requires` must open the function body"). The workaround is in the code: an array index by a `u3` truncation (`at`), and a comparison of a zero-extended narrow number with a constant is folded to true so the compiler's own bounds check on it is not an obligation.
- **Solver time grows with the unrolled range**; 8 blocks is what is practical.
- **`zv-own` does not know `Cell(T)`** or the block-set operations; `src/own` was not touched (a parallel refactor owns it). What it needs is in the M3 section; add `Cell`: `own`, `write` and `discard` as a source, a consuming transformer and a sink, with the same rule for a cell in a field of `*Self`.

## What stays `.trusted`, and why

| Item | Count | Why it is not proved |
| --- | --- | --- |
| `zv.PointsTo.own` | 1 premise in `Bump.init`, named in every verdict that rests on it (`assuming zv.assume at examples/bump.zig:96`) and counted by `--max-assume` | "nothing else uses these bytes" is a fact about the caller; Zig does not check aliasing. Verus has the same boundary, in the creation of a `PPtr` from an allocation. `run_zvc.sh` pins that `--max-assume 0` refuses it |
| the rules of `zvc` above | the trusted base of the token | they are code, pinned by 23 verdicts; a verdict that changes is reviewed as a soundness change |
| offset to slice in `Arena` (`@alignCast(self.region[blk.off..blk.end])`) | 1 shell, `.checked` | the base address alignment is a type (`[]align(64) u8`), the cast is checked in safe builds and by `blocks_hold` on real addresses. `zvc` cannot return a slice yet |
| memory from the system, the `align(64)` of a stack array | outside the code | the trusted edge of the design (FFI, syscalls) |
| Z3 | | as for every proof |

M3 adds `Pool` (4 `.verified` methods, 1 premise `BlockSet.own`, 0 `.trusted`).

M2 numbers: 7 `.verified` methods of `Bump` (`init`, `padTo`, `carve`, `alloc`, `free`, `reset`, `pair`), 3 `.checked` (`Arena`), 2 laws, 0 `.trusted` functions, 1 premise. The repository's `.trusted` count was 0 and stays 0, so the "falling" half of the exit gate is not measured by M1; the first measurement is the pilot below.

## Limits found building M1 and M2

- **Solver time.** 16 s for the file, of which `alloc` 9.4 s and `pair` 6.4 s. The cost is 64-bit identities of modular arithmetic in the obligations (`next + pad + len <= cap` from two guards). Positions instead of lengths and a helper per bit trick (`padTo`) took it from 46 s to 14 s; `run_zvc.sh` gives this pack `--timeout 60000` (the default is 10 s per obligation). Trying `smt.bv.solver=2` (Z3's integer translation) first made `carve` 100 times faster and crashed Z3 on a query with arrays in the existing suite, so it was not adopted; a portfolio that runs it only on array-free queries is a candidate.
- **Pointer parameters are structs only**, and a callee is verified on the assumption that its pointers do not alias; `*u32`, `*[N]T` and pointers to pointers are outside the fragment.
- **A `zv.requires` cannot contain an operation that has an overflow check**, because the check is an obligation that comes first; specs use `-%` and `+%` after a guard (`isPow2`, `refused`).
- **No region identity.** Tokens of two allocators of the same shape are interchangeable to `zvc`; an allocator instance is distinguished only by the values the proof has about it. A cross-allocator `free` is caught only when the offsets disagree. M4 below.
- **`reset` takes every token back.** The shell holds them (`used`), a client holding raw slices does not. A revoke-all `reset` needs an epoch.
- **A dropped token is proved harmless** by `zvc`; `zv-own` reports it.
- **Minting twice from one buffer** is two premises, not an error.

## Milestones

| | Scope | Gate |
| --- | --- | --- |
| **M1** (0.17.17) | `PointsTo` over byte ranges, linearity and forging rules in `zvc`, bump allocator proved, soundness cases | this document |
| **M2** (0.17.19) | `zvc` takes `*Self` and `*const T` parameters (in/out summaries), the allocator is a set of methods on `*Bump` with its token in a field, `zv-own` checks tokens (shared names, tokens through `*Self`) | done |
| **M3** (0.17.21) | `zv.BlockSet` (a token over a set of the blocks of a pool), the lemma `apart`, a pool of fixed-size blocks proved, 17 soundness verdicts | done, with a bitmap for the free set (above) |
| **M4** (0.17.25) | bounded `zv.forall` (unrolled), element places and stores in arrays, `zv.Cell(T)`, an intrusive free list proved | done, see above; the hash map is not |
| **M4b** | typed `PointsTo(T)` with an initialization flag, `Tracked(T)`, a ring buffer proved with its read/write laws | |
| **M5** | region identity and epochs: a token belongs to one allocator instance; `reset` bumps the epoch and revokes outstanding tokens without collecting them | cross-allocator misuse refuted; shell needs no `used` |
| **M5b** | typed offset regions: `zv.Offset(T)` resolved against a region base, carrying the region's generation; growth, prune and reset end the generation, so a stale offset or a `*T` derived from one is a finding instead of `@ptrFromInt` UNPROVEN (the page/pin bug class of ghostty, `ext/REPORT-ghostty.md`: #1, #14, #23, #25, #13997); handle registries that are remapped on mutation (tracked pins) as a first-class obligation | a stale-cell-pointer-after-grow reduction of ghostty #13960 is a finding in `zv-own` and refuted in `zvc` |
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
