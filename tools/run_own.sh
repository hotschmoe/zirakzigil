#!/bin/sh
# The zv-own suite: every pinned AIR pack in tests/own against its pinned verdicts. No solver needed.
# The packs are exports of the sources listed in tests/own/SOURCES; editing a source without exporting it
# again (tools/own_repin.sh) fails here, because the verdicts would be about the old program.
# Every suite runs twice against the same verdicts: on the packs of the project alone, where std's containers
# come from the documented model in src/own/spec.zig, and on tests/own/std, where the packs hold the bodies of the
# std functions the project reaches (ZV_AIR_STD) and the effects are derived from them.
set -eu
cd "$(dirname "$0")/.."

zig build zv-own
own="zig-out/bin/zv-own --pins tests/own/SOURCES --module zv=src"

for dir in tests/own tests/own/std; do
    $own --module target=tests/own --expect tests/own/linear.expect $dir/linear.zvp
    $own --module target=tests/own --expect tests/own/memory.expect $dir/memory.zvp
    $own --module target=tests/own --expect tests/own/registry.expect $dir/registry.zvp
    $own --module target=tests/own --expect tests/own/trusted.expect --max-trusted 1 $dir/trusted.zvp
    $own --module target=tests/own --expect tests/own/pinned.expect $dir/pinned.zvp
    $own --module target=tests/should_panic --expect tests/own/pin_copy.expect $dir/pin_copy.zvp
    $own --module target=tests/own --files realish.zig --expect tests/own/realish.expect $dir/realish.zvp
    $own --module target=tests/own --module realish=tests/own --files realish_bugs.zig --expect tests/own/realish_bugs.expect $dir/realish_bugs.zvp
    $own --module target=tests/should_panic --module ledger=examples --expect tests/own/double_consume.expect $dir/double_consume.zvp
    $own --module target=tests/own --expect tests/own/review1.expect $dir/review1.zvp
    $own --module target=tests/own --expect tests/own/stdcode.expect $dir/stdcode.zvp
done

# The ratchet: a trusted function is exempt and counted, and the count can be capped.
if $own --module target=tests/own --expect tests/own/trusted.expect --max-trusted 0 tests/own/trusted.zvp >/dev/null; then
    echo "run_own: --max-trusted 0 passed a pack with a trusted function" >&2
    exit 1
fi

# What is assumed is printed, never silent: each of these is clean because the footer counts it.
counted() { # PACK FUNCTION PATTERN
    if ! $own --module target=tests/own --only "$2" "$1" | grep -q "$3"; then
        echo "run_own: $2 in $1 does not count: $3" >&2
        exit 1
    fi
}
for dir in tests/own tests/own/std; do
    counted $dir/review1.zvp badLinearInList "1 linear values handed to memory it does not follow"
    counted $dir/stdcode.zvp okResizeInPlace "1 resizes by a length it cannot show to be non-zero"
done
