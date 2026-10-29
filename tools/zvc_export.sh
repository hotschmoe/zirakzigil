#!/bin/sh
# Exports the AIR pack of each given Zig file, the way zvc reads it: Debug, ghost code on, a fixed target.
#   tools/zvc_export.sh OUT_DIR FILE.zig...      writes OUT_DIR/<stem>.zvp
# The compiler is zig-zv (tools/build_zig_zv.sh): ZIG_ZV, else compiler/.work/zig-src/zig-out/bin/zig-zv.
# Every pub function of FILE is analyzed (tools/air_all.zig is the root), so a function no test reaches is
# still exported. The sources are imported as module `target`; `zv` is src/zv.zig.
set -eu

[ $# -ge 2 ] || { echo "usage: $0 OUT_DIR FILE.zig..." >&2; exit 2; }
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
shift
mkdir -p "$out"
out=$(cd "$out" && { pwd -W 2>/dev/null || pwd; })
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf 'pub const ghost: bool = true;\n' >"$work/zv_options.zig"

for file in "$@"; do
    stem=$(basename "$file" .zig)
    index=$work/$stem
    mkdir -p "$index"
    # shellcheck disable=SC2086
    ZV_AIR_OUT=$index "$zv" test -fno-emit-bin -target "$target" -mcpu baseline $lib \
        --dep target -Mroot="$root/tools/air_all.zig" \
        --dep zv -Mtarget="$file" \
        --dep zv_options -Mzv="$root/src/zv.zig" \
        -Mzv_options="$work/zv_options.zig"
    pack=$(ls "$index"/*.zvp)
    cp "$pack" "$out/$stem.zvp"
    echo "exported $out/$stem.zvp"
done
