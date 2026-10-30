#!/bin/sh
# What a verified core costs in lines: the struct that carries the `.verified` methods, without its tests, laws and doc
# comments, counted by what each line is for.
#   code      lines the program needs
#   contract  `zv.requires` / `zv.ensures` / `zv.invariant` / `zv.decreases` and the manifest
#   spec      the bodies of the specification functions (`sound`, `owns`, `granted`, ...)
#   ghost     lines that name a token or a ghost value or call an operation on one
#   gate      `zv.ghost` conditionals and `else {}` branches: lines written to keep ghost code out of the program
# usage: tools/ghost_lines.sh FILE.zig STRUCT [REV]       (REV reads the file from git)
set -eu
file=$1
core=$2
rev=${3:-}
if [ -n "$rev" ]; then src=$(git show "$rev:$file"); else src=$(cat "$file"); fi
printf '%s\n' "$src" | awk -v core="$core" '
function spec_name(s) { return s ~ /fn (sound|owns|granted|refused|carved|together|unchanged|onList|listed|linked|isPow2|inMask|bitOf|at|padFor)\(/ }
BEGIN { inside = 0; depth = 0; in_spec = 0 }
{
    line = $0
    if (!inside) {
        if (line ~ ("^pub const " core " = struct")) { inside = 1; depth = 0 } else next
    }
    stripped = line
    sub(/^[ \t]+/, "", stripped)
    if (stripped == "" || stripped ~ /^\/\//) next
    opens = gsub(/\{/, "{", line); closes = gsub(/\}/, "}", line)
    if (in_spec == 0 && spec_name(stripped)) { in_spec = 1; spec_depth = depth }
    if (stripped ~ /zv\.ghost|else \{\}/) gate++
    else if (in_spec) spec++
    else if (stripped ~ /zv\.(requires|ensures|invariant|decreases)|assurance|requireAssurance/) contract++
    else if (stripped ~ /zv\.(Ghost|forall|Int|Seq)|BlockSet|PointsTo|\.spare|\.perm|\.order|\.posn|\.cut\(|\.split\(|\.join\(|\.apart\(|\.discard\(|const old = |const (id|mask0) = /) ghost++
    else code++
    depth += opens - closes
    if (in_spec && depth <= spec_depth) in_spec = 0
    if (started && depth <= 0 && closes > 0) exit
    started = 1
}
END { printf "code %d contract %d spec %d ghost %d gate %d  proof-per-code %.2f\n", code, contract, spec, ghost, gate, (code ? (contract + spec + ghost + gate) / code : 0) }'
