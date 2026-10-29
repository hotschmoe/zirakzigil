#!/bin/sh
# hazard_build.sh ZV_EXE [KEY=VAL...]: zig build project, same caches, differing ZV_AIR_* env
ZV=$1; shift
for kv in "$@"; do export "$kv"; done
P=/c/Users/hotschmoe/zr/a-work/proj; T=/c/Users/hotschmoe/zr/a-work/hzb
rm -rf $T $P/.zig-cache; mkdir -p $T
n() { ls $1 2>/dev/null | wc -l; }
bld() { out=$1; shift; (cd $P && env ZIG_GLOBAL_CACHE_DIR=$T/global ZV_AIR_OUT=$out "$@" "$ZV" build --cache-dir $T/local --global-cache-dir $T/global >$T/log.txt 2>&1 || echo "  build failed: $(head -3 $T/log.txt)"); }
bld $T/A;                  echo "first build -> A: $(n $T/A) files"
bld $T/B;                  echo "same caches, out dir B: $(n $T/B) files"
rm -rf $T/A; bld $T/A;     echo "same caches, out dir A deleted and reused: $(n $T/A) files"
bld $T/C ZV_AIR_STD=1;     echo "same caches, ZV_AIR_STD=1 -> C: $(n $T/C) files"
bld $T/D ZV_AIR_STD=1;     echo "STD=1 again, new dir D: $(n $T/D) files"
