"""Compares air_text output with the hook's schema v1 files, field by field.
usage: compare.py BASE_DIR PARSED_DIR   (functions are matched by fqn)"""
import glob, json, sys, collections

def load(d):
    out = {}
    for f in glob.glob(d + '/*.json'):
        j = json.load(open(f, encoding='utf8'))
        out[j['fqn']] = (f, j)
    return out

def tyname(j, ty):
    return None if ty is None else j['types'][ty]['name']

def tykind(j, ty):
    return None if ty is None else j['types'][ty]['kind']

def operand(j, o):
    if o is None: return None
    if 'inst' in o: return ('i', o['inst'])
    return ('c', tyname(j, o['ty']), o['val'])

def walk(j, insts, acc, prefix=''):
    for i in insts:
        acc[(prefix, i['id'])] = i
        for n, b in enumerate(i.get('bodies', [])):
            walk(j, b['insts'], acc, prefix + '%d.%s/' % (i['id'], b['label']))

def main():
    base, got = load(sys.argv[1]), load(sys.argv[2])
    c = collections.Counter()
    bad = collections.defaultdict(list)
    for fqn, (bf, b) in sorted(base.items()):
        if fqn not in got:
            c['fn_missing'] += 1; bad['fn_missing'].append(fqn); continue
        gf, g = got[fqn]
        c['fn'] += 1
        if open(bf, 'rb').read() == open(gf, 'rb').read(): c['fn_byte_identical'] += 1
        for k in ('fqn', 'line', 'generic_instance', 'unsupported', 'zig_version', 'schema'):
            if b[k] != g[k]: bad['top.' + k].append((fqn, b[k], g[k]))
        if tyname(b, b['ret']) != tyname(g, g['ret']): bad['top.ret'].append((fqn, tyname(b, b['ret']), tyname(g, g['ret'])))
        if b['files'] != g['files']: bad['top.files'].append((fqn, b['files'], g['files']))
        if [(tyname(b, p['ty']), p['zir_index']) for p in b['params']] != [(tyname(g, p['ty']), p['zir_index']) for p in g['params']]:
            bad['top.params'].append(fqn)
        if b['callees'] != g['callees']: bad['top.callees'].append((fqn, b['callees'], g['callees']))
        if [t['name'] for t in b['types']] != [t['name'] for t in g['types']]: bad['types.order'].append(fqn)
        bk = {t['name']: t['kind'] for t in b['types']}
        for t in g['types']:
            c['type_total'] += 1
            if bk.get(t['name']) == t['kind']: c['type_kind_ok'] += 1
            else: bad['types.kind'].append((t['name'], bk.get(t['name']), t['kind']))
        A, B = {}, {}
        walk(b, b['insts'], A); walk(g, g['insts'], B)
        if A.keys() != B.keys(): bad['insts.shape'].append(fqn)
        for key, bi in A.items():
            gi = B.get(key)
            if gi is None: continue
            c['inst'] += 1
            ok = True
            for what, x, y in (
                ('tag', bi['tag'], gi['tag']),
                ('ty', tyname(b, bi.get('ty')), tyname(g, gi.get('ty'))),
                ('operands', [operand(b, o) for o in bi.get('operands', [])], [operand(g, o) for o in gi.get('operands', [])]),
                ('attrs', bi.get('attrs'), gi.get('attrs')),
                ('loc', bi.get('loc'), gi.get('loc')),
                ('bodies', [(x['label'], [operand(b, o) for o in x.get('items', [])], [[operand(b, o) for o in r] for r in x.get('ranges', [])]) for x in bi.get('bodies', [])],
                            [(x['label'], [operand(g, o) for o in x.get('items', [])], [[operand(g, o) for o in r] for r in x.get('ranges', [])]) for x in gi.get('bodies', [])]),
            ):
                if x != y:
                    c['inst_bad.' + what] += 1; ok = False
                    bad['inst.' + what].append((fqn, key, bi['tag'], x, y))
            if ok: c['inst_exact'] += 1
    for k, v in sorted(c.items()): print('%-24s %d' % (k, v))
    print()
    for k, v in sorted(bad.items()):
        print('== %s (%d)' % (k, len(v)))
        for e in v[:int(sys.argv[3]) if len(sys.argv) > 3 else 4]: print('   ', e)

main()
