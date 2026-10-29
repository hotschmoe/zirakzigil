#!/bin/sh
# Exports the AIR packs of the zv-own suite again and pins the sources they come from (needs zig-zv, see
# tools/zvc_export.sh). Run it after editing a source listed in tests/own/SOURCES.
set -eu
cd "$(dirname "$0")/.."

# Each source twice: the project alone (tests/own), and with the std functions it reaches (tests/own/std).
for out in tests/own tests/own/std; do
    if [ "$out" = tests/own ]; then std=; else std=1; fi
    export ZV_AIR_STD=$std
    sh tools/zvc_export.sh $out tests/own/linear.zig
    sh tools/zvc_export.sh $out tests/own/memory.zig
    sh tools/zvc_export.sh $out tests/own/registry.zig
    sh tools/zvc_export.sh $out tests/own/trusted.zig
    sh tools/zvc_export.sh $out tests/own/pinned.zig
    sh tools/zvc_export.sh $out tests/should_panic/pin_copy.zig
    sh tools/zvc_export.sh $out tests/own/review1.zig
    sh tools/zvc_export.sh $out tests/own/stdcode.zig
    sh tools/zvc_export.sh $out tests/own/review2.zig
    sh tools/zvc_export.sh $out tests/own/review2b.zig
    sh tools/zvc_export.sh $out tests/own/real.zig
    sh tools/zvc_export.sh $out tests/own/switchloop.zig
    for f in fp_zls fp_zls2 fp_zls3 fp_zls4 fp_zls5 fp_zls6 fp_zls7 fp_idioms fp_loops fp_tags review3 review3b; do
        ZVC_DEEP=1 sh tools/zvc_export.sh $out tests/own/$f.zig
    done
    ZVC_DEEP=1 sh tools/zvc_export.sh $out tests/own/realish.zig
    ZVC_DEEP=1 sh tools/zvc_export.sh $out tests/own/realish_bugs.zig --dep realish=tests/own/realish.zig
    sh tools/zvc_export.sh $out tests/should_panic/double_consume.zig --dep ledger=examples/ledger.zig
done
unset ZV_AIR_STD
sh tools/zvc_export.sh tests/consumer/own tests/consumer/own/handoff.zig
sha256sum tests/own/linear.zig tests/own/memory.zig tests/own/registry.zig tests/own/trusted.zig tests/own/pinned.zig tests/should_panic/pin_copy.zig tests/own/realish.zig tests/own/realish_bugs.zig tests/should_panic/double_consume.zig examples/ledger.zig tests/own/review1.zig tests/own/stdcode.zig tests/own/review2.zig tests/own/review2b.zig tests/own/real.zig tests/own/switchloop.zig tests/own/fp_zls.zig tests/own/fp_zls2.zig tests/own/fp_zls3.zig tests/own/fp_zls4.zig tests/own/fp_zls5.zig tests/own/fp_zls6.zig tests/own/fp_zls7.zig tests/own/fp_idioms.zig tests/own/fp_loops.zig tests/own/fp_tags.zig tests/own/review3.zig tests/own/review3b.zig >tests/own/SOURCES
(cd tests/consumer && sha256sum own/handoff.zig >own/SOURCES)
