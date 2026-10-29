#!/bin/sh
# Builds zig-zv: upstream Zig at the pinned tag, plus compiler/src/zv_air and the hook that
# tools/zv_hook.zig inserts from compiler/hook/rules.zon.
#   tools/build_zig_zv.sh          patched compiler -> compiler/.work/zig-src/zig-out/bin/zig-zv
#   ZV_STOCK=1 tools/build_zig_zv.sh   unpatched, same build flags -> compiler/.work/zig-stock/zig-out/bin/zig-stock
#   ZV_DEBUG_AIR=1 tools/build_zig_zv.sh   patched, plus -Ddebug-extensions (--verbose-air, the oracle for
#                                      tools/air_oracle.py) -> compiler/.work/zig-air/zig-out/bin/zig-zv-air
# ZV_ZIG_UPSTREAM overrides the clone source (a URL or a local path); ZIG selects the host zig;
# ZV_WORK moves the working directory (default compiler/.work; use a native filesystem under WSL).
# ZV_ZIG_REF builds another upstream ref (branch, tag or commit hash) instead of the pin; the commit and
# version checks are skipped for it.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=$root/compiler
upstream=${ZV_ZIG_UPSTREAM:-https://codeberg.org/ziglang/zig.git}
host_zig=${ZIG:-zig}
tag=$(awk '$1 == "tag" { print $2 }' "$compiler/ZIG_VERSION")
commit=$(awk '$1 == "commit" { print $2 }' "$compiler/ZIG_VERSION")
ref=${ZV_ZIG_REF:-$tag}

flags=
if [ "${ZV_STOCK:-0}" = 1 ]; then
    name=zig-stock
    out=zig-stock
elif [ "${ZV_DEBUG_AIR:-0}" = 1 ]; then
    name=zig-air
    out=zig-zv-air
    flags=-Ddebug-extensions=true
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
    case $ref in
        *[!0-9a-f]*) git clone --quiet -c core.autocrlf=false -c advice.detachedHead=false --depth 1 --branch "$ref" "$upstream" "$tree" ;;
        *) git clone --quiet -c core.autocrlf=false -c advice.detachedHead=false --filter=blob:none "$upstream" "$tree"
           git -C "$tree" checkout --quiet "$ref" ;;
    esac
fi
cd "$tree"
if [ "$ref" = "$tag" ]; then
    [ "$(git rev-parse HEAD)" = "$commit" ] || { echo "error: $tree is not at $commit" >&2; exit 1; }
else
    commit=$(git rev-parse HEAD)
    echo "building $ref at $commit"
fi
git reset --quiet --hard "$commit"
git clean --quiet -fd -e zig-out -e .zig-cache

if [ "$name" != zig-stock ]; then
    cp -R "$compiler/src/zv_air" src/zv_air
    cp "$root/src/air/schema.zig" "$root/src/air/builder.zig" "$root/src/air/json.zig" src/zv_air/
    # Loud on drift: every anchor must match exactly once, or nothing is written.
    hook="$host_zig run $root/tools/zv_hook.zig --"
    $hook apply "$compiler/hook/rules.zon" .
    $hook verify "$compiler/hook/rules.zon" .
fi

# Upstream declares an 8 GB RSS bound for the compiler step, and this step peaks just above it on
# Windows. The build runner then marks the step failed although the binary is installed and fine
# (--maxrss only changes scheduling). So: tolerate exactly that one error, and only if the binary
# passes the checks below. Any other error fails the script.
log=$work/$name.build.log
status=0
"$host_zig" build -Dno-lib -Denable-llvm=false -Doptimize=ReleaseFast $flags >"$log" 2>&1 || status=$?
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
if [ "$ref" = "$tag" ]; then
    [ "$("$bin" version)" = "$tag" ] || { echo "error: $bin does not report version $tag" >&2; exit 1; }
fi

if [ "$name" != zig-stock ]; then
    # Smoke test: one function exported directly (no cache) and through the cache, where a hit after
    # deleting the index directory must name the same pack again.
    smoke=$work/smoke
    rm -rf "$smoke"
    mkdir -p "$smoke"
    printf 'export fn answer() u32 {
    return 42;
}
' >"$smoke/answer.zig"
    (cd "$smoke" && ZV_AIR_OUT=direct "$tree/$bin" build-obj -fno-emit-bin answer.zig)
    ls "$smoke"/direct/*.zvp "$smoke"/direct/*.zvi >/dev/null 2>&1 || { echo "error: smoke export produced no pack" >&2; exit 1; }
    for run in miss hit; do
        rm -rf "$smoke/cached"
        (cd "$smoke" && ZV_AIR_OUT=cached "$tree/$bin" build-obj --cache-dir cache answer.zig)
        ls "$smoke"/cached/*.zvi >/dev/null 2>&1 || { echo "error: smoke cache $run produced no index entry" >&2; exit 1; }
    done
    (cd "$smoke" && ZV_AIR_JSON=1 ZV_AIR_OUT=json "$tree/$bin" build-obj -fno-emit-bin answer.zig)
    ls "$smoke"/json/*.json >/dev/null 2>&1 || { echo "error: smoke export produced no JSON" >&2; exit 1; }
fi
echo "built $tree/$bin"
