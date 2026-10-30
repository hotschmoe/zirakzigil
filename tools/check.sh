#!/bin/sh
# The pack-based gates from the sources in the tree, in one command: builds zig-zv when there is none or when
# anything it is built from is newer than it, exports every pack, runs the zvc and zv-own suites.
# Needs Z3 (ZV_Z3 or PATH). ZIG_ZV and ZIG_LIB select another compiler, as for tools/zvc_export.sh; it is then not rebuilt.
set -eu
cd "$(dirname "$0")/.."

if [ -z "${ZIG_ZV:-}" ]; then
    bin=compiler/.work/zig-src/zig-out/bin/zig-zv
    [ -f "$bin.exe" ] && bin=$bin.exe
    if [ ! -f "$bin" ] || [ -n "$(find compiler/src compiler/hook compiler/ZIG_VERSION tools/build_zig_zv.sh tools/zv_hook.zig \
        src/air/schema.zig src/air/builder.zig src/air/json.zig src/air/names.zig -type f -newer "$bin")" ]; then
        sh tools/build_zig_zv.sh
    fi
fi
sh tools/zvc_packs.sh
sh tools/own_packs.sh
sh tools/run_zvc.sh
sh tools/run_own.sh
