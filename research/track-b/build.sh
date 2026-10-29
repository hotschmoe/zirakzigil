#!/bin/sh
# Builds a zig-zv variant: sh research/track-b/build.sh VER [check]
#   VER is 0.16, 0.17 or 0.18; sources come from research/track-b/compiler/VER.
#   VER master builds upstream ZV_REF (a commit, default the one matching the host nightly) with the 0.18 sources.
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
    master) up=${ZV_UP:-https://codeberg.org/ziglang/zig.git}; host=zig; ref=${ZV_REF:-$(zig version | sed "s/.*+//")}; srcver=0.18; ZV_WORK=${ZV_WORK:-$here/.work} ;;
esac
vs=${vs:-}
srcver=${srcver:-$ver}
work=${ZV_WORK:-/c/Users/hotschmoe/zr/b-work}
tree=$work/$ver
hooked="src/main.zig src/Compilation.zig src/Zcu/PerThread.zig"
case $up in
    http*)
        if [ ! -d "$tree/.git" ]; then
            mkdir -p "$work"
            git clone --quiet -c advice.detachedHead=false --filter=blob:none "$up" "$tree"
        fi
        cd "$tree"
        git checkout --quiet "$ref"
        git checkout --quiet "$ref" -- $hooked
        ;;
    *)
        if [ ! -d "$tree" ]; then
            mkdir -p "$tree"
            git -C "$up" archive "$ref" | tar -x -C "$tree"
        fi
        cd "$tree"
        git -C "$up" archive "$ref" $hooked | tar -x
        ;;
esac
rm -rf src/zv_air
cp -R "${ZV_SRC:-$here/compiler/$srcver/zv_air}" src/zv_air
git apply "$here/compiler/$srcver/hook.patch"
if [ -n "${ZV_MUTATE:-}" ]; then sh "$ZV_MUTATE"; fi
start=$(date +%s)
status=0
if [ "$mode" = check ]; then
    "$host" build -Dno-lib -Denable-llvm=false -Dno-bin -Ddebug-extensions=true -Doptimize=ReleaseFast ${vs:-} ${ZV_BUILD_ARGS:-} >"$work/$ver.log" 2>&1 || status=$?
else
    "$host" build -Dno-lib -Denable-llvm=false -Ddebug-extensions=true -Doptimize=ReleaseFast ${vs:-} ${ZV_BUILD_ARGS:-} >"$work/$ver.log" 2>&1 || status=$?
fi
echo "build $ver $mode status=$status seconds=$(( $(date +%s) - start ))"
if [ "$status" -ne 0 ]; then
    others=$(grep '^error:' "$work/$ver.log" | grep -v 'memory usage peaked at .* exceeding the declared upper bound' | grep -v 'the following build command' || true)
    grep -E 'error:|^src/' "$work/$ver.log" | grep -v 'memory usage peaked' | head -${ZV_ERR_LINES:-40} || true
    # Upstream declares an 8 GB bound that the compiler step slightly exceeds; the binary is still installed.
    if [ -n "$others" ] || ! grep -q 'memory usage peaked' "$work/$ver.log"; then exit 1; fi
fi
exe=; [ -f zig-out/bin/zig.exe ] && exe=.exe
if [ "$mode" != check ]; then
    [ -f "zig-out/bin/zig$exe" ] || { echo "error: no compiler was installed" >&2; exit 1; }
    cp "zig-out/bin/zig$exe" "zig-out/bin/zig-zv-$ver$exe"
    echo "built $tree/zig-out/bin/zig-zv-$ver$exe"
fi
