#!/usr/bin/env python3
"""Compares what zvc parses from a source file with what the AIR export says about the same functions.

usage: air_vs_zvc.py FILE.zig PACK.json|AIR_DIR   (the JSON form of a pack: zv-air dump)
zvc needs z3 only to prove; its parser is used here, so a stub stands in when z3 is not installed.
"""
import collections
import json
import sys
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
try:
    import z3  # noqa: F401
except ImportError:
    sys.modules["z3"] = types.ModuleType("z3")
import zvc

CONTRACTS = {"zv.requires": "requires", "zv.ensures": "ensures", "zv.invariant": "invariant"}


def count_tags(node, counts):
    if isinstance(node, tuple) and node and isinstance(node[0], str):
        counts[node[0]] += 1
    if isinstance(node, (tuple, list)):
        for child in node:
            count_tags(child, counts)


def walk(insts):
    for inst in insts:
        yield inst
        for body in inst.get("bodies", []):
            yield from walk(body["insts"])


def main():
    path, air_dir = sys.argv[1], Path(sys.argv[2])
    src = Path(path).read_text(encoding="utf-8")
    toks = zvc.lex(src)
    levels = zvc.manifest(src)
    docs = {}
    for f in sorted(air_dir.rglob("*.json")) if air_dir.is_dir() else [air_dir]:
        pack = json.loads(f.read_text(encoding="utf-8"))
        for d in pack["functions"]:
            docs[d["fqn"].split(".", 1)[-1]] = d

    print(f"{'function':<14} {'level':<9} {'zvc':<34} AIR")
    for name, level in levels.items():
        i = zvc.find_fn(toks, name)
        try:
            p = zvc.Parser(toks)
            p.i = i
            _, params, _, body = p.fn()
            c = collections.Counter()
            count_tags(body, c)
            z = f"{len(params)} params; " + ", ".join(f"{c[k]} {k}" for k in ("requires", "ensures", "invariant") if c[k])
        except zvc.Unsupported as ex:
            z = f"outside subset ({str(ex)[:40]})"
        d = docs.get(name)
        if d is None:
            print(f"{name:<14} {level:<9} {z:<34} MISSING")
            continue
        c = collections.Counter(CONTRACTS[x["attrs"]["callee"]] for x in walk(d["insts"])
                                if x["tag"] == "dbg_inline_block" and x["attrs"]["callee"] in CONTRACTS)
        a = f"line {d['line']}; {len(d['params'])} params; " + ", ".join(f"{c[k]} {k}" for k in ("requires", "ensures", "invariant") if c[k])
        panics = sum(1 for x in walk(d["insts"]) if x["tag"].endswith("_safe"))
        print(f"{name:<14} {level:<9} {z:<34} {a}; {panics} safety-checked ops")


if __name__ == "__main__":
    main()
