#!/bin/sh
# Cache scenarios for ZV_AIR_OUT on a `zig build` project of two objects, a and b, run against one
# zig-zv. After every build the output directory must hold the complete export.
#   tools/check_cache.sh ZIG_ZV [STOCK_ZIG]
# With STOCK_ZIG (built from the same tag, tools/build_zig_zv.sh with ZV_STOCK=1), also checks that with the
# export off zig-zv writes the same cache entries as the stock compiler.
# Needs a platform where zig-zv links the build runner: Linux, not Windows (docs/phase1.md).
set -eu

[ $# -ge 1 ] || { echo "usage: $0 ZIG_ZV [STOCK_ZIG]" >&2; exit 2; }
zv=$1
stock=${2:-}
root=$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })
work=$root/compiler/.work/cache
proj=$work/proj
out=$work/out
fail=0

rm -rf "$work"
mkdir -p "$proj"
cat >"$proj/build.zig" <<'ZIG'
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.dependency("dep", .{});
    const target = b.standardTargetOptions(.{});
    for ([_][]const u8{ "a", "b" }) |name| {
        const obj = b.addObject(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("{s}.zig", .{name})),
                .target = target,
                .strip = true,
            }),
        });
        b.getInstallStep().dependOn(&b.addInstallFile(obj.getEmittedBin(), b.fmt("{s}.o", .{name})).step);
    }
}
ZIG
mkdir -p "$proj/dep"
printf '.{ .name = .dep, .version = "0.0.1", .fingerprint = 0xf81054301c3a9f5e, .paths = .{ "" } }
' >"$proj/dep/build.zig.zon"
printf 'const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b;
}
' >"$proj/dep/build.zig"
printf '.{ .name = .proj, .version = "0.0.1", .fingerprint = 0x520c3c901ec752a6, .dependencies = .{ .dep = .{ .path = "dep" } }, .paths = .{ "" } }
' >"$proj/build.zig.zon"
for name in a b; do
    printf 'export fn %s_one(x: u32) u32 {\n    return x +%% 1;\n}\nexport fn %s_two(x: u32) u32 {\n    return x *%% 2;\n}\n' "$name" "$name" >"$proj/$name.zig"
done

# build LABEL COMPILER EXPORT_DIR [args]: one zig build in the shared caches; the log is $work/LABEL.log.
# Without EXPORT_DIR the export is off.
build() {
    label=$1 compiler=$2 dir=$3
    shift 3
    if [ -n "$dir" ]; then export ZV_AIR_OUT=$dir; else unset ZV_AIR_OUT; fi
    (cd "$proj" && "$compiler" build --cache-dir "$work/local" --summary all "$@") >"$work/$label.log" 2>&1 || {
        echo "FAIL   $label: build failed"
        tail -n 8 "$work/$label.log"
        fail=1
    }
}

names() { ls "$1" 2>/dev/null | sort; }
check() { # description, command...
    description=$1
    shift
    if "$@"; then echo "ok     $description"; else echo "FAIL   $description"; fail=1; fi
}
same_names() { [ "$(names "$1")" = "$(cat "$2")" ]; }
cached() { grep -q 'cached' "$work/$1.log"; }

export ZIG_GLOBAL_CACHE_DIR=$work/global

build cold "$zv" "$out"
names "$out" >"$work/cold.names"
has_all() { [ "$(wc -l <"$1")" = 4 ] && [ "$(sed -n '/^a\./p' "$1" | wc -l)" = 2 ] && [ "$(sed -n '/^b\./p' "$1" | wc -l)" = 2 ]; }
check "cold build exports a_one a_two b_one b_two ($(wc -l <"$work/cold.names") files)" has_all "$work/cold.names"

rm -rf "$out"
build hit "$zv" "$out"
check "second build is a cache hit" cached hit
check "the hit restores the same set after the output directory was deleted" same_names "$out" "$work/cold.names"

build hit_present "$zv" "$out"
check "a hit with the output directory present leaves the same set" same_names "$out" "$work/cold.names"

rm -rf "$out"
sed -i.bak 's/x +% 1/x +% 3/' "$proj/a.zig"
build edit "$zv" "$out"
names "$out" >"$work/edit.names"
sed -n '/^b\./p' "$work/edit.names" >"$work/edit.b"
sed -n '/^b\./p' "$work/cold.names" >"$work/cold.b"
check "after editing a.zig the set is complete" [ "$(wc -l <"$work/edit.names")" = "$(wc -l <"$work/cold.names")" ]
check "after editing a.zig only a's files changed" cmp -s "$work/edit.b" "$work/cold.b"
check "after editing a.zig a_one changed" [ "$(sed -n '/^a\.a_one/p' "$work/edit.names")" != "$(sed -n '/^a\.a_one/p' "$work/cold.names")" ]

rm -rf "$out"
build edit_hit "$zv" "$out"
check "rebuilding after the edit is a cache hit with the same set" same_names "$out" "$work/edit.names"

refused() {
    rm -rf "$work/local" "$out"
    ! (cd "$proj" && ZV_AIR_OUT=$out "$zv" build --cache-dir "$work/local" -fincremental) >"$work/incremental.log" 2>&1 &&
        grep -q 'cannot be combined with -fincremental' "$work/incremental.log"
}
check "-fincremental with the export on is refused loudly" refused

same_objects() { cmp -s "$work/prefix-$1/a.o" "$work/prefix-$2/a.o" && cmp -s "$work/prefix-$1/b.o" "$work/prefix-$2/b.o"; }
if [ -n "$stock" ]; then
    for variant in stock off on; do
        rm -rf "$work/local" "$work/global"
        case $variant in
            stock) compiler=$stock dir= ;;
            off) compiler=$zv dir= ;;
            on) compiler=$zv dir=$work/out-on ;;
        esac
        build "objects_$variant" "$compiler" "$dir" --prefix "$work/prefix-$variant"
        ls "$work/local/o" | sort >"$work/entries-$variant"
    done
    check "export off: zig-zv writes the cache entries of the stock compiler ($(wc -l <"$work/entries-stock") entries)" cmp -s "$work/entries-stock" "$work/entries-off"
    check "export off: the objects are identical to stock's" same_objects stock off
    check "export on: the objects are identical to stock's" same_objects stock on
fi

echo "$([ "$fail" = 0 ] && echo PASS || echo FAIL)"
[ "$fail" = 0 ]
