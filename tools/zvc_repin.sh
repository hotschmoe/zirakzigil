#!/bin/sh
# Exports the AIR packs of the zvc suite again and pins the sources they come from (needs zig-zv, see
# tools/zvc_export.sh). Run it after editing a source listed in tests/zvc/SOURCES.
set -eu
cd "$(dirname "$0")/.."

for file in examples/search.zig tests/zvc/cases.zig tests/zvc/features.zig tests/zvc/soundness.zig tests/zvc/soundness2.zig tests/zvc/soundness3.zig tests/zvc/tokens.zig tests/zvc/pointers.zig examples/bump.zig; do
    case $file in
        examples/bump.zig) sh tools/zvc_export.sh tests/zvc "$file" --only Bump ;;
        tests/zvc/pointers.zig) sh tools/zvc_export.sh tests/zvc "$file" --only R ;;
        *) sh tools/zvc_export.sh tests/zvc "$file" ;;
    esac
done
sh tools/zvc_export.sh tests/zvc/dup tests/zvc/dup/soundness2.zig
sha256sum examples/search.zig tests/zvc/cases.zig tests/zvc/features.zig tests/zvc/soundness.zig tests/zvc/soundness2.zig tests/zvc/soundness3.zig tests/zvc/tokens.zig tests/zvc/pointers.zig examples/bump.zig >tests/zvc/SOURCES
