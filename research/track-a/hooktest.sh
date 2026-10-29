#!/bin/sh
# hooktest.sh TREE RULES : apply, show diff stats, verify, undo, confirm clean
H=/c/Users/hotschmoe/zr/a-work/bin/zv_hook_new.exe
R=/c/Users/hotschmoe/zr/wt-a/compiler/hook
cd /c/Users/hotschmoe/zr/a-work/t/$1 || exit 9
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.safecrlf GIT_CONFIG_VALUE_0=false
$H apply $R/$2.zon . 2>&1
echo "apply=$? $(git diff --shortstat 2>/dev/null)"
$H apply $R/$2.zon . >/dev/null 2>&1; echo "reapply=$? $(git diff --shortstat 2>/dev/null)"
$H verify $R/$2.zon . >/dev/null 2>&1; echo "verify=$?"
$H undo $R/$2.zon . >/dev/null 2>&1; echo "undo=$? residual=$(git diff --shortstat 2>/dev/null)"
git checkout -q . 2>/dev/null
