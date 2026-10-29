#!/bin/sh
# Coverage, oracle and format gate (fixed target, so the legalization the dump shows does not depend on
# the host CPU): exports research/corpus/corpus.zig with a zig-zv built with ZV_DEBUG_AIR=1
# (tools/build_zig_zv.sh) and requires
#   - the pack to validate and the pinned counts: 27 functions, 1083 instructions, 0 unsupported,
#   - a second export to produce the same pack, byte for byte,
#   - the pack as JSON (zv-air dump) to equal the JSON the compiler writes directly (ZV_AIR_JSON=1),
#   - that JSON to validate and round-trip (air_read.py),
#   - the JSON to agree with the compiler's own --verbose-air text of the same run (air_oracle.py).
#   tools/check_corpus.sh ZIG_ZV_AIR
set -eu

[ $# -eq 1 ] || { echo "usage: $0 ZIG_ZV_AIR" >&2; exit 2; }
zv=$1
root=$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })
tmp=$root/compiler/.work/corpus
lib=$(cd "$(dirname "$zv")/../.." && { pwd -W 2>/dev/null || pwd; })/lib
python=${PYTHON:-}
for candidate in python3 python; do
    [ -n "$python" ] || ! "$candidate" -c '' >/dev/null 2>&1 || python=$candidate
done
[ -n "$python" ] || { echo "error: no working python" >&2; exit 1; }

rm -rf "$tmp"
mkdir -p "$tmp"
(cd "$root" && zig build zv-air -Doptimize=ReleaseSafe --prefix "$tmp/cli")
cli=$tmp/cli/bin/zv-air
export_corpus() { # EXTRA_ZIG_ARGS...; the export goes to $ZV_AIR_OUT
    "$zv" test -fno-emit-bin -target x86_64-windows-gnu --zig-lib-dir "$lib" "$@" "$root/research/corpus/corpus.zig"
}

ZV_AIR_OUT=$tmp/pack export_corpus
ZV_AIR_OUT=$tmp/pack2 export_corpus
ZV_AIR_JSON=1 ZV_AIR_OUT=$tmp/json export_corpus --verbose-air 2>"$tmp/dump.txt"

"$cli" verify "$tmp/pack"
"$cli" stats "$tmp/pack" | tee "$tmp/stats.txt"
grep -q 'functions 27  generic instances 2  instructions 1083  distinct tags 100  unsupported 0' "$tmp/stats.txt" ||
    { echo "FAIL pinned counts"; exit 1; }
packs=$(ls "$tmp"/pack/*.zvp)
cmp "$packs" "$(ls "$tmp"/pack2/*.zvp)" || { echo "FAIL the pack differs between two runs"; exit 1; }
"$cli" dump "$packs" >"$tmp/from_pack.json"
cmp "$tmp/from_pack.json" "$(ls "$tmp"/json/*.json)" || { echo "FAIL pack as JSON differs from the compiler's JSON"; exit 1; }
echo "pack as JSON equals the compiler's JSON: $(wc -c <"$tmp/from_pack.json") bytes"

PYTHONUTF8=1 "$python" "$root/tools/air_read.py" "$tmp/json"
PYTHONUTF8=1 "$python" "$root/tools/air_oracle.py" "$tmp/json" "$tmp/dump.txt" --functions 27 --instructions 1083
