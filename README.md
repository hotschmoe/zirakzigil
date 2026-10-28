# Zirakzigil

**A formalization layer for multi-contributor Zig.** Contracts, refinement types, ownership backstops and an SMT verifier, stacked on top of the stock Zig compiler with no fork and no new syntax.

> *Zirakzigil* is the dwarven name for the Silvertine. Durin's Endless Stair climbs from the deepest level of Moria to the tower on its summit. This project is a stair of that kind, a stack of layers where each one checks what the layer below cannot.

## Why

Rust's borrow checker helps large teams mostly because it makes code **modular**: a signature carries enough machine-checked facts about ownership and aliasing that a reviewer can approve a diff by reading the diff and the signatures it touches.

Zig makes the *mechanics* explicit (allocators, control flow, error handling). It does not make the *invariants* explicit. Who frees this slice? Is this pointer still valid after `append`? Is it legal to copy this struct? In Zig those answers usually live in the original author's head.

Zirakzigil moves them into signatures and contracts that a machine checks at every call site.

## The stack

| Layer | What it catches | Status |
| --- | --- | --- |
| **A. Contracts** `zv.requires` / `ensures` / `invariant` | Broken pre/postconditions, blamed on the side that broke them | Built |
| **B. Refinement and brand types** `zv.Ranged`, `zv.Pool(..., struct {})` | Overflow in ranged arithmetic, out-of-range literals, cross-pool handle mixups, narrowing | Built |
| **C. Runtime ownership backstops** `zv.Linear`, generational handles, `zv.PinCheck` | Double consume, use-after-free via stale handle, copied self-referential structs, leaks | Built |
| **D. Static ownership checker** `zv-own` (over AIR) | The bugs in C, at compile time, plus region escapes and pointer invalidation | Designed |
| **E. Deductive verifier** `zvc` (Verus-style, Z3) | Functional correctness and absence of every safety panic | Spike, on a source subset |
| **H. Governance** assurance manifest + laws | Silent erosion of guarantees by contributors | Built |

Every module declares how much assurance each public function carries, and the compiler enforces it:

```zig
pub const assurance = .{ .midpoint = .verified, .scale = .checked };
comptime { zv.requireAssurance(@This(), .checked); } // missing entry or downgrade = compile error

pub fn midpoint(lo: u32, hi: u32) u32 {
    zv.requires(lo <= hi);
    const mid = lo + (hi - lo) / 2;
    return zv.ensures(mid, lo <= mid and mid <= hi);
}
```

The same function is compiled normally, checked at runtime in safe builds (contracts vanish in `ReleaseFast`), and proved statically by `zvc`. The naive `(lo + hi) / 2` passes every small unit test; `zvc` rejects it with the counterexample `lo=1, hi=4294967295`.

The full rationale, the survey of prior art (Verus, Bend 2, SPARK, CN, Kani) and the roadmap are in [`docs/design.md`](docs/design.md).

## Layout

| Path | What it is |
| --- | --- |
| `src/zv.zig` | The library: contracts, `Ranged` integers, branded generational `Pool`, `Linear(T)`, `PinCheck`, assurance gate, executable laws |
| `examples/search.zig` | Functions with contracts. Two contain planted bugs (`midpointNaive`, `withdrawNaive`) |
| `examples/ledger.zig` | Accounts in a branded pool, money as linear tokens, laws checked as properties |
| `tests/should_panic/` | Contributor mistakes that must panic in safe builds |
| `tests/compile_fail/cases.txt` | Contributor mistakes that must be rejected at compile time |
| `tools/zvc.py` | Static verifier spike: proves `.verified` functions with Z3 |
| `tools/run_negative.sh` | Runs the should-panic and compile-fail suites |
| `docs/design.md` | Design document |

## Running it

Requires Zig 0.16.0, and Python 3 with `z3-solver` for the verifier.

```sh
zig build test                          # contracts, laws (20k property checks), ownership tests
zig build test -Doptimize=ReleaseFast   # contracts compile out
zig build test -Dghost=true             # ghost (verification-only) code compiled in
./tools/run_negative.sh                 # 4 must-panic + 6 must-not-compile cases
pip install z3-solver
python3 tools/zvc.py examples/search.zig   # expect 4 verified, 2 rejected, exit code 1
```

## Results

| Check | Result |
| --- | --- |
| `zig build test` | 9/9 in Debug, ReleaseSafe, ReleaseFast, and with `-Dghost=true` |
| Must panic: double consume, stale handle, pinned copy, violated precondition | 4/4 |
| Must not compile: mixed brands, missing manifest entry, below floor, out-of-range literal, oversize index, narrowing | 6/6 |
| `zvc examples/search.zig` | 34 obligations, 6 functions, ~1 s: 4 verified, 2 planted bugs rejected |

### What `zvc` understands today

Integer and bool parameters, `[]const T` slices, `const`/`var`, assignment and `+= -= *=`, `if`/`else`, `while` with a leading `zv.invariant`, `return` with `zv.ensures`, `+ - * / %`, comparisons, `and`/`or`/`!`, `xs[i]`, `xs.len`, `@as` widening. Anything else is reported **UNPROVEN**, never silently accepted. Termination is not checked and calls are not yet modular.

## Limits, honestly

- `zvc` parses a source subset, not Zig's AIR. Generics, comptime-dependent code, calls, structs and pointers are out of scope for now.
- Ownership is enforced only at runtime. The static checker `zv-own` is designed but not built.
- The `Linear` ledger is a fixed 16K-slot global with no thread safety. It is fine for tests, not for production.

## Roadmap

Phase 0 (adopt layers A to C and H on a real codebase) needs nothing beyond this repo. Phase 1, a small compiler patch that exports versioned AIR, is the decision that commits the project to maintaining a pinned fork. Later phases build `zv-own` and move `zvc` onto AIR. See [`docs/design.md`](docs/design.md#roadmap-and-experiments).

## License

Public domain, via [The Unlicense](LICENSE). Do whatever you want with it.
