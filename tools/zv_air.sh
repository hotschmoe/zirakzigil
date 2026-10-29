#!/bin/sh
# Exports AIR JSON for a whole `zig build` project.
#   tools/zv_air.sh OUT_DIR [zig build args...]      run from the project root (default step: install)
# Runs zig-zv with ZV_AIR_OUT=OUT_DIR (ZV_AIR_STD=1 in the environment also exports std). Compiler runs
# spawned by the build inherit the variable, so no build.zig changes are needed. OUT_DIR is cleared of
# *.json first, so it holds exactly this run's export; cached compile steps restore their files into it.
# Libraries built by a different compiler (compiler_rt from the LLVM-enabled stock zig) do not link with
# the no-LLVM zig-zv, so it gets its own global cache (ZV_GLOBAL_CACHE, default compiler/.work/global-cache).
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
rm -f "$out"/*.json
ZIG_GLOBAL_CACHE_DIR=${ZV_GLOBAL_CACHE:-$root/compiler/.work/global-cache} ZV_AIR_OUT=$out "$zv" build "$@"
echo "zv_air: $(ls "$out" | grep -c '\.json$') function files in $out"
