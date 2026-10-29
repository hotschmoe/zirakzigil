#!/bin/sh
# Coverage and oracle gate (fixed target, so the legalization the dump shows does not depend on the host CPU): exports research/corpus/corpus.zig with a zig-zv built with ZV_DEBUG_AIR=1
# (tools/build_zig_zv.sh) and requires
#   - every file to validate and round-trip (air_read.py),
#   - the pinned counts: 27 functions, 1083 instructions, 0 unsupported,
#   - the hook's JSON to agree with the compiler's own --verbose-air text of the same run (air_oracle.py).
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
ZV_AIR_OUT=$tmp/out "$zv" test -fno-emit-bin -target x86_64-windows-gnu --zig-lib-dir "$lib" --verbose-air "$root/research/corpus/corpus.zig" 2>"$tmp/dump.txt"
PYTHONUTF8=1 "$python" "$root/tools/air_read.py" "$tmp/out"
PYTHONUTF8=1 "$python" "$root/tools/air_oracle.py" "$tmp/out" "$tmp/dump.txt" --functions 27 --instructions 1083
