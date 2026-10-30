#!/bin/sh
# The differential oracle for zv-own, at a fixed seed and budget (seed 1, 300 programs, 6 minimizations).
#   ZIG_ZV=/path/to/zig-zv tools/oracle/run.sh [--seed N] [--count N] [--out DIR] [--minimize N] [--modes plain,std]
# Needs the patched compiler (tools/build_zig_zv.sh) in ZIG_ZV and stock zig 0.17 on PATH. Writes report.md,
# report.json and results.jsonl to zig-out/oracle (or --out). The same seed and count give the same report.
set -eu
cd "$(dirname "$0")/../.."
[ -n "${ZIG_ZV:-}" ] || { echo "oracle: set ZIG_ZV to the patched compiler (tools/build_zig_zv.sh)" >&2; exit 2; }
exec zig build oracle -Doptimize=ReleaseSafe -- "$@"
