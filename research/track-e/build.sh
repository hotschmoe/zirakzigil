#!/bin/sh
# Builds a zig-zv with the generated adapter: sh research/track-e/build.sh VER [check]
#   VER is 0.16 or 0.17; sources come from research/track-e/compiler/VER/zv_air.
#   check: type-check only (-Dno-bin), about 30 s.
# Output: $ZV_WORK/VER/zig-out/bin/zig-zv-VER. Run it through the build lock.
set -eu
ver=$1
mode=${2:-full}
here=$(cd "$(dirname "$0")" && pwd)
case $ver in
    0.16) up=/c/Users/hotschmoe/Documents/GitHub/zig-0.16; host=/c/Users/hotschmoe/zr/host-0.16/zig.exe; ref=0.16.0; vs= ;;
    0.17) up=/c/Users/hotschmoe/Documents/GitHub/zig-0.17; host=zig; ref=0.17.0; vs="-Dversion-string=0.17.0" ;;
esac
work=${ZV_WORK:-/c/Users/hotschmoe/zr/gen/work}
tree=$work/$ver
hooked="src/main.zig src/Compilation.zig src/Zcu/PerThread.zig"
if [ ! -d "$tree" ]; then
    mkdir -p "$tree"
    git -c core.longpaths=true -C "$up" archive "$ref" | tar -x -C "$tree"
fi
cd "$tree"
git -c core.longpaths=true -C "$up" archive "$ref" $hooked | tar -x
rm -rf src/zv_air
cp -R "${ZV_SRC:-$here/compiler/$ver/zv_air}" src/zv_air
git apply "$here/../../compiler/hook.patch"
start=$(date +%s)
status=0
if [ "$mode" = check ]; then
    "$host" build -Dno-lib -Denable-llvm=false -Dno-bin -Ddebug-extensions=true -Doptimize=ReleaseFast $vs >"$work/$ver.log" 2>&1 || status=$?
else
    "$host" build -Dno-lib -Denable-llvm=false -Ddebug-extensions=true -Doptimize=ReleaseFast $vs >"$work/$ver.log" 2>&1 || status=$?
fi
echo "build $ver $mode status=$status seconds=$(( $(date +%s) - start ))"
if [ "$status" -ne 0 ]; then
    others=$(grep '^error:' "$work/$ver.log" | grep -v 'memory usage peaked at .* exceeding the declared upper bound' | grep -v 'the following build command' || true)
    grep -E 'error:|^src/' "$work/$ver.log" | grep -v 'memory usage peaked' | head -${ZV_ERR_LINES:-40} || true
    if [ -n "$others" ] || ! grep -q 'memory usage peaked' "$work/$ver.log"; then exit 1; fi
fi
exe=; [ -f zig-out/bin/zig.exe ] && exe=.exe
if [ "$mode" != check ]; then
    [ -f "zig-out/bin/zig$exe" ] || { echo "error: no compiler was installed" >&2; exit 1; }
    cp "zig-out/bin/zig$exe" "zig-out/bin/zig-zv-$ver$exe"
    echo "built $tree/zig-out/bin/zig-zv-$ver$exe"
fi
