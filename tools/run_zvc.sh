#!/bin/sh
# The zvc suite: every pinned AIR pack in tests/zvc against its pinned verdicts. Needs Z3 (ZV_Z3 or PATH).
# The packs are exports of the sources listed in tests/zvc/SOURCES; editing a source without exporting it
# again (tools/zvc_repin.sh) fails here, because the verdicts would be about the old program.
set -eu
cd "$(dirname "$0")/.."

zig build zvc
zvc="zig-out/bin/zvc --pins tests/zvc/SOURCES"

$zvc --src examples --expect tests/zvc/search.expect tests/zvc/search.zvp
$zvc --src tests/zvc --expect tests/zvc/cases.expect tests/zvc/cases.zvp
$zvc --src tests/zvc --expect tests/zvc/features.expect tests/zvc/features.zvp
