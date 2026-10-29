# Phase 0 report: the gate, measured on zmoltcp

Phase 0's exit gate is "every module has a manifest at floor `.tested` or higher". Until now that was a table people filled in: `.tested` was whatever the author wrote. This report is the first time the claim is measured. Pilot: zmoltcp 0.5.0 (Zig 0.17.0, Windows and Linux).

## What `.tested` means now

A function classified `.tested` (or `.checked`, `.verified`) must be **executed by a law or a scenario**. A law is a `pub fn` in a laws namespace run by `zv.checkLaws`; a scenario is an end-to-end test outside the library source (zmoltcp's `examples/`). Unit tests are not evidence. `.trusted` is exempt and counted.

The measurement is dynamic and generated, so it cannot be edited into place:

1. `src/gate/instrument.zig` copies the library source into the build cache, planting `zv.cover.hit(id)` at the top of every function body and **deleting every `test` block** except in the files named as law roots. Source that mentions the hit function is rejected.
2. The law roots (inside the source) and scenario roots (outside it) are built against the copy and run. Their stdout carries the first hit of each function; stderr stays free, so a failing law fails the build in its own words.
3. `zv.report` walks the manifest from the library root (nothing to forget to list), joins each claim to its function by qualified name and fails the build on a claim with no hit, or naming no function.

Why it cannot be gamed: a contributor cannot call the probe (the tool refuses the text, and the ids are assigned per build); cannot move a function out of the walk (the walk follows `pub` declarations, which the manifest gate already forces to be classified); cannot count a unit test (they are not in the tree that is run); and cannot lower evidence by editing the repository's expectations, because there is no list of expectations other than the manifest itself. What remains is quality, not presence: a law can run a function and never judge its result. Execution proves reach; mutation spot checks (below) show whether the laws bite.

## Results

zmoltcp before and after, same measurement (the "before" run is the same gate on zmoltcp 0.4.1's laws and demos):

| | classified functions | evidenced | unproven |
| --- | ---: | ---: | ---: |
| before (v0.4.1) | 549 | 364 | 185 |
| after (v0.5.0) | 549 | 549 | 0 |

Per module (`laws / scenarios` columns count functions executed by each suite; a function may be in both):

| module | functions | before: laws / scenarios | before: unproven | after: laws / scenarios | after: unproven |
| --- | ---: | ---: | ---: | ---: | ---: |
| `fragmentation` | 24 | 0 / 0 | 9 | 0 / 22 | 0 |
| `iface` | 61 | 0 / 13 | 27 | 0 / 53 | 0 |
| `phy` | 12 | 0 / 0 | 3 | 0 / 3 | 0 |
| `rpl` | 21 | 0 / 0 | 21 | 0 / 21 | 0 |
| `socket.dhcp` | 18 | 0 / 8 | 6 | 0 / 17 | 0 |
| `socket.dns` | 15 | 0 / 6 | 4 | 0 / 12 | 0 |
| `socket.icmp` | 15 | 0 / 2 | 3 | 0 / 10 | 0 |
| `socket.raw` | 15 | 0 / 0 | 5 | 0 / 15 | 0 |
| `socket.tcp` | 79 | 0 / 33 | 41 | 0 / 76 | 0 |
| `socket.udp` | 16 | 0 / 4 | 5 | 0 / 15 | 0 |
| `stack` | 9 | 0 / 0 | 1 | 0 / 6 | 0 |
| `storage.assembler` | 9 | 0 / 9 | 0 | 0 / 9 | 0 |
| `storage.packet_buffer` | 10 | 0 / 6 | 4 | 0 / 10 | 0 |
| `storage.ring_buffer` | 20 | 0 / 20 | 0 | 0 / 20 | 0 |
| `time` | 32 | 0 / 11 | 17 | 0 / 32 | 0 |
| `wire.arp` | 2 | 0 / 2 | 0 | 0 / 2 | 0 |
| `wire.checksum` | 8 | 0 / 8 | 0 | 0 / 8 | 0 |
| `wire.dhcp` | 7 | 0 / 6 | 1 | 0 / 7 | 0 |
| `wire.dns` | 18 | 0 / 4 | 4 | 0 / 18 | 0 |
| `wire.ethernet` | 4 | 0 / 4 | 0 | 0 / 4 | 0 |
| `wire.icmp` | 4 | 0 / 4 | 0 | 0 / 4 | 0 |
| `wire.icmpv6` | 4 | 0 / 4 | 0 | 0 / 4 | 0 |
| `wire.ieee802154` | 7 | 0 / 5 | 2 | 0 / 7 | 0 |
| `wire.igmp` | 3 | 0 / 2 | 1 | 0 / 3 | 0 |
| `wire.ip` | 5 | 0 / 3 | 2 | 0 / 5 | 0 |
| `wire.ipsec_ah` | 4 | 0 / 2 | 2 | 0 / 4 | 0 |
| `wire.ipsec_esp` | 3 | 0 / 1 | 2 | 0 / 3 | 0 |
| `wire.ipv4` | 11 | 0 / 8 | 3 | 0 / 11 | 0 |
| `wire.ipv6` | 16 | 0 / 6 | 6 | 0 / 16 | 0 |
| `wire.ipv6ext_header` | 4 | 0 / 3 | 1 | 0 / 4 | 0 |
| `wire.ipv6fragment` | 3 | 0 / 2 | 1 | 0 / 3 | 0 |
| `wire.ipv6hbh` | 4 | 0 / 3 | 1 | 0 / 4 | 0 |
| `wire.ipv6option` | 6 | 0 / 4 | 2 | 0 / 6 | 0 |
| `wire.ipv6routing` | 3 | 0 / 3 | 0 | 0 / 3 | 0 |
| `wire.mld` | 6 | 0 / 5 | 1 | 0 / 6 | 0 |
| `wire.ndisc` | 3 | 0 / 3 | 0 | 0 / 3 | 0 |
| `wire.ndiscoption` | 4 | 0 / 4 | 0 | 0 / 4 | 0 |
| `wire.rpl` | 16 | 0 / 9 | 7 | 0 / 16 | 0 |
| `wire.sixlowpan` | 12 | 0 / 5 | 2 | 0 / 7 | 0 |
| `wire.sixlowpan_frag` | 4 | 0 / 3 | 1 | 0 / 4 | 0 |
| `wire.tcp` | 23 | 0 / 22 | 0 | 0 / 22 | 0 |
| `wire.udp` | 9 | 0 / 9 | 0 | 0 / 9 | 0 |

The 185 functions that had only a hand-written `.tested` and no law or scenario behind them were covered by new laws derived from the RFCs and smoltcp's behavior (RFC 791 fragmentation and reassembly, RFC 1122/3927/4291 address classes, RFC 5681 congestion windows, RFC 6550/6206/6552 routing state, RFC 2131 lease timers, RFC 3810 and 4861 host behavior, RFC 4944 fragmentation, RFC 4302/4303 headers, and TCP byte-stream delivery across option sets), not by mirroring the implementation.

## Defects the laws found

Each is fixed in zmoltcp 0.5.0 and pinned as a law instance:

- `time`: `millis()` used `@mod` while `secs()` truncates, so negative instants decomposed inconsistently (`-1.5 s` was `secs=-1, millis=500`). Now `@rem`.
- `TcpRepr.isEmpty` treated a bare PSH segment as non-empty; smoltcp ignores PSH, and the keep-alive decision depends on it.
- `rpl.ObjectiveFunction0.computeRank` overflowed a `u16` multiplication on an advertised `MinHopRankIncrease` above 21845 (a 16-bit field from the network); now saturating.
- `rpl.TrickleTimer` panicked on interval exponents of 64 or more (8-bit wire fields); the exponent is now capped at 40.
- `fragmentation.maxIpv4FragmentPayload` underflowed for an MTU below the IP header, and `Fragmenter.emitNext` emitted empty fragments forever for an MTU of 20 to 27; it now returns null when no data fits.
- `dhcp` request back-off cast the retry count to `u5`: a configured `request_retries` of 64 or more panicked. The doubling is capped.
- `ipsec_ah.emit` panicked on an ICV longer than the length field can describe and silently wrote a non-multiple-of-32-bit header; it now returns `error.BadIcvLen`.

Bugs 3, 4 and 6 are also present in upstream smoltcp (the same arithmetic on the same wire-sized fields); they are written up for the owner, nothing was filed.

## Mutation spot check

Twelve one-line mutants of functions that previously had no evidence (network mask, link-local prefix, instant subtraction, Reno halving, relation expiry, DHCP T2, fragment alignment, MLD group reporting, global unicast prefix, DNS additional count, PSH emptiness, UDP receive) were applied one at a time and `zig build assurance` run: 11 failed in a law or scenario, and the twelfth (`len + 0`) is an equivalent mutant.

## Limits

- Evidence is execution of the function body, once. It says nothing about branches inside it.
- Generic functions are matched by name, so `Socket(ipv4)` and `Socket(ipv6)` share a claim; a hit in either counts. Both instantiations are compiled by the laws' own `refAllDecls` test.
- Functions reached only at comptime cannot be hit; a law must call them at run time (`ip.assertIsIp` is called from a law for that reason).
- Claims that come from a dependency (zmoltcp re-exports `zv.Slots` handles) are listed as foreign and gated by the dependency's own build.
- The fuzz targets and the Rust interop harness are not evidence suites yet; adding them is one more root in `addAssuranceGate`.
