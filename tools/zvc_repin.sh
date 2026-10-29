#!/bin/sh
# Exports the AIR packs of the zvc suite again and pins the sources they come from (needs zig-zv, see
# tools/zvc_export.sh). Run it after editing a source listed in tests/zvc/SOURCES.
set -eu
cd "$(dirname "$0")/.."

for file in examples/search.zig tests/zvc/cases.zig tests/zvc/features.zig tests/zvc/soundness.zig; do
    sh tools/zvc_export.sh tests/zvc "$file"
done
sha256sum examples/search.zig tests/zvc/cases.zig tests/zvc/features.zig tests/zvc/soundness.zig >tests/zvc/SOURCES
