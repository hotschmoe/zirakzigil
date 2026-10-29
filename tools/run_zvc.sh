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
$zvc --src tests/zvc --expect tests/zvc/soundness.expect tests/zvc/soundness.zvp

# A proof is only as good as the callees it relies on, whatever --only selects.
$zvc --src tests/zvc --only soundness.useInc --expect tests/zvc/soundness.only.expect tests/zvc/soundness.zvp

# A trusted callee is an assumption: named in the verdict, and counted against the ratchet.
trusted="$zvc --src tests/zvc --only soundness.useBadAdd --expect tests/zvc/soundness.trusted.expect tests/zvc/soundness.zvp"
$trusted --max-trusted 1
if $trusted --max-trusted 0; then
    echo "run_zvc: --max-trusted 0 passed a proof that assumes a trusted function" >&2
    exit 1
fi

# A signed value is shown signed.
shown=$($zvc --src tests/zvc --only soundness.cmpSign tests/zvc/soundness.zvp || true)
case $shown in
    *"x = -1;"*) ;;
    *)
        echo "run_zvc: counterexample of soundness.cmpSign does not show x = -1" >&2
        exit 1
        ;;
esac
