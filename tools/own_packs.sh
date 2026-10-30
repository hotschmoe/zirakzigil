#!/bin/sh
# Exports the AIR packs of the zv-own suite from the sources in the tree (needs zig-zv, see
# tools/zvc_export.sh). The packs are build products and not committed: tools/run_own.sh reads what this writes.
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
    sh tools/zvc_export.sh $out tests/own/tokens.zig
    for f in fp_zls fp_zls2 fp_zls3 fp_zls4 fp_zls5 fp_zls6 fp_zls7 fp_idioms fp_loops fp_tags fp_tags2 review3 review3b review4 overseer overseer2 oracle1; do
        ZVC_DEEP=1 sh tools/zvc_export.sh $out tests/own/$f.zig
    done
    ZVC_DEEP=1 sh tools/zvc_export.sh $out tests/own/realish.zig
    ZVC_DEEP=1 sh tools/zvc_export.sh $out tests/own/realish_bugs.zig --dep realish=tests/own/realish.zig
    sh tools/zvc_export.sh $out tests/should_panic/double_consume.zig --dep ledger=examples/ledger.zig
done
unset ZV_AIR_STD
