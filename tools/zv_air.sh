#!/bin/sh
# Exports AIR packs for a whole `zig build` project.
#   tools/zv_air.sh INDEX_DIR [zig build args...]      run from the project root (default step: install)
# Runs zig-zv with ZV_AIR_OUT=INDEX_DIR (ZV_AIR_STD=1 in the environment also exports std, ZV_AIR_JSON=1
# writes JSON instead of packs). Compiler runs spawned by the build inherit the variable, so no
# build.zig changes are needed. Each compile step leaves one small index entry in INDEX_DIR; the packs
# stay in the Zig cache and are read in place (`zv-air stats INDEX_DIR`). INDEX_DIR is emptied of
# entries first, so it names exactly this run's packs; cached compile steps write theirs again.
# Libraries built by a different compiler (compiler_rt from the LLVM-enabled stock zig) do not link with
# the no-LLVM zig-zv, so it gets its own global cache (ZV_GLOBAL_CACHE, default compiler/.work/global-cache).
set -eu

[ $# -ge 1 ] || { echo "usage: $0 INDEX_DIR [zig build args...]" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })
zv=${ZIG_ZV:-}
if [ -z "$zv" ]; then
    zv=$root/compiler/.work/zig-src/zig-out/bin/zig-zv
    [ -f "$zv.exe" ] && zv=$zv.exe
fi

mkdir -p "$1"
out=$(cd "$1" && { pwd -W 2>/dev/null || pwd; })
shift
rm -f "$out"/*.zvi "$out"/*.json
ZIG_GLOBAL_CACHE_DIR=${ZV_GLOBAL_CACHE:-$root/compiler/.work/global-cache} ZV_AIR_OUT=$out "$zv" build "$@"
echo "zv_air: $(ls "$out" | grep -c '\.zvi$') packs named in $out"
