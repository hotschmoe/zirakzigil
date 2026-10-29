#!/bin/sh
# b.sh VERSION(16|17|18) [env...] : build under lock; logs to a-work/log-VERSION-TAG.txt
v=$1; shift
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.longpaths GIT_CONFIG_VALUE_0=true
export ZV_WORK=/c/Users/hotschmoe/zr/a-work/w$v
case $v in
 16) export ZV_ZIG_UPSTREAM=/c/Users/hotschmoe/Documents/GitHub/zig-0.16 ZV_ZIG_REF=0.16.0 ZIG=/c/Users/hotschmoe/zr/host-0.16/zig.exe;;
 17) export ZV_ZIG_UPSTREAM=/c/Users/hotschmoe/Documents/GitHub/zig-0.17 ZIG=zig;;
 18) export ZV_ZIG_UPSTREAM=/c/Users/hotschmoe/zr/zig-0.18-dev ZV_ZIG_REF=ae9a8acc7 ZIG=/c/Users/hotschmoe/zr/host-0.18-dev/zig.exe;;
esac
cd /c/Users/hotschmoe/zr/wt-a
for kv in "$@"; do export "$kv"; done
sh /c/Users/hotschmoe/zr/buildlock.sh sh tools/build_zig_zv.sh
