#!/usr/bin/env bash
# Runs the negative test suite:
#   1. every should_panic program must exit non-zero with the expected zv message
#   2. every compile_fail case must FAIL to compile with the expected diagnostic
set -u
cd "$(dirname "$0")/.."
pass=0; fail=0

zig build negative >/dev/null 2>&1 || { echo "build of should-panic programs failed"; exit 1; }
declare -A expect=(
  [double_consume]="consumed twice"
  [stale_handle]="stale or foreign handle"
  [pin_copy]="pinned struct was copied"
  [precondition]="precondition violated"
)
for name in "${!expect[@]}"; do
  out=$(./zig-out/bin/$name 2>&1); code=$?
  if [[ $code -ne 0 && "$out" == *"${expect[$name]}"* ]]; then
    echo "PANIC OK   $name: ${expect[$name]}"; pass=$((pass+1))
  else
    echo "PANIC FAIL $name (exit $code)"; echo "$out" | head -5; fail=$((fail+1))
  fi
done

tmp=$(mktemp -d)
mkdir -p "$tmp/src"; cp src/*.zig "$tmp/src/"
printf 'pub const ghost: bool = false;\n' > "$tmp/src/zv_options.zig"
awk -v dir="$tmp" '
  /^### expect: / { sub(/^### expect: /, ""); print > (dir "/" name ".expect"); next }
  /^### / { name = substr($0, 5); next }
  { print > (dir "/" name ".zig") }
' tests/compile_fail/cases.txt
for f in "$tmp"/*.zig; do
  name=$(basename "$f" .zig); want=$(cat "$tmp/$name.expect")
  out=$(zig build-exe --dep zv -Mroot="$f" --dep zv_options -Mzv="$tmp/src/zv.zig" -Mzv_options="$tmp/src/zv_options.zig" \
        -femit-bin="$tmp/$name.out" 2>&1); code=$?
  if [[ $code -ne 0 && "$out" == *"$want"* ]]; then
    echo "REJECT OK  $name: $want"; pass=$((pass+1))
  else
    echo "REJECT FAIL $name (exit $code)"; echo "$out" | head -8; fail=$((fail+1))
  fi
done
rm -rf "$tmp"
echo "negative suite: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
