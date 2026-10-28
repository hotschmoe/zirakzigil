#!/usr/bin/env python3
"""zvc — a spike of the Zirakzigil static verifier.

Reads an ordinary Zig source file, finds every function its assurance manifest
marks `.verified`, and proves with Z3 (bit-precise, Zig semantics):

  * every `zv.ensures` postcondition, given the `zv.requires` preconditions
  * every loop invariant: holds on entry, preserved by each iteration
  * absence of the panics Zig inserts in safe builds: integer overflow on
    + - *, division by zero, and out-of-bounds slice indexing

The production design does this on Zig AIR (after comptime, monomorphized);
this spike parses a small subset of Zig source directly so it runs against the
stock compiler today. Anything outside the subset is reported as unproven,
never silently accepted.

usage: zvc.py FILE.zig [--only NAME] [--smt]
"""
import re
import sys
from dataclasses import dataclass, field

import z3

# ── types ────────────────────────────────────────────────────────────────────

INT_TYPES = {
    "u8": (8, False), "u16": (16, False), "u32": (32, False), "u64": (64, False),
    "usize": (64, False), "i8": (8, True), "i16": (16, True), "i32": (32, True),
    "i64": (64, True), "isize": (64, True),
}


@dataclass(frozen=True)
class Ty:
    kind: str  # int | bool | slice | cint
    bits: int = 0
    signed: bool = False
    elem: "Ty | None" = None

    def __str__(self):
        if self.kind == "int":
            return ("i" if self.signed else "u") + str(self.bits)
        if self.kind == "slice":
            return f"[]const {self.elem}"
        return self.kind


USIZE = Ty("int", 64, False)
BOOL = Ty("bool")
CINT = Ty("cint")


class Unsupported(Exception):
    pass


# ── lexer ────────────────────────────────────────────────────────────────────

TOKEN = re.compile(r"""
    (?P<ws>\s+|//[^\n]*)
  | (?P<num>\d[\d_]*)
  | (?P<id>@?[A-Za-z_]\w*)
  | (?P<op>\+=|-=|\*=|==|!=|<=|>=|\.\{|[(){}\[\],;:.=<>+\-*/%!])
""", re.X)


@dataclass
class Tok:
    kind: str
    text: str
    line: int


def lex(src):
    toks, pos, line = [], 0, 1
    while pos < len(src):
        m = TOKEN.match(src, pos)
        if not m:
            toks.append(Tok("other", src[pos], line))
            pos += 1
            continue
        txt = m.group(0)
        if m.lastgroup != "ws":
            toks.append(Tok(m.lastgroup, txt, line))
        line += txt.count("\n")
        pos = m.end()
    toks.append(Tok("eof", "", line))
    return toks


# ── parser (subset) ──────────────────────────────────────────────────────────

