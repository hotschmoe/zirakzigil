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
$zvc --src tests/zvc --expect tests/zvc/soundness2.expect tests/zvc/soundness2.zvp
$zvc --src tests/zvc --expect tests/zvc/soundness3.expect tests/zvc/soundness3.zvp

# --only names whole dotted components: packBit does not select packBit2.
$zvc --src tests/zvc --only soundness3.packBit --expect tests/zvc/soundness3.only.expect tests/zvc/soundness3.zvp
$zvc --src tests/zvc --only packBit --expect tests/zvc/soundness3.only.expect tests/zvc/soundness3.zvp

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

# A zv.assume is a premise: named in the verdict, passed on to its callers, counted against the ratchet.
assumed="$zvc --src tests/zvc --only soundness2.useAssume --expect tests/zvc/soundness2.assume.expect tests/zvc/soundness2.zvp"
$assumed --max-assume 1
if $assumed --max-assume 0; then
    echo "run_zvc: --max-assume 0 passed a proof that rests on a zv.assume" >&2
    exit 1
fi
shown=$($assumed)
case $shown in
    *"assuming zv.assume at"*) ;;
    *)
        echo "run_zvc: the verdict of soundness2.useAssume does not name its zv.assume" >&2
        exit 1
        ;;
esac

# Over the ceiling the verdict itself is not accepted, as with --max-trusted.
for gate in "$assumed --max-assume 0" "$trusted --max-trusted 0"; do
    shown=$($gate || true)
    case $shown in
        *"UNPROVEN"*"exceed"*) ;;
        *)
            echo "run_zvc: a proof over its ceiling is still reported proved: $gate" >&2
            exit 1
            ;;
    esac
done

# Two different functions under one name cannot be told apart by a call: not proved, not first-wins.
$zvc --src tests/zvc --only soundness2.useLenBound --expect tests/zvc/soundness2.dup.expect tests/zvc/soundness2.zvp tests/zvc/dup/soundness2.zvp
