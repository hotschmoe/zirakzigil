#!/bin/sh
# run.sh ZV_BIN TARGET OUT: exports TARGET (corpus, search or zmoltcp) with a zig-zv binary into OUT/v1.
set -eu
zv=$1
target=$2
out=$3
root=$(cd "$(dirname "$0")/../.." && pwd -W 2>/dev/null || pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd -W 2>/dev/null || pwd)
rm -rf "$out/v1" "$out/.cache"
export ZV_AIR_OUT=$out/v1
export ZIG_GLOBAL_CACHE_DIR=${ZV_GLOBAL_CACHE:-$out/.global-cache}
cd "$root"
case $target in
    corpus) "$zv" test -fno-emit-bin --cache-dir "$out/.cache" research/corpus/corpus.zig ;;
    search) "$zv" test -fno-emit-bin --cache-dir "$out/.cache" --dep target -Mroot=tools/air_all.zig --dep zv -Mtarget=examples/search.zig --dep zv_options -Mzv=src/zv.zig -Mzv_options=research/track-e/zv_options.zig ;;
    zmoltcp) zvo=$root/research/track-e/zv_options.zig; zvs=$root/src/zv.zig; cd ${ZM_DIR:-/c/Users/hotschmoe/Documents/GitHub/zmoltcp} && "$zv" test -fno-emit-bin --cache-dir "$out/.cache" --dep zv -Mroot=src/root.zig --dep zv_options -Mzv="$zvs" -Mzv_options="$zvo" ;;
esac
