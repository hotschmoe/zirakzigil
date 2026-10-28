#!/usr/bin/env python3
"""Reader for the zig-zv AIR export (schema v1, see docs/phase1.md).

Loads every JSON file, validates it against the schema, re-serializes it and
checks the result is byte-identical to the input (the round-trip gate).

usage: air_read.py PATH... [--pretty] [--list] [--quiet]
  PATH is a .json file or a directory of them. Exit status 1 on any failure.
"""
import argparse
import collections
import json
import sys
from pathlib import Path

SCHEMA = 1


class SchemaError(Exception):
    pass


def need(cond, where, msg):
    if not cond:
        raise SchemaError(f"{where}: {msg}")


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def check_keys(obj, where, required, optional=()):
    need(isinstance(obj, dict), where, "expected object")
    missing = set(required) - obj.keys()
    extra = obj.keys() - set(required) - set(optional)
    need(not missing, where, f"missing {sorted(missing)}")
    need(not extra, where, f"unexpected {sorted(extra)}")


def check_operand(op, where, ntypes):
    if op is None:
        return
    check_keys(op, where, [], ["inst", "ty", "val"])
    if "inst" in op:
        need(set(op) == {"inst"} and is_int(op["inst"]), where, "bad inst operand")
    else:
        need(set(op) == {"ty", "val"} and is_int(op["ty"]) and isinstance(op["val"], str), where, "bad const operand")
        need(0 <= op["ty"] < ntypes, where, "type out of range")


def check_insts(insts, where, ctx):
    need(isinstance(insts, list), where, "expected array")
    for n, inst in enumerate(insts):
        w = f"{where}[{n}]"
        check_keys(inst, w, ["id", "tag"], ["ty", "operands", "attrs", "loc", "bodies", "unsupported"])
        need(is_int(inst["id"]) and isinstance(inst["tag"], str), w, "bad id/tag")
        ctx["tags"][inst["tag"]] += 1
        ctx["insts"] += 1
        if inst.get("unsupported"):
            need(inst["unsupported"] is True and set(inst) == {"id", "tag", "unsupported"}, w, "bad unsupported entry")
            ctx["unsupported"][inst["tag"]] += 1
            continue
        need(is_int(inst.get("ty")) and 0 <= inst["ty"] < ctx["ntypes"], w, "bad ty")
        for k, op in enumerate(inst.get("operands", [])):
            check_operand(op, f"{w}.operands[{k}]", ctx["ntypes"])
            if op and "inst" in op:
                ctx["refs"].append(op["inst"])
        for key, v in inst.get("attrs", {}).items():
            need(isinstance(v, (int, str, bool)), f"{w}.attrs.{key}", "bad attr value")
        if "loc" in inst:
            loc = inst["loc"]
            need(isinstance(loc, list) and len(loc) == 3 and all(is_int(x) for x in loc), w, "bad loc")
            need(loc[0] < ctx["nfiles"], w, "loc file out of range")
        for k, body in enumerate(inst.get("bodies", [])):
            bw = f"{w}.bodies[{k}]"
            check_keys(body, bw, ["label", "insts"], ["items", "ranges"])
            for item in body.get("items", []):
                check_operand(item, bw + ".items", ctx["ntypes"])
            for rng in body.get("ranges", []):
                need(len(rng) == 2, bw, "range needs two bounds")
                for end in rng:
                    check_operand(end, bw + ".ranges", ctx["ntypes"])
            check_insts(body["insts"], bw + ".insts", ctx)


def validate(doc, where):
    check_keys(doc, where, [
        "schema", "zig_version", "fqn", "file", "line", "generic_instance", "params", "ret",
        "unsupported", "files", "types", "callees", "insts",
    ])
    need(doc["schema"] == SCHEMA, where, f"schema {doc['schema']!r}, reader knows {SCHEMA}")
    need(isinstance(doc["zig_version"], str) and isinstance(doc["fqn"], str), where, "bad strings")
    need(is_int(doc["line"]) and isinstance(doc["generic_instance"], bool), where, "bad line/generic_instance")
    for f in doc["files"]:
        check_keys(f, where + ".files", ["module", "path"])
    for t in doc["types"]:
        check_keys(t, where + ".types", ["name", "kind"])
    need(0 <= doc["file"] < len(doc["files"]), where, "file out of range")
    need(0 <= doc["ret"] < len(doc["types"]), where, "ret out of range")
    for p in doc["params"]:
        check_keys(p, where + ".params", ["ty", "zir_index"])
        need(0 <= p["ty"] < len(doc["types"]), where, "param type out of range")
    for c in doc["callees"]:
        check_keys(c, where + ".callees", ["fqn", "inlined"])
    ctx = {
        "ntypes": len(doc["types"]), "nfiles": len(doc["files"]), "refs": [], "insts": 0,
        "tags": collections.Counter(), "unsupported": collections.Counter(),
    }
    check_insts(doc["insts"], where + ".insts", ctx)
    need(ctx["unsupported"].total() == doc["unsupported"], where, "unsupported count mismatch")
    return ctx


def dumps(doc, pretty=False):
    if pretty:
        return json.dumps(doc, ensure_ascii=False, indent=1)
    return json.dumps(doc, ensure_ascii=False, separators=(",", ":"))


def files_of(paths):
    for p in map(Path, paths):
        if not p.exists():
            sys.exit(f"air_read: no such path: {p}")
        yield from sorted(p.rglob("*.json")) if p.is_dir() else [p]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--pretty", action="store_true", help="print each document indented (human reading)")
    ap.add_argument("--list", action="store_true", help="list function names with instruction and callee counts")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    total = collections.Counter()
    tags = collections.Counter()
    unsupported = collections.Counter()
    failures = []
    for path in files_of(args.paths):
        raw = path.read_bytes().decode("utf-8")
        try:
            doc = json.loads(raw)
            ctx = validate(doc, path.name)
            if dumps(doc) != raw:
                raise SchemaError(f"{path.name}: round-trip differs")
        except (SchemaError, json.JSONDecodeError) as e:
            failures.append(f"{path}: {e}")
            continue
        total["functions"] += 1
        total["instructions"] += ctx["insts"]
        total["generic_instances"] += doc["generic_instance"]
        tags.update(ctx["tags"])
        unsupported.update(ctx["unsupported"])
        if args.pretty:
            print(dumps(doc, True))
        if args.list:
            callees = sorted({c["fqn"] for c in doc["callees"]})
            print(f"{doc['fqn']}\t{ctx['insts']} insts\tcalls: {', '.join(callees) or '-'}")

    for f in failures:
        print("FAIL", f, file=sys.stderr)
    if not args.quiet:
        print(f"functions {total['functions']}  instructions {total['instructions']}  "
              f"generic instances {total['generic_instances']}  distinct tags {len(tags)}  "
              f"unsupported {unsupported.total()} {dict(unsupported) or ''}  "
              f"round-trip {'FAIL' if failures else 'pass'} ({len(failures)} failures)")
    return 1 if failures or total["functions"] == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
