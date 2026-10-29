#!/usr/bin/env python3
"""Coverage and oracle check for the AIR export (schema v2, JSON form, see docs/phase1.md).

Compares the hook's JSON with the text that the compiler's own printer (`--verbose-air`, a build
with -Ddebug-extensions) writes for the same run: for every exported function, every instruction's
tag, parent body, ordered operands (instruction references and constants), result type of the
instructions that print it, and `dbg_stmt` position must agree. The two come from different code
(the compiler's printer and our adapter), so a decoding mistake in either shows up as a difference.

The printer runs after legalization and liveness, the hook before, so instructions that legalization
rewrites differ by design; those are the pinned ones below and nothing else may differ.

usage: air_oracle.py JSON_DIR_OR_FILE DUMP.txt --functions N --instructions N
"""
import argparse
import collections
import json
import re
import struct
import sys
from pathlib import Path

# Legalization rewrites int_from_float_safe into a range check around int_from_float: the exact
# number of hook instructions it replaces and of instructions it adds.
PINNED_LEGALIZED = {"corpus.casts": (2, 16)}

BEGIN = re.compile(r"^# Begin Function AIR: (.*):$")
INST = re.compile(r"^\s*%(\d+)!?\s*= (\w+)\((.*)$")
HINTS = {"poi", "likely", "unlikely", "cold", "unpredictable"}
NOT_TYPE = ("%", "<", "@.", '"', ".")
CALLS = ("call", "call_always_tail", "call_never_tail", "call_never_inline", "aggregate_init")


def scrub(text):
    """schema.scrub: the compiler-internal ids in generated names are not part of the export."""
    return re.sub(r"__([a-z]+)_[0-9]+(?![A-Za-z0-9_])", r"__\1", text)


def parse_dump(text):
    functions = {}
    current = None
    for line in text.splitlines():
        m = BEGIN.match(line)
        if m:
            current = functions[m.group(1)] = {"insts": {}, "stack": [None], "name": m.group(1)}
            continue
        if current is None:
            continue
        if line.startswith("#"):
            if line.startswith("# End Function AIR:"):
                current = None
            continue
        stack = current["stack"]
        m = INST.match(line)
        if m:
            ident = int(m.group(1))
            opened = line.rstrip().endswith("{")
            current["insts"][ident] = {"tag": m.group(2), "head": m.group(3), "parent": stack[-1], "open": opened}
            if opened:
                stack.append(ident)
            continue
        s = line.strip()
        if s.startswith("}") and not s.endswith("{"):
            stack.pop()
    for name, f in functions.items():
        assert f["stack"] == [None], f"{name}: unbalanced bodies in the dump"
    return functions


def split_args(head, opened):
    """The top-level arguments of an instruction's first line, without the body opener."""
    if opened:
        head = head.rstrip()[:-1]
    args, depth, start, i = [], 0, 0, 0
    while i < len(head):
        c = head[i]
        if c == '"':
            i += 1
            while head[i] != '"':
                i += 2 if head[i] == "\\" else 1
        elif c in "([{<":
            depth += 1
        elif c in ")]}>":
            if c == ">" and head[i - 1] in "=-":
                pass
            elif depth == 0:
                break
            else:
                depth -= 1
        elif c == "," and depth == 0:
            args.append(head[start:i].strip())
            start = i + 1
        i += 1
    args.append(head[start:i].strip())
    return [a for a in args if a]


def is_type(arg):
    if arg.startswith("["):
        return re.match(r"^\[[^\],]*\][a-z*?(\[]", arg) is not None
    return not arg.startswith(NOT_TYPE) and not arg[0].isdigit() and not set(arg.split()) <= HINTS


def dump_operands(tag, inst):
    args = split_args(inst["head"], inst["open"])
    if tag == "dbg_stmt":
        return None, [], tuple(int(x) for x in args[0].split(":"))
    ty = args.pop(0) if args and is_type(args[0]) else None
    operands = []
    for arg in args:
        if "=>" in arg or set(arg.split()) <= HINTS or arg.startswith("else"):
            continue
        if arg.startswith("[") and arg.endswith("]") and tag in CALLS:
            operands += split_args(arg[1:-1] + ")", False)
        else:
            operands.append(arg)
    out = []
    for arg in operands:
        m = re.fullmatch(r"%(\d+)!?", arg)
        if m:
            out.append(("i", int(m.group(1))))
        elif arg.startswith("<") and arg.endswith(">"):
            out.append(("c", arg[1:-1]))
        elif arg.startswith("@."):
            out.append(("c", arg))
        else:
            out.append(("?", arg))
    return ty, out, None


