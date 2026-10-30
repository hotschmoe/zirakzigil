#!/bin/sh
# Exports the AIR pack of a Zig file, the way zvc reads it: Debug, ghost code on, a fixed target.
#   tools/zvc_export.sh OUT_DIR FILE.zig [--only PATH]...      writes OUT_DIR/<stem>.zvp
# PATH is a dotted path in the file, as its root sees it (`wire.tcp.SeqNumber`): the container whose
# functions to export. Without --only, every pub function of the file. The file's imports of other
# modules must be named after the dependency: `zv` is src/zv.zig. `--dep NAME=FILE.zig` adds a module of that name
# (it may import `zv` too), for a file that imports a sibling the way a build.zig would wire it.
# ZV_AIR_STD=1 also exports std, cut down to what the project reaches (zv-air slice): the checker then reads the
# bodies of std's containers instead of a table.
# The compiler is zig-zv (tools/build_zig_zv.sh): ZIG_ZV, else compiler/.work/zig-src/zig-out/bin/zig-zv.
set -eu

[ $# -ge 2 ] || { echo "usage: $0 OUT_DIR FILE.zig [--only PATH]... [--dep NAME=FILE.zig]..." >&2; exit 2; }
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
deps=
dep_list=
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || { echo "usage: $0 OUT_DIR FILE.zig [--only PATH]... [--dep NAME=FILE.zig]..." >&2; exit 2; }
    case $1 in
        --only) items="${items:+$items, }target.$2" ;;
        --dep)
            name=${2%%=*}
            path=${2#*=}
            deps="$deps --dep $name"
            dep_list="$dep_list $name=$path"
            ;;
        *) echo "usage: $0 OUT_DIR FILE.zig [--only PATH]... [--dep NAME=FILE.zig]..." >&2; exit 2 ;;
    esac
    shift 2
done
# Every extra module sees zv and every other extra module.
dep_modules=
for entry in $dep_list; do
    name=${entry%%=*}
    others=
    for other in $dep_list; do [ "${other%%=*}" = "$name" ] || others="$others --dep ${other%%=*}"; done
    dep_modules="$dep_modules --dep zv$others -M$entry"
done
mkdir -p "$out"
out=$(cd "$out" && { pwd -W 2>/dev/null || pwd; })
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf 'pub const ghost: bool = true;\n' >"$work/zv_options.zig"
printf 'const target = @import("target");\npub const items = .{ %s };\n' "${items:-target}" >"$work/selection.zig"

air_root=air_all
[ -z "${ZVC_DEEP:-}" ] || air_root=air_deep
stem=$(basename "$file" .zig)
index=$work/$stem
mkdir -p "$index"
# shellcheck disable=SC2086
ZV_AIR_OUT=$index "$zv" test -fno-emit-bin -target "$target" -mcpu baseline $lib \
    --dep target --dep selection -Mroot="$root/src/verify/$air_root.zig" \
    --dep zv$deps -Mtarget="$file"$dep_modules \
    --dep target -Mselection="$work/selection.zig" \
    --dep zv_options -Mzv="$root/src/zv.zig" \
    -Mzv_options="$work/zv_options.zig"
pack=$(ls "$index"/*.zvp)
cp "$pack" "$out/$stem.zvp"
# With the library in the pack (ZV_AIR_STD=1), keep the project and the library functions it reaches.
if [ -n "${ZV_AIR_STD:-}" ]; then
    cli=$root/zig-out/bin/zv-air
    [ -f "$cli" ] || [ -f "$cli.exe" ] || (cd "$root" && zig build zv-air)
    "$cli" slice "$out/$stem.zvp" "$out/$stem.zvp" >/dev/null
fi
echo "exported $out/$stem.zvp"
