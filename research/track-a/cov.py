import json, sys, glob, hashlib

d = sys.argv[1]
files = sorted(glob.glob(d + '/*.json'))


def count(insts):
    n = 0
    for i in insts:
        n += 1
        for b in i.get('bodies', []):
            n += count(b['insts'])
    return n


tot = uns = 0
h = hashlib.sha256()
for f in files:
    j = json.load(open(f))
    tot += count(j['insts'])
    uns += j['unsupported']
    h.update(open(f, 'rb').read())
print(f'{len(files)} functions, {tot} instructions, {uns} unsupported, sha256(all files in name order)={h.hexdigest()[:16]}')