def render_float(bits):
    text = repr(struct.unpack("<d", struct.pack("<Q", int(bits, 16)))[0])
    return text[:-2] if text.endswith(".0") else text


def render_const(doc, op):
    """The constant the way the compiler prints it, from its structured form."""
    kind, val = op["kind"], op.get("val")
    types = doc["types"]
    if kind == "undef":
        return "undefined"
    if kind in ("void",):
        return "{}"
    if kind == "null":
        return "null"
    if kind == "bool":
        return "true" if val else "false"
    if kind == "int":
        return str(val)
    if kind == "float":
        return render_float(val)
    if kind in ("enum_literal", "enum_tag"):
        return "." + val
    if kind == "error":
        return "error." + val
    if kind == "func":
        return f"(function '{val.rsplit('.', 1)[-1]}')"
    if kind == "type":
        return types[val]["name"]
    return val


def hook_operands(doc, inst):
    out = []
    target = inst.get("attrs", {}).get("target")
    if target is not None:
        out.append(("i", target))
    for op in inst.get("operands", []):
        if op is None:
            out.append(("n", None))
        elif "inst" in op:
            out.append(("i", op["inst"]))
        else:
            out.append(("c", f"{doc['types'][op['ty']]['name']}, {render_const(doc, op)}"))
    return out


def flatten(doc):
    flat, parent = {}, {}

    def walk(insts, owner):
        for inst in insts:
            flat[inst["id"]] = inst
            parent[inst["id"]] = owner
            for body in inst.get("bodies", []):
                walk(body["insts"], inst["id"])

    walk(doc["insts"], None)
    return flat, parent


def inline_owner(parent, flat, ident):
    """The innermost dbg_inline_block around an instruction, or None."""
    owner = parent[ident]
    while owner is not None and flat[owner]["tag"] != "dbg_inline_block":
        owner = parent[owner]
    return owner


def compare(doc, dump, problems, stats):
    fqn = doc["fqn"]
    flat, parent = flatten(doc)
    bases = {None: doc["line"]}
    pinned = fqn in PINNED_LEGALIZED
    extra = set(dump["insts"]) - set(flat)
    if pinned:
        stats["pinned_added"] += len(extra)
    elif extra:
        problems.append(f"{fqn}: instructions only in the dump: {sorted(extra)}")
    for ident, inst in flat.items():
        where = f"{fqn} %{ident} {inst['tag']}"
        theirs = dump["insts"].get(ident)
        if theirs is None or theirs["tag"] != inst["tag"]:
            if pinned:
                stats["pinned_changed"] += 1
            else:
                problems.append(f"{where}: dump says {theirs and theirs['tag']}")
            continue
        stats["compared"] += 1
        if parent[ident] != theirs["parent"] and not pinned:
            problems.append(f"{where}: parent {parent[ident]}, dump {theirs['parent']}")
        if inst.get("unsupported"):
            continue
        ty, ops, position = dump_operands(inst["tag"], theirs)
        ops = [(k, scrub(v)) if k == "c" else (k, v) for k, v in ops]
        ty = scrub(ty) if ty else ty
        if position is not None:
            _, line, col = inst["loc"]
            owner = inline_owner(parent, flat, ident)
            base = bases.setdefault(owner, line - position[0] + 1)
            if (line, col) != (base + position[0] - 1, position[1]):
                problems.append(f"{where}: position {line}:{col}, dump {position} on declaration line {base}")
            continue
        mine = hook_operands(doc, inst)
        if inst["tag"] == "dbg_inline_block":
            if ops[0][0] != "c" or not ops[0][1].endswith(f"(function '{inst['attrs']['callee'].rsplit('.', 1)[-1]}')"):
                problems.append(f"{where}: callee {inst['attrs']['callee']}, dump {ops[0]}")
            ops = ops[1:]
        words = [b[1].strip('"') for b in ops if b[0] == "?"]
        ops = [b for b in ops if b[0] != "?"]
        shown = sorted(str(v).lower() for k, v in inst.get("attrs", {}).items() if k not in ("target", "callee"))
        if sorted(w.lower() for w in words) != shown:
            problems.append(f"{where}: attributes {shown}, dump {words}")
        if len(mine) != len(ops) or any(a[0] != b[0] or (a[0] == "i" and a[1] != b[1]) for a, b in zip(mine, ops)):
            problems.append(f"{where}: operands {mine}, dump {ops}")
        else:
            for a, b in zip(mine, ops):
                if a[0] != "c":
                    continue
                stats["constants"] += 1
                if not b[1].startswith("@.") and a[1] != b[1]:
                    problems.append(f"{where}: constant {a[1]!r}, dump {b[1]!r}")
        if ty is not None:
            stats["types"] += 1
            if doc["types"][inst["ty"]]["name"] != ty:
                problems.append(f"{where}: type {doc['types'][inst['ty']]['name']!r}, dump {ty!r}")


