#!/bin/sh
# Exports the AIR packs of the zvc suite from the sources in the tree (needs zig-zv, see tools/zvc_export.sh).
# The packs are build products and not committed: tools/run_zvc.sh reads what this writes.
set -eu
cd "$(dirname "$0")/.."

for file in examples/search.zig tests/zvc/cases.zig tests/zvc/features.zig tests/zvc/soundness.zig tests/zvc/soundness2.zig tests/zvc/soundness3.zig tests/zvc/tokens.zig tests/zvc/pointers.zig tests/zvc/pools.zig tests/zvc/lists.zig tests/zvc/cells.zig examples/bump.zig examples/pool.zig examples/freelist.zig; do
    case $file in
        examples/bump.zig) sh tools/zvc_export.sh tests/zvc "$file" --only Bump ;;
        tests/zvc/pointers.zig) sh tools/zvc_export.sh tests/zvc "$file" --only R ;;
        examples/pool.zig) sh tools/zvc_export.sh tests/zvc "$file" --only Pool ;;
        tests/zvc/pools.zig) sh tools/zvc_export.sh tests/zvc "$file" --only P ;;
        examples/freelist.zig) sh tools/zvc_export.sh tests/zvc "$file" --only FreeList ;;
        tests/zvc/lists.zig) sh tools/zvc_export.sh tests/zvc "$file" --only L ;;
        tests/zvc/cells.zig) sh tools/zvc_export.sh tests/zvc "$file" --only Box ;;
        *) sh tools/zvc_export.sh tests/zvc "$file" ;;
    esac
done
sh tools/zvc_export.sh tests/zvc/dup tests/zvc/dup/soundness2.zig
