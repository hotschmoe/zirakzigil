#!/bin/sh
# check.sh VER: type-check the zig-zv sources for one version (about 30 s, no binary).
exec sh /c/Users/hotschmoe/zr/buildlock.sh sh "$(dirname "$0")/build.sh" "$1" check