class Parser:
    def __init__(self, toks):
        self.t, self.i = toks, 0

    def peek(self, k=0):
        return self.t[self.i + k]

    def next(self):
        tok = self.t[self.i]
        self.i += 1
        return tok

    def accept(self, text):
        if self.peek().text == text:
            return self.next()
        return None

    def expect(self, text):
        tok = self.next()
        if tok.text != text:
            raise Unsupported(f"line {tok.line}: expected '{text}', found '{tok.text}'")
        return tok

    # types
    def ty(self):
        if self.accept("["):
            self.expect("]")
            self.expect("const")
            return Ty("slice", elem=self.ty())
        tok = self.next()
        if tok.text in INT_TYPES:
            b, s = INT_TYPES[tok.text]
            return Ty("int", b, s)
        if tok.text == "bool":
            return BOOL
        raise Unsupported(f"line {tok.line}: type '{tok.text}' outside zvc subset")

    # functions
    def fn(self):
        self.expect("pub"), self.expect("fn")
        name = self.next().text
        self.expect("(")
        params = []
        while not self.accept(")"):
            pname = self.next().text
            self.expect(":")
            params.append((pname, self.ty()))
            self.accept(",")
        ret = self.ty()
        return name, params, ret, self.block()

    def block(self):
        self.expect("{")
        out = []
        while not self.accept("}"):
            out.append(self.stmt())
        return out

    def stmt(self):
        tok = self.peek()
        line = tok.line
        if tok.text == "zv" and self.peek(1).text == ".":
            self.next(), self.next()
            what = self.next().text
            if what not in ("requires", "invariant", "assume"):
                raise Unsupported(f"line {line}: zv.{what} as a statement")
            self.expect("(")
            e = self.expr()
            self.expect(")"), self.expect(";")
            return (what, e, line)
        if tok.text in ("const", "var"):
            self.next()
            name = self.next().text
            ty = self.ty() if self.accept(":") else None
            self.expect("=")
            e = self.expr()
            self.expect(";")
            return ("decl", name, ty, e, line)
        if tok.text == "if":
            self.next(), self.expect("(")
            c = self.expr()
            self.expect(")")
            then = self.block()
            els = []
            if self.accept("else"):
                els = [self.stmt()] if self.peek().text == "if" else self.block()
            return ("if", c, then, els, line)
        if tok.text == "while":
            self.next(), self.expect("(")
            c = self.expr()
            self.expect(")")
            cont = None
            if self.accept(":"):
                self.expect("(")
                cont = self.assign_stmt(require_semicolon=False)
                self.expect(")")
            return ("while", c, cont, self.block(), line)
        if tok.text == "return":
            self.next()
            e = self.expr()
            self.expect(";")
            return ("return", e, line)
        if tok.text == "{":
            return ("block", self.block(), line)
        if tok.kind == "id" and self.peek(1).text in ("=", "+=", "-=", "*="):
            return self.assign_stmt()
        raise Unsupported(f"line {line}: statement starting with '{tok.text}' outside zvc subset")

    def assign_stmt(self, require_semicolon=True):
        tok = self.next()
        op = self.next().text
        e = self.expr()
        if op != "=":
            e = ("bin", op[0], ("var", tok.text, tok.line), e, tok.line)
        if require_semicolon:
            self.expect(";")
        return ("assign", tok.text, e, tok.line)

    # expressions, Zig precedence: or < and < comparison < +,- < *,/,% < prefix < postfix
    def expr(self):
        return self.binary(0)

    LEVELS = [("or",), ("and",), ("==", "!=", "<", ">", "<=", ">="), ("+", "-"), ("*", "/", "%")]

    def binary(self, lvl):
        if lvl == len(self.LEVELS):
            return self.unary()
        lhs = self.binary(lvl + 1)
        while self.peek().text in self.LEVELS[lvl]:
            op = self.next()
            rhs = self.binary(lvl + 1)
            lhs = ("bin", op.text, lhs, rhs, op.line)
            if lvl == 2:  # Zig comparisons do not chain
                break
        return lhs

    def unary(self):
        tok = self.peek()
        if tok.text == "!":
            self.next()
            return ("not", self.unary(), tok.line)
        return self.postfix(self.primary())

    def postfix(self, e):
        while True:
            if self.accept("["):
                idx = self.expr()
                self.expect("]")
                e = ("index", e, idx, self.peek().line)
            elif self.peek().text == "." and self.peek(1).text == "len":
                self.next(), self.next()
                e = ("len", e, self.peek().line)
            else:
                return e

    def primary(self):
        tok = self.next()
        if tok.kind == "num":
            return ("lit", int(tok.text.replace("_", "")), tok.line)
        if tok.text in ("true", "false"):
            return ("blit", tok.text == "true", tok.line)
        if tok.text == "(":
            e = self.expr()
            self.expect(")")
            return e
        if tok.text == "@as":
            self.expect("(")
            ty = self.ty()
            self.expect(",")
            e = self.expr()
            self.expect(")")
            return ("as", ty, e, tok.line)
        if tok.text == "zv" and self.peek().text == ".":
            self.next()
            what = self.next().text
            if what != "ensures":
                raise Unsupported(f"line {tok.line}: zv.{what} in an expression")
            self.expect("(")
            v = self.expr()
            self.expect(",")
            p = self.expr()
            self.expect(")")
            return ("ensures", v, p, tok.line)
        if tok.kind == "id":
            if self.peek().text == "(":
                raise Unsupported(f"line {tok.line}: call to '{tok.text}' (callee contracts not yet modular in the spike)")
            return ("var", tok.text, tok.line)
        raise Unsupported(f"line {tok.line}: expression '{tok.text}' outside zvc subset")


# ── symbolic execution ───────────────────────────────────────────────────────

@dataclass
class Val:
    ty: Ty
    z: object  # z3 expr, or python int for cint


@dataclass
class State:
    env: dict
    pc: list = field(default_factory=list)

    def fork(self, *extra):
        return State(dict(self.env), self.pc + list(extra))


@dataclass
class Obligation:
    kind: str
    line: int
    ok: bool
    detail: str = ""


