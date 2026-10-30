#!/bin/sh
# The patch-queue hash: twelve hex digits over everything zig-zv is built from. It names the prebuilt zig-zv assets
# of a release and the from-source build directory; CI keys its zig-zv cache on the same files.
set -eu
cd "$(dirname "$0")/.."

{
    find compiler/src compiler/hook -type f
    printf '%s\n' compiler/ZIG_VERSION tools/build_zig_zv.sh tools/zv_hook.zig src/air/schema.zig src/air/builder.zig src/air/json.zig src/air/names.zig
} | LC_ALL=C sort | while read -r file; do
    printf '%s ' "$file"
    tr -d '\r' <"$file" | sha256sum | cut -d' ' -f1
done | sha256sum | cut -c1-12
