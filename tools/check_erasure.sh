#!/bin/sh
# A build without ghost code compiles the verified free list to the machine code of the same program written without the
# proof: tests/erasure/plain.zig against examples/freelist.zig, ReleaseFast, ghost off. Needs stock Zig only.
set -eu
cd "$(dirname "$0")/.."

out=${TMPDIR:-/tmp}/zv-erasure
mkdir -p "$out"
printf 'pub const ghost: bool = false;\n' >"$out/options.zig"
zig build-obj -OReleaseFast -fstrip -fno-emit-bin -femit-asm="$out/plain.s" tests/erasure/plain.zig
zig build-obj -OReleaseFast -fstrip -fno-emit-bin -femit-asm="$out/real.s" \
    --dep freelist -Mroot=tests/erasure/real.zig \
    --dep zv -Mfreelist=examples/freelist.zig \
    --dep zv_options -Mzv=src/zv.zig -Mzv_options="$out/options.zig"

# The entry points only: everything between a function's label and its `.size` line, without comments and addresses.
body() { # FILE SYMBOL
    awk -v sym="$2" '$0 ~ ("^[.]?L?[a-z]*[.]?" sym ":") { on = 1 } on { print } on && /^[.](seh|cfi)_endproc/ { exit }' "$1" |
        sed -e 's/#.*//' -e 's/[.]LBB[0-9]*_[0-9]*/.LBB/g' -e 's/[.]L\(plain\|real\)[.]//g' -e 's/\(plain\|real\)[.]//g' |
        grep -v -e '^[[:space:]]*[.]\(file\|loc\|cfi_\)' -e '^[[:space:]]*$' || true
}
for sym in freelist_alloc freelist_free; do
    body "$out/plain.s" "$sym" >"$out/plain.$sym"
    body "$out/real.s" "$sym" >"$out/real.$sym"
    [ -s "$out/plain.$sym" ] || { echo "check_erasure: no $sym in the plain build" >&2; exit 1; }
    if ! cmp -s "$out/plain.$sym" "$out/real.$sym"; then
        echo "check_erasure: $sym differs between plain.zig and examples/freelist.zig" >&2
        diff "$out/plain.$sym" "$out/real.$sym" >&2 || true
        exit 1
    fi
done
echo "check_erasure: freelist_alloc and freelist_free are identical ($(wc -l <"$out/plain.freelist_alloc") and $(wc -l <"$out/plain.freelist_free") lines of assembly)"