def check_pinned(fqn, changed, added, problems):
    if (changed, added) != PINNED_LEGALIZED[fqn]:
        problems.append(f"{fqn}: legalization changed {changed} and added {added}, pinned {PINNED_LEGALIZED[fqn]}")


def load_docs(path):
    """One document per function, with the pack's tables alongside, from a JSON file or a directory."""
    docs = []
    for file in sorted(path.rglob("*.json")) if path.is_dir() else [path]:
        pack = json.loads(file.read_text(encoding="utf-8"))
        for function in pack["functions"]:
            docs.append({**function, "types": pack["types"], "callees": pack["callees"], "files": pack["files"]})
    return docs


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("json_dir", help="a pack as JSON, or a directory of them")
    ap.add_argument("dump")
    ap.add_argument("--functions", type=int, required=True)
    ap.add_argument("--instructions", type=int, required=True)
    args = ap.parse_args()

    docs = load_docs(Path(args.json_dir))
    dumps = parse_dump(Path(args.dump).read_text(encoding="utf-8", errors="replace"))
    by_name = collections.defaultdict(list)
    for dump in dumps.values():
        by_name[scrub(dump["name"])].append(dump)
    used = set()
    problems = []
    stats = collections.Counter()
    for doc in docs:
        flat, _ = flatten(doc)
        stats["instructions"] += len(flat)
        stats["unsupported"] += doc["unsupported"]
        # Generic instances share a name once the compiler's ids are hidden: take the dump that agrees.
        best = None
        for dump in (d for d in by_name.get(doc["fqn"], []) if d["name"] not in used):
            trial = (dump, collections.Counter(), [])
            compare(doc, dump, trial[2], trial[1])
            best = best or trial
            if not trial[2]:
                best = trial
                break
        if best is None:
            problems.append(f"{doc['fqn']}: the compiler printed no AIR for it")
            continue
        dump, trial_stats, trial_problems = best
        used.add(dump["name"])
        stats.update(trial_stats)
        problems.extend(trial_problems)
        if doc["fqn"] in PINNED_LEGALIZED:
            check_pinned(doc["fqn"], trial_stats["pinned_changed"], trial_stats["pinned_added"], problems)
    if len(docs) != args.functions:
        problems.append(f"functions: {len(docs)}, expected {args.functions}")
    if stats["instructions"] != args.instructions:
        problems.append(f"instructions: {stats['instructions']}, expected {args.instructions}")
    if stats["unsupported"]:
        problems.append(f"unsupported instructions: {stats['unsupported']}")
    for p in problems:
        print("FAIL", p, file=sys.stderr)
    print(f"functions {len(docs)}  instructions {stats['instructions']}  unsupported {stats['unsupported']}  "
          f"compared {stats['compared']}  constants {stats['constants']}  types {stats['types']}  "
          f"legalized (pinned) {stats['pinned_changed']} changed {stats['pinned_added']} added  "
          f"oracle {'FAIL' if problems else 'pass'} ({len(problems)} differences)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
