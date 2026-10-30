> **Archived (2026-10-30).** This is the write-up of the fork-flexibility research (tracks A to E, 2026-10-28). The experiment code lived on branches that were removed when the repository was consolidated onto `master`; each is kept as a tag: `archive/research-fork-flex`, `archive/research-track-a` ... `archive/research-track-e` (`git checkout archive/research-track-e`). Paths below that are not in this directory refer to those tags. Outcome: zirakzigil pins one Zig release and ports per release (docs/design.md, "Fork policy"); track E (a generated adapter) was parked.

# Research: a fork that survives Zig releases

Question: what is the cheapest way to keep `zig-zv` (the AIR exporter, docs/phase1.md) working across Zig releases before 1.0? The fallback is fine and known: lock to a release, then spend the time to re-anchor and re-port when the next release drops. We are looking for something that needs close to zero changes per release, and we want every dead end written down with evidence.

## The benchmark: replay 0.16.0 -> 0.17.0

Every track is measured on the same historical upgrade:

1. **Build it for 0.16.0 first**, as if 0.16.0 were the pin. Host compiler: `C:\Users\hotschmoe\zr\host-0.16\zig.exe` (checksum-verified). Upstream tree: `C:\Users\hotschmoe\Documents\GitHub\zig-0.16`, read-only, so make your own copy. It must export `research/corpus/corpus.zig` (version-neutral; passes `zig test` on both 0.16.0 and 0.17.0).
2. **Upgrade to 0.17.0.** Host is `zig` on PATH. Upstream tree: `C:\Users\hotschmoe\Documents\GitHub\zig-0.17`, also read-only. Record the upgrade cost exactly, using the metrics below.
3. **Live port: 0.17.0 -> 0.18.0-dev.738+ae9a8acc7**, today's nightly. This is the upgrade we will actually face next, with no known answer. Host: `C:\Users\hotschmoe\zr\host-0.18-dev\zig.exe` (checksum-verified). Upstream tree: `C:\Users\hotschmoe\zr\zig-0.18-dev`, a full checkout at ae9a8acc7 with longpaths on; read-only, so make your own copy. Record the same metrics as for path 1.
4. **Canary.** `gh workflow run canary.yml --ref <your-branch>` builds the same nightly commit on Linux CI, which confirms the Linux side.

There are two upgrade paths: the historical replay (0.16 -> 0.17) and the live port (0.17 -> 0.18-dev). Report both in every RESULTS.md. A mechanism that only looks good in hindsight doesn't count.

The 0.17.0 output must be usable by the existing consumers: either schema v1 byte-identical to today's exporter on `research/corpus/corpus.zig`, `examples/search.zig` and zmoltcp, or a documented, versioned replacement.

## Metrics, recorded in `research/<track>/RESULTS.md`

| Metric | Meaning |
| --- | --- |
| hook lines | lines added or changed in upstream files, per version |
| port diff | lines changed in our files to go 0.16 -> 0.17, split into hook mechanism, in-compiler adapter, out-of-compiler layer |
| rebuilds | compiler rebuilds needed during the port (each about 8 minutes) |
| failure quality | when something broke, was it loud and local (file:line plus a reason) or silent or misplaced? |
| silent-drift risk | can an upstream change produce wrong output without any error? How would we notice? |
| coverage | instructions exported, and how many are `unsupported`, per version |
| wall time | for the port |

## Shared rules

- **Compiler builds**, about 9 GB RAM each, go through `sh /c/Users/hotschmoe/zr/buildlock.sh <cmd...>`, which allows at most 2 at once on this 32 GB machine.
- **Long paths:** put working trees under `C:\Users\hotschmoe\zr\<track>\` and use `git -c core.longpaths=true` (Windows long paths).
- **Repo:** work in your track's worktree and branch only. Commit often. Do not push to master. Pushing your own branch is fine, and needed for the canary.
- **Style:** ultra-idiomatic Zig, minimal comments, no emojis. Don't delete files you didn't create. No `git reset --hard` or `git clean` outside your own working trees.
- **Commit messages** end with:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01S7e2sBdYQMxGuvKvssBGTE`
- **Dead ends are results.** Record each one with the evidence (error text, upstream commit, file:line).

## Tracks

| Track | Idea | Agent |
| --- | --- | --- |
| A | Hook mechanism: rule-based or AST-anchored insertion instead of a diff, plus the smallest possible hook | Sonnet 5.5 |
| B | Adapter: comptime-reflection raw dump in the compiler, plus an out-of-compiler normalizer keyed on `zig_version` | Sonnet 5.5 |
| C | Landscape: zero-fork and low-fork routes (what replaced `verbose_air`, compiler-as-library, LLVM IR, C backend, ZIR, upstream proposals) | Grok 4.7 |

The tracks are independent, because A changes how we hook in and B changes what we export. The likely outcome is a combination. A synthesis and an adversarial review follow.
