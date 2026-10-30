# The differential oracle, first run (0.17.25)

Four adversarial reviews each found new silent false negatives: `zv-own` said `clean` and the footer said everything was decided, while the program crashed in Debug. Hand-written cases find them one class at a time. `tools/oracle` is the generated version of that review: a seeded generator of small allocator-heavy programs, a Debug ground truth, the same programs through `zv-own`, a classification, an automatic minimizer for the silent misses, and a report with a rate per construct. The overseer's recommendation 2 (OVERSEER.md, Q2) is this tool. `tools/oracle/run.sh` runs it at a fixed seed and budget; `.github/workflows/oracle.yml` runs it nightly with a new seed and uploads the report.

## What was measured

6000 programs, seed 1 (`tools/oracle/run.sh --seed 1 --count 6000 --batch 200 --minimize 20`), Windows, Zig 0.17.0 and the patched compiler of the pin, `plain` (std's containers from the table) and `std` (`ZV_AIR_STD=1`) packs. 3275 programs fault in Debug and 2725 do not. The complete reports are next to this file: [before](oracle-1/before.md) is `zv-own` at e7f91a1 (0.17.21, the master this branch started from), [after](oracle-1/after.md) is master at 0.17.24 (PR #28, the choke point and the `COUNTED` verdict, 0.17.22). The same programs, the same ground truth; only `zv-own` differs.

| | silent miss, `plain` | silent miss, `std` | counted miss, `plain` | counted miss, `std` | true finding | false positive |
|---|---:|---:|---:|---:|---:|---:|
| before (0.17.21) | 637 (19.5% of 3275) | 273 (8.3%) | 427 | 791 | 2211 | 128 (4.7% of 2725) |
| after (0.17.24) | 118 (3.6%) | 120 (3.7%) | 946 | 944 | 2211 | 128 (4.7%) |

Reading: #28 turned silent misses into counted ones and found nothing new: the 2211 true findings and the 128 false positives did not change. That is exactly what the PR claims (a missed end is now counted), and it is the first time the claim is measured on programs nobody wrote after reading the rules. Still faulting and called plainly `clean`: 3.6 percent. A counted miss is not a finding: a program that crashes and is called `COUNTED` is only a program the checker declined to decide, and 944 of 3275 faulting programs are in that state.

The rates per motif, programs of exactly one motif (the clean attribution; the other tables of the reports count a program for every construct it contains):

| motif | programs | faulting | silent `plain` before | after | silent `std` before | after | counted `plain` before | after |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| buf (alloc, dupe, print, alias, subslice, defer, helper free) | 116 | 65 | 6 | 6 | 6 | 6 | 0 | 0 |
| realloc | 106 | 44 | 0 | 0 | 0 | 0 | 0 | 0 |
| ArrayList view and growth | 90 | 6 | 0 | 0 | 0 | 0 | 0 | 0 |
| ArrayList struct copy | 104 | 49 | 0 | 0 | 0 | 0 | 0 | 0 |
| list of owned elements, loops | 119 | 45 | 45 | 0 | 0 | 0 | 0 | 45 |
| AutoHashMap | 113 | 36 | 27 | 0 | 12 | 0 | 0 | 27 |
| AutoArrayHashMap | 113 | 39 | 17 | 0 | 8 | 0 | 0 | 17 |
| StringHashMap, owned keys | 115 | 43 | 43 | 0 | 0 | 0 | 0 | 43 |
| struct fields, copies, by-value and by-pointer params | 118 | 67 | 0 | 0 | 0 | 0 | 26 | 26 |
| struct holding a list (`Bag`) | 101 | 18 | 0 | 0 | 0 | 0 | 8 | 8 |
| optionals by value and by pointer | 89 | 33 | 7 | 0 | 7 | 0 | 5 | 12 |
| tagged unions | 102 | 20 | 9 | 0 | 9 | 0 | 0 | 9 |
| error unions, errdefer, catch | 97 | 33 | 0 | 0 | 0 | 0 | 0 | 0 |
| helpers (by value, by pointer, aliasing parameters) | 94 | 46 | 3 | 0 | 3 | 0 | 5 | 8 |
| globals | 103 | 50 | 21 | 11 | 21 | 11 | 19 | 29 |
| function pointers | 105 | 29 | 0 | 0 | 0 | 0 | 29 | 29 |
| arenas | 97 | 35 | 0 | 0 | 0 | 0 | 0 | 0 |
| `zv.Linear` | 108 | 53 | 0 | 0 | 0 | 0 | 0 | 0 |
| `zv.Pool` | 99 | 29 | 0 | 0 | 0 | 0 | 0 | 0 |
| `create`/`destroy` node chains | 94 | 47 | 42 | 42 | 42 | 42 | 0 | 0 |

The reviews' own targets are covered: the tag, `deinit`, error-exit and linear/pool motifs have no silent miss in either version. The holes are in the memory the checker does not follow: elements of containers, map values, optionals through a call, globals, and chains of heap nodes.

## The silent misses that remain (minimized by the tool)

The minimizer removes units (statements) and motifs while the program still compiles, still faults and `zv-own` still says `clean` with nothing counted, in the mode where it was silent. The reports list 8 (after) and 25 (before) reproducers; these are the ones that matter now. Each is a whole `pub fn` of the batch file (the prelude helpers `mk`, `mkNode`, `nextOf`, `stash`, `rd*` are in `tools/oracle/prelude.zig`); all are silent in both modes.

1. Heap nodes, use after `destroy` through a call (`m_node`, 97 programs in the run share the signature; 42 of the 47 single-motif node programs that fault are silent):

   ```zig
   const n1 = try mkNode(a, 7, null);
   const n2 = try mkNode(a, 8, n1);
   var cur: ?*Node = n2; while (cur) |c| { a.destroy(c); cur = nextOf(c); }
   ```

   `destroy(c)` then `nextOf(c)`, a call that reads through `c`, is not found. The same list walked the right way round and then `a.destroy(n1)` again (a double free of the node the walk already destroyed) is silent too, as is `a.destroy(n1); _ = rdn(n2.next.?)` (the freed node reached through a field of another). These are `create`/`destroy` objects reached through a pointer stored in another heap object; the identity of `n1` flows into `n2.next` and the loop variable, and no end is attributed to it.

2. A global that holds the block (`m_global`, 36 programs): `stash(v)` stores `v` in a global, `a.free(v)`, then `rd(g_slice)` reads the global. The use of a global after the free of its content is silent (11 of 50 faulting global programs; the other 29 are `COUNTED`). `stash(v); dropStashKeep(a); a.free(v)` (the callee frees the global's block, the caller frees it again) was silent before and is counted now.

3. A subslice freed instead of the block (`m_buf`, 14+4+2 programs): `const w = v[1..]; a.free(w)` is an invalid free (Debug: the allocator is given a pointer that is not the start of an allocation). The checker does not model a free of a non-allocation. This is outside what `docs/phase3.md` claims, but it is a crash and it is silent: 10 of 39 `bug_invalid_free` programs.

Before 0.17.22 the reproducers of the same run were more varied; each of these was silent and is `COUNTED` now (from [before](oracle-1/before.md)):

- elements of owned lists freed twice, freed in the loop and again by the `deinit` walk, `pop` freed and then freed by the loop, partly freed by `if (i % 2 == 0)` and then by the loop (45 of 45 single-motif programs, 0 now);
- hash maps: `getPtr` kept across a `fetchRemove` and read, `get` then free then the iterator frees the values, `get` then the iterator frees then read (27 of 36);
- array hash maps: `get(2)` freed and `values()` freed again (17 of 39);
- string maps with an owned key freed and then freed by the iterator, a key that is a static buffer (43 of 43);
- `dropOpt(a, o); rdOpt(o)` (an optional passed by value to a freeing helper, then read; 7 of 33);
- `dropAnyU` on a union whose `borrowed` arm holds memory that is not a block (9 of 20);
- `freeIf(a, v, c); a.free(v)` (a conditional free in a helper, then an unconditional free: 3 of 46 helper programs).

## False positives

128 programs (4.7 percent of the 2725 that do not fault) get findings and do not fault. 127 contain the view-after-growth steps: a slice or element pointer of an `ArrayList` or of a `Bag` kept across `append`/`add`/`insert`, which the checker reports and which crashes only when the append reallocates. In these programs the append did not reallocate (capacity 8 holds the elements). They are contract violations that Debug did not punish in this run, so they are the checker being right about the contract and the ground truth being a single execution; they are listed as false positives because the claim of the table is "faulted". The 128th is an infeasible path: a `zv.Pool` handle read after `if (selv >= 2) pool.free(h)` in a program that returns early for that `selv`. Neither the generator's `selv` conditions nor the checker's branches know that the bad branch is unreachable.

The report columns are therefore: false positive rate of the program set, not of the checker. The share that is an execution artefact is the 127 above.

## How the ground truth is decided, and its limits

A false ground truth poisons everything, so this is what the label means and what it does not.

- Every program runs against a tracking allocator (`tools/oracle/harness.zig`) on top of `std.heap.DebugAllocator`. A freed block is poisoned with 0xAA and kept: it is never handed out again, so no later allocation can hide a stale pointer. A free of anything that is not the start of a live block, with the right length, is a double free or an invalid free at that call. `resize` and `remap` always refuse, so every growth moves the storage and the old block is poisoned; Allocator's contract allows that, and it makes "stale if the container had no room" deterministic for the cases where the container does grow.
- Every read of heap memory in a generated program goes through `rd`, `rdb`, `rdp`, `rdn` or `nextOf` (`prelude.zig`), which stop at a byte of 0xAA. Live data never holds 0xAA (filled with 1..90, ASCII literals, small integers). Writes after a free are never generated, since a write over the poison would hide it. Memory read after the free of the allocation it lives in is detected the way a poisoned read is; reading memory that was never freed but is out of its owner's lifetime (a pointer into a `zv.Pool` slot after `free`) is not generated, because Debug cannot see it. Everything is read through those helpers, so no unrelated panic can be labelled a fault: a panic whose message does not start with `oracle: ` or `zv.` is dropped from the numbers and counted as invalid (0 of 6000 in this run; a first version emitted `ArrayList.deinit` twice, which is undefined behaviour, and was removed).
- A `zv.Linear` token consumed twice, borrowed after the consume (panics of the ledger, messages starting `zv.`), or never consumed at the end of a run (the ledger is checked after every run) is a fault; so is a stale `zv.Pool` handle.
- Each program runs for `selv` 0..3 (the second parameter, used in branch conditions) and, for each of those, once per allocation with that allocation failing (`std.testing.FailingAllocator`), so error paths and `errdefer` run. A fault in any of the runs makes the program faulting.
- Leaks are not faults (phase3: out of scope). A test run with `DebugAllocator.deinit` would report them and was not used.
- What the ground truth cannot see: a bug whose path none of the 4 values of `selv` and the failure points reach; a use of freed memory that is not through `rd*` (never generated); two failures in one run; behaviour that depends on the data (the programs have none). The silent-miss rate is a rate against this set of executions, and a lower bound for the real thing.
- The programs are not random Zig: they are motifs from a fixed library (`prelude.zig`, `gen.zig`), 20 of them, each with correct and wrong variants, one to three motifs per program, with random sizes, conditions and orderings. That is a generator with its own bias, and the fault rate (55 percent) is chosen. A rate here is a rate over this distribution; it is comparable across versions of `zv-own` at the same seed, and it says nothing about real code (that is the second half of the overseer's recommendation: a held-out project set, which this tool does not replace).
- The generated array of the same seed and count is identical on Windows and on Linux (WSL, Ubuntu 24.04): the first 600 programs gave the same ground truth for each of them on both. The verdicts differed there, because the Linux compiler in WSL was another build of zig-zv.

## What was not done

`zv-own` was not changed. The 8 reproducers are not in the corpus; the right place for them is `tests/own` with an expectation, when the checker is fixed (a pinned `clean` accepts nothing else). The oracle does not gate CI: `zig build oracle` and the nightly workflow report. A gate on the silent-miss rate at a fixed seed (a number that must not rise) is one line in `tools/oracle/run.sh` once the owner of `src/own` decides the number.

## Reproducing

```
ZIG_ZV=compiler/.work/zig-src/zig-out/bin/zig-zv tools/oracle/run.sh --seed 1 --count 6000 --batch 200 --minimize 20 --out oracle-out
zig build oracle -Doracle-seed=1 -Doracle-count=300      # the CI-sized default, report in zig-out/oracle
```

Time on the machine of this run: 6000 programs, both modes, 25 minutes; each minimization 20 to 30 seconds.
