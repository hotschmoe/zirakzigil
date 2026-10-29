#!/bin/sh
# run.sh VER TARGET OUT: exports TARGET (corpus, search or zmoltcp) with the zig-zv built for VER.
# Writes OUT/v1 (hand-written adapter), OUT/raw (reflection dump) and OUT/txt (compiler printer).
set -eu
ver=$1
target=$2
out=$3
root=$(cd "$(dirname "$0")/../.." && pwd -W 2>/dev/null || pwd)
zv=${ZV_BIN:-/c/Users/hotschmoe/zr/b-work/$ver/zig-out/bin/zig-zv-$ver.exe}
mkdir -p "$out"
out=$(cd "$out" && pwd -W 2>/dev/null || pwd)
rm -rf "$out/v1" "$out/raw" "$out/txt" "$out/.cache"
export ZV_AIR_OUT=$out/v1 ZV_AIR_RAW=$out/raw ZV_AIR_TEXT=$out/txt
export ZIG_GLOBAL_CACHE_DIR=${ZV_GLOBAL_CACHE:-/c/Users/hotschmoe/zr/b-work/global-cache-$ver}
cd "$root"
case $target in
    corpus) "$zv" test -fno-emit-bin --cache-dir "$out/.cache" research/corpus/corpus.zig ;;
    search) "$zv" test -fno-emit-bin --cache-dir "$out/.cache" --dep target -Mroot=tools/air_all.zig --dep zv -Mtarget=examples/search.zig --dep zv_options -Mzv=src/zv.zig -Mzv_options=research/track-b/zv_options.zig ;;
    zmoltcp) zvo=$root/research/track-b/zv_options.zig; zvs=$root/src/zv.zig; cd /c/Users/hotschmoe/Documents/GitHub/zmoltcp && "$zv" test -fno-emit-bin --cache-dir "$out/.cache" --dep zv -Mroot=src/root.zig --dep zv_options -Mzv="$zvs" -Mzv_options="$zvo" ;;
esac
