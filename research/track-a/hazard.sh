#!/bin/sh
# hazard.sh ZV_EXE [extra env KEY=VAL...]: cache-hit-skips-export probes with direct invocations
ZV=$1; shift
for kv in "$@"; do export "$kv"; done
C=/c/Users/hotschmoe/zr/wt-a/research/corpus/corpus.zig
T=/c/Users/hotschmoe/zr/a-work/hz; rm -rf $T; mkdir -p $T/local $T/global
n() { ls $1 2>/dev/null | wc -l; }
run() { # out mode extra
  out=$1; mode=$2; shift 2
  case $mode in noemit) cmd=test; emit=-fno-emit-bin;; obj) cmd="test-obj --test-no-exec"; emit=-femit-bin=$T/o.obj;; esac
  env ZV_AIR_OUT=$out "$@" "$ZV" $cmd $emit --cache-dir $T/local --global-cache-dir $T/global $C >/dev/null 2>$T/err.txt || { echo "  run failed: $(head -2 $T/err.txt)"; }
}
for mode in noemit obj; do
  rm -rf $T/local $T/global $T/A $T/B $T/C $T/D; mkdir -p $T/local $T/global
  run $T/A $mode;                       echo "[$mode] first run -> A: $(n $T/A) files"
  run $T/B $mode;                       echo "[$mode] same cache, other out dir B: $(n $T/B) files"
  rm -rf $T/A
  run $T/A $mode;                       echo "[$mode] same cache, same out dir A after deleting it: $(n $T/A) files"
  run $T/C $mode ZV_AIR_STD=1;          echo "[$mode] same cache, ZV_AIR_STD=1 -> C: $(n $T/C) files"
  run $T/D $mode ZV_AIR_STD=1;          echo "[$mode] again STD=1 to new dir D: $(n $T/D) files"
done
