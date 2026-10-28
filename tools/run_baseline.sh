#!/usr/bin/env bash
# Runs the plain-Zig controls in tests/baseline/: the same bugs as the negative
# suite, written without zv. Shows what stock Zig does with each one, per mode.
#
# Each control prints "WRONG:" when it computes a bad result without complaint.
# Outcomes:  reject = compile error,  panic = safety check fired,
#            silent = compiled, ran, wrong answer,  ub = illegal behavior in
#            ReleaseFast (not run: the result is undefined, not a finding).
# A control's header line `//! expect: Debug=.. ReleaseSafe=.. ReleaseFast=..`
# is checked against what actually happens.
set -u
cd "$(dirname "$0")/.."
modes=(Debug ReleaseSafe ReleaseFast)
tmp=$(mktemp -d)
pass=0; fail=0

printf '%-16s %-8s %-12s %-12s\n' "control" "Debug" "ReleaseSafe" "ReleaseFast"
for f in tests/baseline/*.zig; do
  name=$(basename "$f" .zig)
  expect=$(sed -n 's#^//! expect: ##p' "$f")
  row=(); ok=1
  for m in "${modes[@]}"; do
    want=$(tr ' ' '\n' <<<"$expect" | sed -n "s/^$m=//p")
    if [[ "$want" == ub ]]; then got=ub
    elif ! zig build-exe -O "$m" "$f" -femit-bin="$tmp/$name-$m.exe" >"$tmp/log" 2>&1; then got=reject
    else
      out=$("$tmp/$name-$m.exe" 2>&1); code=$?
      if [[ $code -ne 0 ]]; then got=panic
      elif [[ "$out" == *WRONG:* ]]; then got=silent
      else got=clean; fi
    fi
    [[ "$got" == "$want" ]] || { ok=0; got="$got!=$want"; }
    row+=("$got")
  done
  printf '%-16s %-8s %-12s %-12s\n' "$name" "${row[@]}"
  if [[ $ok -eq 1 ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
rm -rf "$tmp"
echo "baseline: $pass controls behaved as documented, $fail did not"
[[ $fail -eq 0 ]]
