#!/bin/sh
# Golden-corpus tripwire: dump the corpus with an unpatched debug-flag compiler, parse it with air_text,
# and require the parsed schema v1 to equal the committed golden files byte for byte.
#   golden.sh ZIG VERSION GOLDEN_DIR air_text DUMP_FLAGS...
# 0.17.0: golden.sh zig17 0.17.0 base17 air_text --verbose-air
# 0.18-dev: golden.sh zig18 0.18.0-dev.738+ae9a8acc7 golden/0.18.0-dev air_text --debug-log illegal-air
set -eu
zig=$1 version=$2 golden=$3 parser=$4
shift 4
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
corpus=$here/../corpus/corpus.zig
"$zig" test -fno-emit-bin "$@" "$corpus" 2>"$work/dump.txt"
"$parser" --zig-version "$version" --module corpus="$corpus" --file-module test --out "$work/out" "$work/dump.txt"
status=0
for f in "$golden"/*.json; do
    cmp -s "$f" "$work/out/$(basename "$f")" || { echo "differs or missing: $(basename "$f")" >&2; status=1; }
done
exit $status
