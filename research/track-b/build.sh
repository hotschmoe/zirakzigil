#!/bin/sh
# Builds a zig-zv variant: sh research/track-b/build.sh VER [check]
#   VER is 0.16, 0.17 or 0.18; sources come from research/track-b/compiler/VER.
#   check: type-check only (-Dno-bin), no binary.
# Output: $WORK/VER/zig-out/bin/zig-zv-VER. Run it through the build lock.
set -eu
ver=$1
mode=${2:-full}
here=$(cd "$(dirname "$0")" && pwd)
case $ver in
    0.16) up=/c/Users/hotschmoe/Documents/GitHub/zig-0.16; host=/c/Users/hotschmoe/zr/host-0.16/zig.exe; ref=0.16.0 ;;
    0.17) up=/c/Users/hotschmoe/Documents/GitHub/zig-0.17; host=zig; ref=0.17.0; vs="-Dversion-string=0.17.0" ;;
    0.18) up=/c/Users/hotschmoe/zr/zig-0.18-dev; host=/c/Users/hotschmoe/zr/host-0.18-dev/zig.exe; ref=ae9a8acc7f232cb78a131b6dc05633f34d0990ad; vs="-Dversion-string=0.18.0-dev.738+ae9a8acc7" ;;
esac
vs=${vs:-}
work=${ZV_WORK:-/c/Users/hotschmoe/zr/b-work}
tree=$work/$ver
if [ ! -d "$tree" ]; then
    mkdir -p "$tree"
    git -C "$up" archive "$ref" | tar -x -C "$tree"
fi
cd "$tree"
git -C "$up" archive "$ref" src/main.zig src/Compilation.zig src/Zcu/PerThread.zig | tar -x
rm -rf src/zv_air
cp -R "${ZV_SRC:-$here/compiler/$ver/zv_air}" src/zv_air
git apply "$here/compiler/$ver/hook.patch"
start=$(date +%s)
status=0
if [ "$mode" = check ]; then
    "$host" build -Dno-lib -Denable-llvm=false -Dno-bin -Ddebug-extensions=true -Doptimize=ReleaseFast ${vs:-} ${ZV_BUILD_ARGS:-} >"$work/$ver.log" 2>&1 || status=$?
else
    "$host" build -Dno-lib -Denable-llvm=false -Ddebug-extensions=true -Doptimize=ReleaseFast ${vs:-} ${ZV_BUILD_ARGS:-} >"$work/$ver.log" 2>&1 || status=$?
fi
echo "build $ver $mode status=$status seconds=$(( $(date +%s) - start ))"
if [ "$status" -ne 0 ]; then
    grep -v 'memory usage peaked' "$work/$ver.log" | grep -E 'error:|^src/' | head -${ZV_ERR_LINES:-40} || true
fi
if [ "$mode" != check ] && [ -f zig-out/bin/zig.exe ]; then cp zig-out/bin/zig.exe "zig-out/bin/zig-zv-$ver.exe"; echo "built $tree/zig-out/bin/zig-zv-$ver.exe"; fi
