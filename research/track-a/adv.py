import os, re, shutil, subprocess, sys
W = 'C:/Users/hotschmoe/zr/a-work'
HOOK = W + '/bin/zv_hook_new.exe'
R = 'C:/Users/hotschmoe/zr/wt-a/compiler/hook'
BASE = 'C:/Users/hotschmoe/Documents/GitHub/zig-0.17/src'
PT = 'Zcu/PerThread.zig'; CO = 'Compilation.zig'


def rd(p): return open(p, newline='').read().replace('\r\n', '\n')
def wr(p, s): open(p, 'w', newline='').write(s)


def make(name, edits):
    d = f'{W}/adv/{name}'
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(BASE, d + '/src')
    for rel, fn in edits:
        p = d + '/src/' + rel
        wr(p, fn(rd(p)))
    return d


CALL = 'var air = try pt.analyzeFuncBodyInner(func_index, reason);'
SIG = '(pt: Zcu.PerThread, func_index: InternPool.Index, reason: ?*const Zcu.DependencyReason) !Air {'


def decoy(s):
    lines = s.split('\n')
    i = next(k for k, l in enumerate(lines) if l.startswith('fn analyzeFuncBody('))
    body = ['fn analyzeFuncBodyTraced' + SIG, '    const gpa = pt.zcu.gpa;'] + ['    _ = pt;'] * 28 + \
        ['    ' + CALL, '    var air_owned = true;', '    defer if (air_owned) air.deinit(gpa);', '    return air;', '}', '']
    return '\n'.join(lines[:i] + body + lines[i:])


def extract(s):
    return s.replace('    ' + CALL, '    var air = try pt.analyzeFuncBodyHelper(func_index, reason);', 1) + \
        '\nfn analyzeFuncBodyHelper' + SIG + '\n    ' + CALL + '\n    return air;\n}\n'


def wrapper(s):
    return s.replace('    ' + CALL, '    var air = try pt.analyzeFuncBodyWrapped(func_index, reason);', 1) + \
        '\nfn analyzeFuncBodyWrapped' + SIG + '\n    return pt.analyzeFuncBodyInner(func_index, reason);\n}\n'


def rename_fn(s): return s.replace('analyzeFuncBody(', 'analyzeFuncBodyImpl(')


def rename_var(s):
    i = s.index(CALL)
    j = s.index('\n    const old_air', i) if '\n    const old_air' in s[i:i+2000] else i + 600
    seg = s[i:j]
    seg = seg.replace('var air ', 'var func_air ').replace(' air.', ' func_air.').replace('(&air', '(&func_air').replace(' air;', ' func_air;')
    return s[:i] + seg + s[j:]


def cache_nested(s):
    return s.replace('        man.hash.add(zcu.error_limit);', '        if (comp.incremental) {\n            man.hash.add(zcu.error_limit);\n        }', 1)


def bypass(s):
    return s + '\nfn analyzeFuncBodyBatch' + SIG + '\n    return pt.analyzeFuncBodyInner(func_index, reason);\n}\n'


cases = {
    'decoy': [(PT, decoy)], 'extract': [(PT, extract)], 'wrapper': [(PT, wrapper)],
    'rename_fn': [(PT, rename_fn)], 'rename_var': [(PT, rename_var)],
    'cache_nested': [(CO, cache_nested)], 'bypass': [(PT, bypass)],
}


def enclosing(src, lineno):
    L = src.split('\n')
    for k in range(lineno - 1, -1, -1):
        m = re.match(r'(?:pub )?(?:inline )?fn (\w+)', L[k])
        if m: return m.group(1)
    return '?'


def where(d, rel, needle):
    src = rd(d + '/src/' + rel)
    for k, l in enumerate(src.split('\n')):
        if needle in l:
            return f'{rel.split("/")[-1]}:{k+1} in {enclosing(src, k+1)}'
    return 'absent'


def git(d, *a):
    return subprocess.run(['git', '-c', 'core.safecrlf=false', *a], cwd=d, capture_output=True, text=True)


def run_mech(d, mech):
    git(d, 'init', '-q'); git(d, 'add', '-A')
    git(d, '-c', 'user.name=a', '-c', 'user.email=a@a', 'commit', '-qm', 'b')
    if mech == 'patch':
        r = git(d, 'apply', '--whitespace=nowarn', W + '/cur.patch')
        out = (r.stderr.strip().splitlines() or ['applied'])[0]
        return ('FAIL(loud): ' + out) if r.returncode else 'applied silently'
    r = subprocess.run([HOOK, 'apply', f'{R}/{mech}.zon', '.'], cwd=d, capture_output=True, text=True)
    res = ('FAIL(loud): ' + (r.stderr.strip().splitlines() or [''])[0][:160]) if r.returncode else 'applied'
    w = [l for l in r.stderr.splitlines() if l.startswith('warning')]
    if w: res += ' WITH WARNING: ' + w[0][:150]
    return res


if __name__ == '__main__':
    names = sys.argv[1:] or list(cases)
    for n in names:
        print(f'### {n}')
        for mech in ['patch', 'full.text', 'full.ast', 'min.text', 'min.ast', 'rules']:
            d = make(n, cases[n])
            res = run_mech(d, mech)
            loc = ''
            if not res.startswith('FAIL'):
                h = 'zv_air_options.hash' if mech in ('patch', 'full.text', 'full.ast') else ('hashCache' if mech == 'rules' else 'hashEnv')
                loc = ' | call: ' + where(d, PT, 'exportFunc(pt') + ' | hash: ' + where(d, CO, h)
            print(f'  {mech:10} {res}{loc}')
