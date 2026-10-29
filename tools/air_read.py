#!/usr/bin/env python3
"""Reader for the JSON form of a zig-zv AIR pack (schema v3, see docs/phase1.md).

Loads every JSON file, validates it against the schema (every table reference in range, tag and
attribute names known, unsupported counts consistent), re-serializes it and checks the result is
byte-identical to the input (the round-trip gate).

usage: air_read.py PATH... [--pretty] [--list] [--quiet]
  PATH is a .json file or a directory of them. Exit status 1 on any failure.
"""
import argparse
import collections
import json
import re
import sys
from pathlib import Path

SCHEMA = 3
TYPE_KINDS = {
    "type", "void", "bool", "noreturn", "int", "float", "pointer", "array", "struct", "comptime_float",
    "comptime_int", "undefined", "null", "optional", "error_union", "error_set", "enum", "union", "fn",
    "opaque", "frame", "anyframe", "vector", "enum_literal",
}
CONST_KINDS = {"undef", "void", "null", "bool", "int", "float", "enum_literal", "enum_tag", "error", "func", "type", "text"}
BODY_LABELS = {"then", "else", "error", "block", "loop", "inline", "case"}
ATTR_KINDS = {
    "index": int, "field": int, "locality": int, "callee": str, "target": int, "order": str, "name": str,
    "op": str, "success": str, "failure": str, "operation": str, "nav": str, "source": str, "volatile": bool,
}


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


def check_const(op, where, ctx):
    check_keys(op, where, ["ty", "kind"], ["val"])
    need(is_int(op["ty"]) and 0 <= op["ty"] < ctx["ntypes"], where, "type out of range")
    kind = op["kind"]
    need(kind in CONST_KINDS, where, f"unknown constant kind {kind!r}")
    if kind in ("undef", "void", "null"):
        need("val" not in op, where, "unexpected value")
        return
    need("val" in op, where, "missing value")
    val = op["val"]
    if kind == "bool":
        need(isinstance(val, bool), where, "bad bool")
    elif kind == "int":
        need(is_int(val), where, "bad int")
    elif kind == "float":
        need(isinstance(val, str) and re.fullmatch(r"0x[0-9a-f]{16}", val), where, "bad float bits")
    elif kind == "type":
        need(is_int(val) and 0 <= val < ctx["ntypes"], where, "type value out of range")
    else:
        need(isinstance(val, str), where, "bad string")


def check_operand(op, where, ctx):
    if op is None:
        return
    need(isinstance(op, dict), where, "expected object or null")
    if "inst" in op:
        need(set(op) == {"inst"} and is_int(op["inst"]), where, "bad inst operand")
    else:
        check_const(op, where, ctx)


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
            check_operand(op, f"{w}.operands[{k}]", ctx)
        for key, v in inst.get("attrs", {}).items():
            need(key in ATTR_KINDS and isinstance(v, ATTR_KINDS[key]) and (ATTR_KINDS[key] is bool or not isinstance(v, bool)),
                 f"{w}.attrs.{key}", "bad attribute")
            if key == "callee":
                need(v in ctx["callees"], f"{w}.attrs.callee", "unknown callee")
        if "loc" in inst:
            loc = inst["loc"]
            need(isinstance(loc, list) and len(loc) == 3 and all(is_int(x) for x in loc), w, "bad loc")
            need(0 <= loc[0] < ctx["nfiles"], w, "loc file out of range")
        for k, body in enumerate(inst.get("bodies", [])):
            bw = f"{w}.bodies[{k}]"
            check_keys(body, bw, ["label", "insts"], ["items", "ranges"])
            need(body["label"] in BODY_LABELS, bw, "unknown label")
            for item in body.get("items", []):
                check_operand(item, bw + ".items", ctx)
            for rng in body.get("ranges", []):
                need(len(rng) == 2, bw, "range needs two bounds")
                for end in rng:
                    check_operand(end, bw + ".ranges", ctx)
            check_insts(body["insts"], bw + ".insts", ctx)