class Verifier:
    def __init__(self, name, params, ret, body, smt=False):
        self.name, self.params, self.ret, self.body = name, params, ret, body
        self.obligations = []
        self.inputs = {}
        self.smt = smt
        self.fresh = 0

    # helpers
    def mk(self, name, ty):
        self.fresh += 1
        tag = f"{name}!{self.fresh}"
        if ty.kind == "int":
            return z3.BitVec(tag, ty.bits)
        if ty.kind == "bool":
            return z3.Bool(tag)
        if ty.kind == "slice":
            return (z3.BitVec(tag + ".len", 64), z3.Array(tag + ".mem", z3.BitVecSort(64), z3.BitVecSort(ty.elem.bits)))
        raise Unsupported(f"cannot model {ty}")

    def oblige(self, st, goal, kind, line):
        s = z3.Solver()
        s.set("timeout", 10_000)
        s.add(*st.pc)
        s.add(z3.Not(goal))
        if self.smt:
            print(f";; obligation {kind} @ line {line}\n{s.sexpr()}")
        r = s.check()
        if r == z3.unsat:
            self.obligations.append(Obligation(kind, line, True))
            return
        detail = "solver timeout" if r == z3.unknown else self.counterexample(s.model())
        self.obligations.append(Obligation(kind, line, False, detail))

    def counterexample(self, m):
        parts = []
        for pname, (ty, z) in self.inputs.items():
            if ty.kind == "slice":
                parts.append(f"{pname}.len={m.eval(z[0], model_completion=True).as_long()}")
            elif ty.kind == "int":
                v = m.eval(z, model_completion=True).as_long()
                if ty.signed and v >= 1 << (ty.bits - 1):
                    v -= 1 << ty.bits
                parts.append(f"{pname}={v}")
            else:
                parts.append(f"{pname}={m.eval(z, model_completion=True)}")
        return ", ".join(parts)

    def coerce(self, v, ty, st, line):
        if v.ty == ty:
            return v
        if v.ty.kind == "cint" and ty.kind == "int":
            lo = -(1 << (ty.bits - 1)) if ty.signed else 0
            hi = (1 << (ty.bits - 1)) - 1 if ty.signed else (1 << ty.bits) - 1
            if not lo <= v.z <= hi:
                raise Unsupported(f"line {line}: literal {v.z} does not fit {ty} (Zig compile error)")
            return Val(ty, z3.BitVecVal(v.z, ty.bits))
        if v.ty.kind == "cint" and ty.kind == "cint":
            return v
        raise Unsupported(f"line {line}: implicit coercion {v.ty} -> {ty}")

    def peer(self, a, b, st, line):
        if a.ty.kind == "cint" and b.ty.kind == "cint":
            return a, b, CINT
        if a.ty.kind == "cint":
            return self.coerce(a, b.ty, st, line), b, b.ty
        if b.ty.kind == "cint":
            return a, self.coerce(b, a.ty, st, line), a.ty
        if a.ty != b.ty:
            raise Unsupported(f"line {line}: mixed operand types {a.ty} and {b.ty}")
        return a, b, a.ty

    # expressions
    def ev(self, e, st):
        tag = e[0]
        if tag == "lit":
            return Val(CINT, e[1])
        if tag == "blit":
            return Val(BOOL, z3.BoolVal(e[1]))
        if tag == "var":
            if e[1] not in st.env:
                raise Unsupported(f"line {e[2]}: unknown name '{e[1]}'")
            return st.env[e[1]]
        if tag == "not":
            v = self.ev(e[1], st)
            return Val(BOOL, z3.Not(v.z))
        if tag == "len":
            s = self.ev(e[1], st)
            if s.ty.kind != "slice":
                raise Unsupported(f"line {e[2]}: .len on non-slice")
            return Val(USIZE, s.z[0])
        if tag == "index":
            s = self.ev(e[1], st)
            i = self.coerce(self.ev(e[2], st), USIZE, st, e[3])
            self.oblige(st, z3.ULT(i.z, s.z[0]), "index in bounds", e[3])
            return Val(s.ty.elem, z3.Select(s.z[1], i.z))
        if tag == "as":
            ty, v = e[1], self.ev(e[2], st)
            if v.ty.kind == "cint":
                return self.coerce(v, ty, st, e[3])
            if v.ty.kind != "int" or ty.kind != "int" or ty.bits < v.ty.bits or (v.ty.signed and not ty.signed):
                raise Unsupported(f"line {e[3]}: @as({ty}, {v.ty}) is not a widening")
            ext = z3.SignExt if v.ty.signed else z3.ZeroExt
            return Val(ty, ext(ty.bits - v.ty.bits, v.z) if ty.bits > v.ty.bits else v.z)
        if tag == "bin":
            return self.binop(e, st)
        raise Unsupported(f"expression {tag}")

    def binop(self, e, st):
        _, op, le, re_, line = e
        if op in ("and", "or"):
            a = self.ev(le, st)
            # short-circuit: the right side is only evaluated when it matters
            b = self.ev(re_, st.fork(a.z if op == "and" else z3.Not(a.z)))
            return Val(BOOL, (z3.And if op == "and" else z3.Or)(a.z, b.z))
        a, b, ty = self.peer(self.ev(le, st), self.ev(re_, st), st, line)
        if ty.kind == "cint":
            py = {"+": lambda x, y: x + y, "-": lambda x, y: x - y, "*": lambda x, y: x * y,
                  "/": lambda x, y: x // y, "%": lambda x, y: x % y, "==": lambda x, y: x == y,
                  "!=": lambda x, y: x != y, "<": lambda x, y: x < y, ">": lambda x, y: x > y,
                  "<=": lambda x, y: x <= y, ">=": lambda x, y: x >= y}[op](a.z, b.z)
            return Val(BOOL, z3.BoolVal(py)) if isinstance(py, bool) else Val(CINT, py)
        x, y, s = a.z, b.z, ty.signed
        if op in ("==", "!="):
            return Val(BOOL, x == y if op == "==" else x != y)
        if op in ("<", ">", "<=", ">="):
            fn = {"<": (z3.ULT, lambda p, q: p < q), ">": (z3.UGT, lambda p, q: p > q),
                  "<=": (z3.ULE, lambda p, q: p <= q), ">=": (z3.UGE, lambda p, q: p >= q)}[op]
            return Val(BOOL, fn[1](x, y) if s else fn[0](x, y))
        if ty.kind != "int":
            raise Unsupported(f"line {line}: arithmetic on {ty}")
        if op == "+":
            self.oblige(st, z3.And(z3.BVAddNoOverflow(x, y, s), z3.BVAddNoUnderflow(x, y)), f"no overflow in + ({ty})", line)
            return Val(ty, x + y)
        if op == "-":
            ok = z3.And(z3.BVSubNoOverflow(x, y), z3.BVSubNoUnderflow(x, y, True)) if s else z3.UGE(x, y)
            self.oblige(st, ok, f"no overflow in - ({ty})", line)
            return Val(ty, x - y)
        if op == "*":
            self.oblige(st, z3.And(z3.BVMulNoOverflow(x, y, s), z3.BVMulNoUnderflow(x, y) if s else z3.BoolVal(True)), f"no overflow in * ({ty})", line)
            return Val(ty, x * y)
        if op in ("/", "%"):
            if s:
                raise Unsupported(f"line {line}: signed '{op}' (Zig requires @divTrunc/@rem)")
            self.oblige(st, y != 0, f"no division by zero ({op})", line)
            return Val(ty, z3.UDiv(x, y) if op == "/" else z3.URem(x, y))
        raise Unsupported(f"line {line}: operator {op}")

    # statements
    def assigned(self, stmts, out=None):
        out = set() if out is None else out
        for s in stmts:
            if s[0] == "assign":
                out.add(s[1])
            elif s[0] == "if":
                self.assigned(s[2], out), self.assigned(s[3], out)
            elif s[0] == "while":
                self.assigned(s[3], out)
                if s[2]:
                    out.add(s[2][1])
            elif s[0] == "block":
                self.assigned(s[1], out)
        return out

    def havoc(self, st, names):
        st = st.fork()
        for n in names:
            v = st.env[n]
            st.env[n] = Val(v.ty, self.mk(n, v.ty))
        return st

    def run(self, stmts, st):
        for k, s in enumerate(stmts):
            tag, line = s[0], s[-1]
            if tag == "requires":
                if any(x[0] not in ("requires",) for x in stmts[:k]) or st is not self.entry:
                    raise Unsupported(f"line {line}: zv.requires must open the function body")
                st.pc.append(self.ev(s[1], st).z)
            elif tag == "assume":
                st.pc.append(self.ev(s[1], st).z)
            elif tag == "invariant":
                raise Unsupported(f"line {line}: zv.invariant must be the first statement of a loop body")
            elif tag == "decl":
                v = self.ev(s[3], st)
                if s[2] is not None:
                    v = self.coerce(v, s[2], st, line)
                elif v.ty.kind == "cint":
                    raise Unsupported(f"line {line}: untyped integer constant (give it a type)")
                st.env[s[1]] = v
            elif tag == "assign":
                cur = st.env.get(s[1])
                if cur is None:
                    raise Unsupported(f"line {line}: assignment to unknown '{s[1]}'")
                st.env[s[1]] = self.coerce(self.ev(s[2], st), cur.ty, st, line)
            elif tag == "block":
                return self.run(s[1] + stmts[k + 1:], st)
            elif tag == "if":
                c = self.ev(s[1], st)
                self.run(s[2] + stmts[k + 1:], st.fork(c.z))
                self.run(s[3] + stmts[k + 1:], st.fork(z3.Not(c.z)))
                return
            elif tag == "while":
                return self.loop(s, stmts[k + 1:], st)
            elif tag == "check_inv":
                if s[1] is not None:
                    self.run([s[1]], st)
                self.oblige(st, self.ev(s[2], st).z, "loop invariant preserved", s[3])
                return
            elif tag == "return":
                e = s[1]
                if e[0] == "ensures":
                    v = self.coerce(self.ev(e[1], st), self.ret, st, line)
                    self.oblige(st, self.ev(e[2], st).z, "postcondition (zv.ensures)", line)
                else:
                    self.coerce(self.ev(e, st), self.ret, st, line)
                return
            else:
                raise Unsupported(f"line {line}: {tag}")

    def loop(self, s, rest, st):
        _, cond, cont, body, line = s
        invs = []
        while body and body[0][0] == "invariant":
            invs.append(body[0][1])
            body = body[1:]
        inv = invs[0] if invs else ("blit", True, line)
        for extra in invs[1:]:
            inv = ("bin", "and", inv, extra, line)
        self.oblige(st, self.ev(inv, st).z, "loop invariant holds on entry", line)
        changed = self.assigned(body) | ({cont[1]} if cont else set())
        # one arbitrary iteration
        it = self.havoc(st, changed)
        it.pc.append(self.ev(inv, it).z)
        it.pc.append(self.ev(cond, it).z)
        self.run(body + [("check_inv", cont, inv, line)], it)
        # after the loop
        ex = self.havoc(st, changed)
        ex.pc.append(self.ev(inv, ex).z)
        ex.pc.append(z3.Not(self.ev(cond, ex).z))
        self.run(rest, ex)

    def verify(self):
        st = State({})
        for pname, ty in self.params:
            z = self.mk(pname, ty)
            st.env[pname] = Val(ty, z)
            self.inputs[pname] = (ty, z)
        self.entry = st
        self.run(self.body, st)
        return self.obligations


