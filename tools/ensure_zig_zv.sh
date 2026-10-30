#!/bin/sh
# Builds zig-zv from source unless WORK already holds the build for this patch queue, and prints its path.
#   tools/ensure_zig_zv.sh WORK
# The fallback of `zig build verify` when no prebuilt zig-zv is pinned for the host (or -Dzv-from-source is set).
set -eu
cd "$(dirname "$0")/.."

[ $# -eq 1 ] || { echo "usage: $0 WORK" >&2; exit 2; }
work=$1/$(sh tools/queue_hash.sh)
bin=$work/zig-src/zig-out/bin/zig-zv
if [ ! -f "$bin" ] && [ ! -f "$bin.exe" ]; then
    echo "zv: no prebuilt zig-zv is pinned for this release and host, or -Dzv-from-source is set: building zig-zv from source into $work" >&2
    echo "zv: about 8 minutes and 9 GB of memory, once per patch queue; needs git and sh" >&2
    ZV_WORK=$work sh tools/build_zig_zv.sh >&2
fi
[ -f "$bin.exe" ] && bin=$bin.exe
echo "$bin"