def validate(doc, where):
    check_keys(doc, where, ["schema", "zig_version", "target", "optimize", "root", "files", "types", "callees", "functions"])
    need(doc["schema"] == SCHEMA, where, f"schema {doc['schema']!r}, reader knows {SCHEMA}")
    for key in ("zig_version", "target", "optimize", "root"):
        need(isinstance(doc[key], str), where, f"bad {key}")
    for f in doc["files"]:
        check_keys(f, where + ".files", ["module", "path"])
    for i, t in enumerate(doc["types"]):
        check_keys(t, where + ".types", ["name", "kind"], ["child", "bits", "signed", "len", "size", "const", "volatile", "allowzero", "fields"])
        need(t["kind"] in TYPE_KINDS, where, f"unknown type kind {t['kind']!r}")
        need("child" not in t or 0 <= t["child"] < i, where, "type child must come first")
        for fl in t.get("fields", []):
            check_keys(fl, where + ".types.fields", ["name", "ty"])
            need(is_int(fl["ty"]) and 0 <= fl["ty"] < len(doc["types"]), where, "field type out of range")
    need(all(isinstance(c, str) for c in doc["callees"]), where, "bad callees")
    ctx = {
        "ntypes": len(doc["types"]), "nfiles": len(doc["files"]), "callees": set(doc["callees"]), "insts": 0,
        "tags": collections.Counter(), "unsupported": collections.Counter(),
    }
    previous = None
    for n, f in enumerate(doc["functions"]):
        w = f"{where}.functions[{n}]"
        check_keys(f, w, ["fqn", "id", "file", "line", "generic_instance", "params", "ret", "unsupported", "callees", "insts"])
        need(isinstance(f["fqn"], str) and re.fullmatch(r"[0-9a-f]{16}", f["id"]), w, "bad fqn/id")
        key = (f["fqn"].encode("utf-8"), f["id"])
        need(previous is None or previous <= key, w, "functions out of order")
        previous = key
        need(0 <= f["file"] < len(doc["files"]) and 0 <= f["ret"] < len(doc["types"]), w, "table reference out of range")
        need(is_int(f["line"]) and isinstance(f["generic_instance"], bool), w, "bad line/generic_instance")
        for p in f["params"]:
            check_keys(p, w + ".params", ["ty", "zir_index"])
            need(0 <= p["ty"] < len(doc["types"]), w, "param type out of range")
        for c in f["callees"]:
            check_keys(c, w + ".callees", ["callee", "inlined"])
            need(0 <= c["callee"] < len(doc["callees"]) and isinstance(c["inlined"], bool), w, "bad callee")
        before = ctx["unsupported"].total()
        check_insts(f["insts"], w + ".insts", ctx)
        need(ctx["unsupported"].total() - before == f["unsupported"], w, "unsupported count mismatch")
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
        total["packs"] += 1
        total["functions"] += len(doc["functions"])
        total["instructions"] += ctx["insts"]
        total["generic_instances"] += sum(f["generic_instance"] for f in doc["functions"])
        tags.update(ctx["tags"])
        unsupported.update(ctx["unsupported"])
        if args.pretty:
            print(dumps(doc, True))
        if args.list:
            for f in doc["functions"]:
                callees = sorted({doc["callees"][c["callee"]] for c in f["callees"]})
                print(f"{f['fqn']}\t{f['id']}\tcalls: {', '.join(callees) or '-'}")

    for f in failures:
        print("FAIL", f, file=sys.stderr)
    if not args.quiet:
        print(f"packs {total['packs']}  functions {total['functions']}  instructions {total['instructions']}  "
              f"generic instances {total['generic_instances']}  distinct tags {len(tags)}  "
              f"unsupported {unsupported.total()} {dict(unsupported) or ''}  "
              f"round-trip {'FAIL' if failures else 'pass'} ({len(failures)} failures)")
    return 1 if failures or total["functions"] == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
