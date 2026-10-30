#!/bin/sh
# Pins the zig-zv assets of a release in build.zig.zon, as lazy dependencies the Zig package manager checksums.
#   tools/pin_assets.sh TAG [BASE_URL]
# Run it after the release workflow has uploaded the assets (BASE_URL defaults to the release download URL of TAG),
# review the diff, and commit it. Only a release whose asset names carry the current patch queue hash is accepted.
set -eu
cd "$(dirname "$0")/.."

[ $# -ge 1 ] || { echo "usage: $0 TAG [BASE_URL]" >&2; exit 2; }
tag=$1
base=${2:-https://github.com/hotschmoe/zirakzigil/releases/download/$tag}
zig_tag=$(awk '$1 == "tag" { print $2 }' compiler/ZIG_VERSION)
queue=$(sh tools/queue_hash.sh)

for target in ${ZV_PIN_TARGETS:-x86_64-windows x86_64-linux}; do
    asset=zig-zv-$zig_tag-$queue-$target.tar.gz
    zig fetch --save-exact="zig_zv_$(echo "$target" | tr - _)" "$base/$asset"
done

# `zig fetch --save` does not mark a dependency lazy: add it to every asset entry that lacks it.
awk '
    /^        \.(zig_zv|z3)_[a-z0-9_]+ = \.\{$/ { held = 1; entry = ""; lazy = 0 }
    held { entry = entry $0 "\n"; if ($0 ~ /\.lazy/) lazy = 1 }
    held && /^        \},$/ {
        if (!lazy) sub(/\n        \},\n$/, "\n            .lazy = true,\n        },\n", entry)
        printf "%s", entry
        held = 0
        next
    }
    !held { print }
' build.zig.zon >build.zig.zon.new
mv build.zig.zon.new build.zig.zon