# ── driver ───────────────────────────────────────────────────────────────────

def manifest(src):
    m = re.search(r"pub const assurance\s*=\s*\.\{(.*?)\};", src, re.S)
    if not m:
        return {}
    body = re.sub(r"//[^\n]*", "", m.group(1))
    return dict(re.findall(r"\.(\w+)\s*=\s*\.(\w+)", body))


def find_fn(toks, name):
    for i, t in enumerate(toks):
        if t.text == "pub" and toks[i + 1].text == "fn" and toks[i + 2].text == name:
            return i
    return None


def main():
    args = sys.argv[1:]
    path = args[0]
    only = args[args.index("--only") + 1] if "--only" in args else None
    smt = "--smt" in args
    src = open(path).read()
    toks = lex(src)
    levels = manifest(src)
    targets = [n for n, lvl in levels.items() if lvl == "verified" and (only is None or n == only)]
    print(f"zvc: {path}: {len(targets)} function(s) marked .verified\n")
    failed = 0
    for name in targets:
        i = find_fn(toks, name)
        if i is None:
            print(f"  ✗ {name}: declared .verified but no such pub fn")
            failed += 1
            continue
        try:
            p = Parser(toks)
            p.i = i
            fname, params, ret, body = p.fn()
            obs = Verifier(fname, params, ret, body, smt).verify()
        except Unsupported as ex:
            print(f"  ✗ {name}: UNPROVEN — {ex}")
            failed += 1
            continue
        bad = [o for o in obs if not o.ok]
        if not bad:
            kinds = sorted({o.kind.split(" (")[0] for o in obs})
            print(f"  ✓ {name}: VERIFIED — {len(obs)} obligations ({', '.join(kinds)})")
        else:
            failed += 1
            print(f"  ✗ {name}: REJECTED — {len(bad)} of {len(obs)} obligations fail")
            seen = set()
            for o in bad:
                key = (o.kind, o.line)
                if key in seen:
                    continue
                seen.add(key)
                print(f"      line {o.line}: {o.kind}\n        counterexample: {o.detail}")
    print(f"\nzvc: {len(targets) - failed} verified, {failed} rejected or unproven")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
