#!/bin/sh
# The zv-own suite: every pinned AIR pack in tests/own against its pinned verdicts. No solver needed.
# The packs are exports of the sources listed in tests/own/SOURCES; editing a source without exporting it
# again (tools/own_repin.sh) fails here, because the verdicts would be about the old program.
set -eu
cd "$(dirname "$0")/.."

zig build zv-own
own="zig-out/bin/zv-own --pins tests/own/SOURCES --module zv=src"

$own --module target=tests/own --expect tests/own/linear.expect tests/own/linear.zvp
$own --module target=tests/own --expect tests/own/memory.expect tests/own/memory.zvp
$own --module target=tests/own --expect tests/own/registry.expect tests/own/registry.zvp
$own --module target=tests/own --expect tests/own/trusted.expect --max-trusted 1 tests/own/trusted.zvp
$own --module target=tests/own --files realish.zig --expect tests/own/realish.expect tests/own/realish.zvp
$own --module target=tests/own --module realish=tests/own --files realish_bugs.zig --expect tests/own/realish_bugs.expect tests/own/realish_bugs.zvp
$own --module target=tests/should_panic --module ledger=examples --expect tests/own/double_consume.expect tests/own/double_consume.zvp

# The ratchet: a trusted function is exempt and counted, and the count can be capped.
if $own --module target=tests/own --expect tests/own/trusted.expect --max-trusted 0 tests/own/trusted.zvp >/dev/null; then
    echo "run_own: --max-trusted 0 passed a pack with a trusted function" >&2
    exit 1
fi
