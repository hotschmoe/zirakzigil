#!/bin/sh
# Run inside an extracted Zig tree: two plausible upstream edits to src/Air.zig.
#   1. Air.Bin gains a defaulted third operand, so every producer still compiles.
#   2. The doc comment of `add` stops saying `bin_op` (the code does not change).
set -eu
perl -0pi -e 's/(pub const Bin = struct \{\n    lhs: Inst\.Ref,\n    rhs: Inst\.Ref,\n)\};/$1    mask: Inst.Ref = .none,\n};/ or die "Bin" ; s/(        \/\/\/ Uses the `)bin_op(` field\.\n        add,)/$1un_op$2/ or die "add"' src/Air.zig
git diff --no-index --stat /dev/null /dev/null >/dev/null 2>&1 || true
grep -n "mask: Inst.Ref = .none" src/Air.zig
