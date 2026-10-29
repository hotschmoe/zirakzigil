#!/bin/sh
# Cache scenarios for ZV_AIR_OUT on a `zig build` project of two objects, a and b, run against one
# zig-zv. After every build the index directory must name exactly the current packs: two packs, four
# functions, nothing from an older edit, and every entry must match its pack (zv-air verify).
#   tools/check_cache.sh ZIG_ZV [STOCK_ZIG]
# With STOCK_ZIG (built from the same tag, tools/build_zig_zv.sh with ZV_STOCK=1), also checks that with the
# export off zig-zv writes the same cache entries as the stock compiler.
# Needs a platform where zig-zv links the build runner: Linux, not Windows (docs/phase1.md).
set -eu

[ $# -ge 1 ] || { echo "usage: $0 ZIG_ZV [STOCK_ZIG]" >&2; exit 2; }
absolute() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
zv=$(absolute "$1")
stock=
[ $# -lt 2 ] || stock=$(absolute "$2")
root=$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })
work=$root/compiler/.work/cache
proj=$work/proj
out=$work/out
fail=0

rm -rf "$work"
mkdir -p "$proj"
(cd "$root" && zig build zv-air -Doptimize=ReleaseSafe --prefix "$work/cli")
cli=$work/cli/bin/zv-air

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

# build LABEL COMPILER INDEX_DIR [args]: one zig build in the shared caches; the log is $work/LABEL.log.
# Without INDEX_DIR the export is off.
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

# The functions the index names, and the packs it names.
functions() { "$cli" list "$1" 2>/dev/null | cut -f1,2 | sort; }
packs() { ls "$1"/*.zvi 2>/dev/null | wc -l | tr -d ' '; }
check() { # description, command...
    description=$1
    shift
    if "$@"; then echo "ok     $description"; else echo "FAIL   $description"; fail=1; fi
}
same_functions() { [ "$(functions "$1")" = "$(cat "$2")" ]; }
exact() { # index dir: two packs, four functions, every entry matches its pack
    [ "$(packs "$1")" = 2 ] && [ "$(functions "$1" | wc -l | tr -d ' ')" = 4 ] && "$cli" verify "$1" >/dev/null
}
cached() { grep -q 'cached' "$work/$1.log"; }
waitfor() { # seconds, command...: poll until the command succeeds
    limit=$1
    shift
    while [ "$limit" -gt 0 ]; do
        if "$@"; then return 0; fi
        sleep 1
        limit=$((limit - 1))
    done
    return 1
}

export ZIG_GLOBAL_CACHE_DIR=$work/global

build cold "$zv" "$out"
functions "$out" >"$work/cold.functions"
check "cold build: the index names a and b, four functions" exact "$out"

rm -rf "$out"
build hit "$zv" "$out"
check "second build is a cache hit" cached hit
check "the hit names the same functions again after the index was deleted" same_functions "$out" "$work/cold.functions"

build hit_present "$zv" "$out"
check "a hit with the index present leaves the same set" same_functions "$out" "$work/cold.functions"

sed -i.bak 's/x +% 1/x +% 3/' "$proj/a.zig"
build edit "$zv" "$out"
functions "$out" >"$work/edit.functions"
sed -n '/b_/p' "$work/edit.functions" >"$work/edit.b"
sed -n '/b_/p' "$work/cold.functions" >"$work/cold.b"
check "after editing a.zig, with the old index kept, it names exactly the current packs" exact "$out"
check "after editing a.zig only a's functions changed" cmp -s "$work/edit.b" "$work/cold.b"
a_one_replaced() { [ "$(grep -c 'a_one' "$1")" = 1 ] && [ "$(sed -n '/a_one/p' "$1")" != "$(sed -n '/a_one/p' "$2")" ]; }
check "after editing a.zig a_one changed and its old version is gone" a_one_replaced "$work/edit.functions" "$work/cold.functions"

build edit_hit "$zv" "$out"
check "rebuilding after the edit is a cache hit with the same set" same_functions "$out" "$work/edit.functions"

refused() {
    rm -rf "$work/local" "$out"
    ! (cd "$proj" && ZV_AIR_OUT=$out "$zv" build --cache-dir "$work/local" -fincremental) >"$work/incremental.log" 2>&1 &&
        grep -q 'cannot be combined with -fincremental' "$work/incremental.log"
}
check "-fincremental with the export on is refused loudly" refused

# --watch: the build runner keeps the compiler children alive and rebuilds the steps whose inputs changed.
rm -rf "$work/local" "$out"
(cd "$proj" && ZV_AIR_OUT=$out exec "$zv" build --watch --cache-dir "$work/local") >"$work/watch.log" 2>&1 &
watcher=$!
settled() { exact "$out"; }
check "--watch: the first build names a and b" waitfor 120 settled
functions "$out" >"$work/watch0.functions"
sed -i.bak 's/x +% 3/x +% 5/' "$proj/a.zig"
changed() { exact "$out" && ! same_functions "$out" "$work/watch0.functions"; }
check "--watch, edit a.zig: the index names exactly the current packs (no union with the old a)" waitfor 120 changed
functions "$out" >"$work/watch1.functions"
b_untouched() { [ "$(sed -n '/b_/p' "$work/watch1.functions")" = "$(sed -n '/b_/p' "$work/watch0.functions")" ]; }
check "--watch, edit a.zig: b is untouched" b_untouched
check "--watch, edit a.zig: a_one changed and its old version is gone" a_one_replaced "$work/watch1.functions" "$work/watch0.functions"
rm -rf "$out"
sed -i.bak 's/x +% 5/x +% 7/' "$proj/a.zig"
reappeared() { [ "$(packs "$out")" -ge 1 ]; }
check "--watch, index deleted then a.zig edited: the rebuilt step names its pack again" waitfor 120 reappeared
echo "note   --watch, index deleted: $(packs "$out") of 2 packs (steps that did not rebuild do not run; the next full zig build restores them)"
kill "$watcher" 2>/dev/null || true
wait "$watcher" 2>/dev/null || true

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
