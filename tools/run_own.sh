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
    $own --module target=tests/own --expect tests/own/switchloop.expect $dir/switchloop.zvp
    $own --module target=tests/own --expect tests/own/tokens.expect $dir/tokens.zvp
    for suite in review2 review2b real fp_zls fp_zls2 fp_zls3 fp_zls4 fp_zls5 fp_zls6 fp_zls7 fp_idioms fp_loops fp_tags fp_tags2 review3 review3b review4; do
        $own --module target=tests/own --expect tests/own/$suite.expect $dir/$suite.zvp
    done
done

# Packs together: a function has the verdict of its own pack, and a function exported into two packs is one function.
pins=tests/own/SOURCES
cat tests/own/review2.expect tests/own/real.expect tests/own/switchloop.expect >"${TMPDIR:-/tmp}/own-together.expect"
$own --module target=tests/own --expect "${TMPDIR:-/tmp}/own-together.expect" tests/own/review2.zvp tests/own/std/review2.zvp tests/own/real.zvp tests/own/std/real.zvp tests/own/switchloop.zvp
$own --module target=tests/own --expect "${TMPDIR:-/tmp}/own-together.expect" tests/own/std/switchloop.zvp tests/own/std/real.zvp tests/own/std/review2.zvp tests/own/switchloop.zvp tests/own/review2.zvp tests/own/real.zvp
rm -f "${TMPDIR:-/tmp}/own-together.expect"

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
    counted $dir/review2b.zvp freeBoth "1 functions that end or change memory through two or more pointer parameters"
    counted $dir/review2.zvp badPqSift "1 pointers stale only if a container had no room"
    counted $dir/review2.zvp badPqPopMoves "1 pointers stale only if a container had no room"
done
for dir in tests/own tests/own/std; do
    counted $dir/real.zvp lostWidgetChild "[1-9][0-9]* pointers to locals handed to calls"
done
counted tests/own/std/real.zvp savedScannerAdvances "[1-9][0-9]* uses of a pointer that may lead into freed memory"

# Review 3: the frees of elements, a conditional free of a by-value parameter, a site that allocates again and a growth after a
# reserve of an unread size are not decided; each of these programs is a bug that Debug faults on, and the footer says so.
for dir in tests/own tests/own/std; do
    for c in review3.badVarIndex review3.badConstIndex review3.badKeepFirst review3.badPrevBuf review3.badOwnOrFree review3b.badSavedElem review3b.badGrowPast; do
        counted $dir/${c%%.*}.zvp "${c#*.}" "[1-9][0-9]* ends that may not have happened to the block"
    done
done

# Review 4: bugs whose tag the run cannot read (an unreadable write, an unknown mode, a pointer called, a by-value free on some
# paths, the loop site) stay undecided, and the footer of the function says so.
for dir in tests/own tests/own/std; do
    for c in badMemsetKind badFnPtr badSoftParam badOwnOrFree badKeepFirst; do
        counted $dir/review4.zvp "review4.$c" "[1-9][0-9]* ends that may not have happened to the block"
    done
done
