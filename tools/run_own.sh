#!/bin/sh
# The zv-own suite: every pinned AIR pack in tests/own against its pinned verdicts. No solver needed.
# The packs are exports of the sources listed in tests/own/SOURCES; editing a source without exporting it
# again (tools/own_repin.sh) fails here, because the verdicts would be about the old program.
set -eu
cd "$(dirname "$0")/.."

zig build zv-own
own="zig-out/bin/zv-own --pins tests/own/SOURCES"

$own --module target=tests/own --expect tests/own/linear.expect tests/own/linear.zvp
$own --module target=tests/should_panic --module ledger=examples --expect tests/own/double_consume.expect tests/own/double_consume.zvp
