#!/bin/sh
# Builds zig-zv: upstream Zig at the pinned tag, plus compiler/src/zv_air and compiler/hook.patch.
#   tools/build_zig_zv.sh          patched compiler -> compiler/.work/zig-src/zig-out/bin/zig-zv
#   ZV_STOCK=1 tools/build_zig_zv.sh   unpatched, same build flags -> compiler/.work/zig-stock/zig-out/bin/zig-stock
# ZV_ZIG_UPSTREAM overrides the clone source (a URL or a local path); ZIG selects the host zig;
# ZV_WORK moves the working directory (default compiler/.work; use a native filesystem under WSL).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=$root/compiler
upstream=${ZV_ZIG_UPSTREAM:-https://codeberg.org/ziglang/zig.git}
host_zig=${ZIG:-zig}
tag=$(awk '$1 == "tag" { print $2 }' "$compiler/ZIG_VERSION")
commit=$(awk '$1 == "commit" { print $2 }' "$compiler/ZIG_VERSION")

if [ "${ZV_STOCK:-0}" = 1 ]; then
    name=zig-stock
    out=zig-stock
else
    name=zig-src
    out=zig-zv
fi
work=${ZV_WORK:-$compiler/.work}
tree=$work/$name

case $upstream in
    http*://* | git@* | file://*) ;;
    *) upstream=file://$(cd "$upstream" && pwd) ;;
esac

if [ ! -d "$tree/.git" ]; then
    mkdir -p "$work"
    git clone --quiet -c core.autocrlf=false -c advice.detachedHead=false --depth 1 --branch "$tag" "$upstream" "$tree"
fi
cd "$tree"
[ "$(git rev-parse HEAD)" = "$commit" ] || { echo "error: $tree is not at $commit" >&2; exit 1; }
git reset --quiet --hard "$commit"
git clean --quiet -fd -e zig-out -e .zig-cache

if [ "$name" = zig-src ]; then
    cp -R "$compiler/src/zv_air" src/zv_air
    git apply "$compiler/hook.patch"
fi

# Upstream declares an 8 GB RSS bound for the compiler step, and this step peaks just above it on
# Windows. The build runner then marks the step failed although the binary is installed and fine
# (--maxrss only changes scheduling). So: tolerate exactly that one error, and only if the binary
# passes the checks below. Any other error fails the script.
log=$work/$name.build.log
status=0
"$host_zig" build -Dno-lib -Denable-llvm=false -Doptimize=ReleaseFast >"$log" 2>&1 || status=$?
cat "$log"
if [ "$status" -ne 0 ]; then
    others=$(grep '^error:' "$log" | grep -v 'memory usage peaked at .* exceeding the declared upper bound' | grep -v 'the following build command' || true)
    if [ -n "$others" ] || ! grep -q 'memory usage peaked' "$log"; then
        echo "error: zig build failed" >&2
        exit 1
    fi
    echo "note: ignoring the declared max_rss overrun; verifying the binary" >&2
fi

exe=
[ -f zig-out/bin/zig.exe ] && exe=.exe
bin=zig-out/bin/$out$exe
[ -f "zig-out/bin/zig$exe" ] || { echo "error: no compiler was installed" >&2; exit 1; }
cp "zig-out/bin/zig$exe" "$bin"
[ "$("$bin" version)" = "$tag" ] || { echo "error: $bin does not report version $tag" >&2; exit 1; }

if [ "$name" = zig-src ]; then
    # Smoke test: the patched compiler must export one function for a trivial program.
    smoke=$work/smoke
    rm -rf "$smoke"
    mkdir -p "$smoke"
    printf 'export fn answer() u32 {
    return 42;
}
' >"$smoke/answer.zig"
    "$bin" build-obj -fno-emit-bin --zv-air-out "$smoke/out" "$smoke/answer.zig"
    ls "$smoke"/out/answer.*.json >/dev/null 2>&1 || { echo "error: smoke export produced no JSON" >&2; exit 1; }
fi
echo "built $tree/$bin"
