#!/bin/sh
# Fails when a zig-zv asset pinned in build.zig.zon was built from another patch queue or Zig tag than this tree's:
# the compiler would then differ from the sources the checkers are built from. Unpinned is fine (build from source).
set -eu
cd "$(dirname "$0")/.."

want=zig-zv-$(awk '$1 == "tag" { print $2 }' compiler/ZIG_VERSION)-$(sh tools/queue_hash.sh)-
status=0
for url in $(sed -n 's/^ *\.url = "\(.*\/zig-zv-[^"]*\)",$/\1/p' build.zig.zon); do
    case ${url##*/} in
        "$want"*) echo "ok $url" ;;
        *) echo "error: $url is not a $want* asset: run the release workflow for this commit and tools/pin_assets.sh" >&2; status=1 ;;
    esac
done
exit $status
