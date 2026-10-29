#!/bin/sh
# Exports the AIR packs of the zv-own suite again and pins the sources they come from (needs zig-zv, see
# tools/zvc_export.sh). Run it after editing a source listed in tests/own/SOURCES.
set -eu
cd "$(dirname "$0")/.."

sh tools/zvc_export.sh tests/own tests/own/linear.zig
sh tools/zvc_export.sh tests/own tests/should_panic/double_consume.zig --dep ledger=examples/ledger.zig
sh tools/zvc_export.sh tests/consumer/own tests/consumer/own/handoff.zig
sha256sum tests/own/linear.zig tests/should_panic/double_consume.zig examples/ledger.zig >tests/own/SOURCES
(cd tests/consumer && sha256sum own/handoff.zig >own/SOURCES)
