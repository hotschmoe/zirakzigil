#!/bin/sh
# Packs a built zig-zv as the release asset `dist/zig-zv-<zig tag>-<patch queue hash>-<arch>-<os>.tar.gz` and prints
# its path. The name is what build.zig.zon pins (tools/pin_assets.sh), so an asset is reused until the queue changes.
#   tools/package_zig_zv.sh [ZIG_ZV]     default: compiler/.work/zig-src/zig-out/bin/zig-zv
set -eu
cd "$(dirname "$0")/.."

case $(uname -s) in
    MINGW* | MSYS* | CYGWIN*) os=windows exe=.exe ;;
    Linux) os=linux exe= ;;
    Darwin) os=macos exe= ;;
    *) echo "error: unsupported host $(uname -s)" >&2; exit 1 ;;
esac
case $(uname -m) in
    x86_64 | AMD64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
bin=${1:-compiler/.work/zig-src/zig-out/bin/zig-zv$exe}
[ -f "$bin" ] || { echo "error: no zig-zv at $bin (tools/build_zig_zv.sh builds it)" >&2; exit 1; }

tag=$(awk '$1 == "tag" { print $2 }' compiler/ZIG_VERSION)
name=zig-zv-$tag-$(sh tools/queue_hash.sh)-$arch-$os.tar.gz
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp "$bin" "$stage/zig-zv$exe"
cp compiler/ZIG_VERSION "$stage/ZIG_VERSION"
chmod 755 "$stage/zig-zv$exe"
mkdir -p dist
tar -czf "dist/$name" -C "$stage" "zig-zv$exe" ZIG_VERSION
echo "dist/$name"
