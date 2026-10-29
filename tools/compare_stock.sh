#!/bin/sh
# Checks the "compiler output does not change" rule: a stock build and zig-zv (built with the same
# flags from the same tag) must give identical results, with the export off and with it on.
#   tools/compare_stock.sh STOCK_ZIG ZV_ZIG
# Compared: diagnostics (stderr and exit code) of a program with a compile error, diagnostics of a
# clean -fno-emit-bin check, and the bytes of objects from the self-hosted x86_64 backend
# (no LLVM in either compiler) for a COFF and an ELF target, stripped: unstripped objects embed the
# compiler-specific cache directory name (a 32-digit hash) in their debug info, which differs per binary.
set -u

stock=$1
zv=$2
root=$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })
tmp=$root/compiler/.work/compare
rm -rf "$tmp"
mkdir -p "$tmp"
fail=0
# Both compilers read the same library tree, so absolute lib paths do not leak into the comparison.
lib=$(cd "$(dirname "$zv")/../.." && { pwd -W 2>/dev/null || pwd; })/lib

cat >"$tmp/bad.zig" <<'ZIG'
export fn f(x: u32) u8 {
    return x;
}
ZIG

cat >"$tmp/obj.zig" <<'ZIG'
const search = @import("search");
export fn mid(a: u32, b: u32) u32 {
    return search.midpoint(a, b);
}
export fn lower(xs: [*]const u32, n: usize, key: u32) usize {
    return search.lowerBound(xs[0..n], key);
}
export fn take(a: u64, b: u64) u64 {
    return search.withdraw(a, b);
}
ZIG
obj_args() { echo "--dep search -Mroot=$tmp/obj.zig --dep zv -Msearch=$root/examples/search.zig -Mzv=$root/src/zv.zig"; }

check() { # name, command prefix output file a, b
    if cmp -s "$2" "$3"; then echo "same   $1"; else echo "DIFFER $1"; fail=1; fi
}

for compiler in stock zv zv_on; do
    case $compiler in
        stock) bin=$stock; pre="env" ;;
        zv) bin=$zv; pre="env" ;;
        zv_on) bin=$zv; pre="env ZV_AIR_OUT=$tmp/air" ;;
    esac
    # shellcheck disable=SC2086
    $pre "$bin" build-obj -fno-emit-bin --zig-lib-dir "$lib" "$tmp/bad.zig" >"$tmp/$compiler.bad.out" 2>&1
    echo "exit $?" >>"$tmp/$compiler.bad.out"
    # shellcheck disable=SC2086
    $pre "$bin" test -fno-emit-bin --zig-lib-dir "$lib" --dep zv -Mroot="$root/examples/search.zig" -Mzv="$root/src/zv.zig" >"$tmp/$compiler.clean.out" 2>&1
    echo "exit $?" >>"$tmp/$compiler.clean.out"
    mkdir -p "$tmp/$compiler" # the object name is embedded in the object, so keep it identical
    for target in x86_64-windows x86_64-linux; do
        # shellcheck disable=SC2086
        $pre "$bin" build-obj --zig-lib-dir "$lib" -target "$target" -O ReleaseFast -fno-llvm -fstrip -femit-bin="$tmp/$compiler/obj.o" \
            $(obj_args) >"$tmp/$compiler.$target.out" 2>&1
        echo "exit $?" >>"$tmp/$compiler.$target.out"
        mv "$tmp/$compiler/obj.o" "$tmp/$compiler.$target.o"
    done
done

for what in bad.out clean.out x86_64-windows.out x86_64-linux.out x86_64-windows.o x86_64-linux.o; do
    for other in zv zv_on; do
        check "stock vs $other: $what" "$tmp/stock.$what" "$tmp/$other.$what"
    done
done
ls -l "$tmp"/stock.*.o | awk '{print $5, $9}'
[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
