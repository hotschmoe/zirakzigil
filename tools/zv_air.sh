#!/bin/sh
# Exports AIR JSON for a whole `zig build` project.
#   tools/zv_air.sh OUT_DIR [zig build args...]      run from the project root (default step: install)
# Runs zig-zv with ZV_AIR_OUT=OUT_DIR (ZV_AIR_STD=1 in the environment also exports std). Compiler runs
# spawned by the build inherit the variable, so no build.zig changes are needed. The build gets a fresh
# cache under OUT_DIR/.cache, because a cached compile step would skip the export. Libraries built by
# a different compiler (compiler_rt from the LLVM-enabled stock zig) do not link with the no-LLVM zig-zv,
# so it also gets its own global cache (ZV_GLOBAL_CACHE, default compiler/.work/global-cache).
set -eu

[ $# -ge 1 ] || { echo "usage: $0 OUT_DIR [zig build args...]" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })
zv=${ZIG_ZV:-}
if [ -z "$zv" ]; then
    zv=$root/compiler/.work/zig-src/zig-out/bin/zig-zv
    [ -f "$zv.exe" ] && zv=$zv.exe
fi

mkdir -p "$1"
out=$(cd "$1" && { pwd -W 2>/dev/null || pwd; })
shift
rm -rf "$out/.cache"
ZIG_GLOBAL_CACHE_DIR=${ZV_GLOBAL_CACHE:-$root/compiler/.work/global-cache} ZV_AIR_OUT=$out "$zv" build --cache-dir "$out/.cache" "$@"
