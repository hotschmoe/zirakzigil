#!/bin/sh
# The adopting-project flow end to end, as CI runs it and as the numbers in docs/ergonomics.md are measured: a fresh
# project made from tests/consumer next to a copy of this tree; the zig-zv built from this tree packaged and pinned
# the way a release is (served from a local asset server, fetched and checksummed by the Zig package manager); Z3 from
# its upstream release; then a cold `zig build verify`, a warm one, a one-function edit, and a seeded mistake that
# must fail. Needs a built zig-zv (tools/build_zig_zv.sh, or ZIG_ZV) and python.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
case $(uname -s) in
    MINGW* | MSYS* | CYGWIN*) target=x86_64-windows ;;
    Linux) target=x86_64-linux ;;
    *) echo "error: no zig-zv asset for $(uname -s)" >&2; exit 1 ;;
esac
python=python3
python3 -c "" >/dev/null 2>&1 || python=python

work=${1:-$(mktemp -d)}
rm -rf "$work"
mkdir -p "$work/assets" "$work/zirakzigil" "$work/proj"
server=
trap '[ -z "$server" ] || kill "$server" 2>/dev/null || true' EXIT

(cd "$root" && tar --exclude=.git --exclude=.zig-cache --exclude=zig-out --exclude=.work --exclude=dist -cf - .) | tar -xf - -C "$work/zirakzigil"
(cd "$root/tests/consumer" && tar --exclude=.zig-cache --exclude=zig-out -cf - .) | tar -xf - -C "$work/proj"
sed -i 's|\.path = "../.."|.path = "../zirakzigil"|' "$work/proj/build.zig.zon"

asset=$(cd "$root" && sh tools/package_zig_zv.sh ${ZIG_ZV:+"$ZIG_ZV"})
cp "$root/$asset" "$work/assets/"
port=$((20000 + $$ % 20000))
(cd "$work/assets" && exec $python -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
server=$!
sleep 2
(cd "$work/zirakzigil" && ZV_PIN_TARGETS=$target sh tools/pin_assets.sh flow "http://127.0.0.1:$port" >/dev/null)

export ZIG_GLOBAL_CACHE_DIR=$work/global-cache
cd "$work/proj"
now() { date +%s; }
run() { # label, expected status
    start=$(now)
    status=0
    zig build verify >"$work/$1.log" 2>&1 || status=$?
    took=$(($(now) - start))
    echo "flow: $1 $took s (exit $status)"
    if [ "$status" -ne "$2" ]; then cat "$work/$1.log" >&2; echo "error: $1 exited $status, expected $2" >&2; exit 1; fi
    eval "$1_s=$took"
}

run cold 0
[ "$cold_s" -lt 300 ] || { echo "error: the first green check took $cold_s s, the budget is 300 s" >&2; exit 1; }
grep -q '^zv: 3 proved (0 from the cache)' "$work/cold.log"
run warm 0
grep -q '^zv: 3 proved (3 from the cache)' "$work/warm.log"
sed -i '0,/const mid = lo + (hi - lo) \/ 2;/s//const mid = lo + ((hi - lo) >> 1);/' src/bounds.zig
run edit 0
grep -q '^zv: 3 proved (2 from the cache)' "$work/edit.log"
sed -i '0,/const mid = lo + ((hi - lo) >> 1);/s//const mid = (lo + hi) \/ 2;/' src/bounds.zig
run mistake 1
grep -q '^REFUTED  bounds.midpoint' "$work/mistake.log"
echo "flow: ok (cold $cold_s s, warm $warm_s s, one-function edit $edit_s s)"
