#!/bin/sh
# The pack-based gates from the sources in the tree, in one command: builds zig-zv if there is none (once per
# checkout; rerun tools/build_zig_zv.sh after changing compiler/), exports every pack, runs the zvc and zv-own suites.
# Needs Z3 (ZV_Z3 or PATH). ZIG_ZV and ZIG_LIB select another compiler, as for tools/zvc_export.sh.
set -eu
cd "$(dirname "$0")/.."

bin=compiler/.work/zig-src/zig-out/bin/zig-zv
if [ -z "${ZIG_ZV:-}" ] && [ ! -f "$bin" ] && [ ! -f "$bin.exe" ]; then
    sh tools/build_zig_zv.sh
fi
sh tools/zvc_packs.sh
sh tools/own_packs.sh
sh tools/run_zvc.sh
sh tools/run_own.sh
