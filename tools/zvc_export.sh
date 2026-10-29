#!/bin/sh
# Exports the AIR pack of a Zig file, the way zvc reads it: Debug, ghost code on, a fixed target.
#   tools/zvc_export.sh OUT_DIR FILE.zig [--only PATH]...      writes OUT_DIR/<stem>.zvp
# PATH is a dotted path in the file, as its root sees it (`wire.tcp.SeqNumber`): the container whose
# functions to export. Without --only, every pub function of the file. The file's imports of other
# modules must be named after the dependency: `zv` is src/zv.zig.
# The compiler is zig-zv (tools/build_zig_zv.sh): ZIG_ZV, else compiler/.work/zig-src/zig-out/bin/zig-zv.
set -eu

[ $# -ge 2 ] || { echo "usage: $0 OUT_DIR FILE.zig [--only PATH]..." >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })
zv=${ZIG_ZV:-}
if [ -z "$zv" ]; then
    zv=$root/compiler/.work/zig-src/zig-out/bin/zig-zv
    [ -f "$zv.exe" ] && zv=$zv.exe
fi
lib=${ZIG_LIB:-}
[ -z "$lib" ] || lib="--zig-lib-dir $lib"
target=${ZVC_TARGET:-x86_64-linux-gnu}

out=$1
file=$2
shift 2
items=
while [ $# -gt 0 ]; do
    [ "$1" = --only ] && [ $# -ge 2 ] || { echo "usage: $0 OUT_DIR FILE.zig [--only PATH]..." >&2; exit 2; }
    items="${items:+$items, }target.$2"
    shift 2
done
mkdir -p "$out"
out=$(cd "$out" && { pwd -W 2>/dev/null || pwd; })
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf 'pub const ghost: bool = true;\n' >"$work/zv_options.zig"
printf 'const target = @import("target");\npub const items = .{ %s };\n' "${items:-target}" >"$work/selection.zig"

stem=$(basename "$file" .zig)
index=$work/$stem
mkdir -p "$index"
# shellcheck disable=SC2086
ZV_AIR_OUT=$index "$zv" test -fno-emit-bin -target "$target" -mcpu baseline $lib \
    --dep target --dep selection -Mroot="$root/tools/air_all.zig" \
    --dep zv -Mtarget="$file" \
    --dep target -Mselection="$work/selection.zig" \
    --dep zv_options -Mzv="$root/src/zv.zig" \
    -Mzv_options="$work/zv_options.zig"
pack=$(ls "$index"/*.zvp)
cp "$pack" "$out/$stem.zvp"
echo "exported $out/$stem.zvp"
