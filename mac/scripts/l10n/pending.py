#!/usr/bin/env python3
"""Literales en español del código que NO están en l10n/en.xliff (lo que el compilador no ve como localizable).
Uso: python3 scripts/l10n/pending.py [--by-context] [--files]"""
import re, sys, xml.etree.ElementTree as ET, collections, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent)); from swiftlit import literals
root = pathlib.Path(__file__).resolve().parents[2]
ns = {'x': 'urn:oasis:names:tc:xliff:document:1.2'}
keys = {u.find('x:source', ns).text for u in ET.parse(root/'l10n/en.xliff').getroot().findall('.//x:trans-unit', ns)}
lit = re.compile(r'"((?:[^"\\]|\\.)*)"')
spanish = re.compile(r'[a-záéíóúñ]{3,}', re.I)
def key_of(s):
    s = re.sub(r'\\\((?:[^()]|\([^()]*\))*\)', '%@', s)   # \(x) → %@ (aprox.)
    return s.replace('\\"', '"')
skip_prefix = ('http', '/', '-', '#', 'com.', 'space.', 'cache/', 'media/', 'broll/', 'exports', 'estudio.', 'proxy', 'application/')
pending = []
for f in sorted((root/'Sources').rglob('*.swift')):
    if 'StudioTests' in f.name or 'SelfTest' in f.name: continue
    for ln, line in enumerate(f.read_text().splitlines(), 1):
        st = line.strip()
        if st.startswith('//') or st.startswith('///'): continue
        for a, z, s in literals(line):
            plain = re.sub(r'\\\((?:[^()]|\([^()]*\))*\)', '', s)
            if not spanish.search(plain) or s.startswith(skip_prefix) or len(plain.strip()) < 4: continue
            if re.fullmatch(r'[\w\-.]+', plain): continue          # identificadores, claves, nombres de archivo
            k = key_of(s)
            if k in keys or k.replace('%@', '%lld') in keys or re.sub(r'%(lld|@|\.\df|d)', '%', k) in {re.sub(r'%(lld|@|\.\df|d)', '%', x) for x in keys}: continue
            before = line[:a].rstrip()[-28:]
            ctx = re.findall(r'(\w+|\.\w+)\s*\($', before) or re.findall(r'(\w+)\s*[=:+]\s*$', before) or ['?']
            pending.append((str(f.relative_to(root)), ln, ctx[-1], s))
if '--by-context' in sys.argv:
    c = collections.Counter(p[2] for p in pending)
    for k, n in c.most_common(40): print(f'{n:5d}  {k}')
elif '--files' in sys.argv:
    c = collections.Counter(p[0] for p in pending)
    for k, n in c.most_common(): print(f'{n:5d}  {k}')
else:
    for p in pending: print(f'{p[0]}:{p[1]} [{p[2]}] {p[3][:90]}')
print(f'\n{len(pending)} literales pendientes · {len(keys)} claves en el xliff', file=sys.stderr)
