#!/usr/bin/env python3
"""Spanish literals in the code that are NOT in l10n/en.xliff (what the compiler doesn't see as localizable).
Usage: python3 scripts/l10n/pending.py [--by-context] [--files]"""
import re, sys, xml.etree.ElementTree as ET, collections, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent)); from swiftlit import literals, key_regex, multiline_spans, split_interp
root = pathlib.Path(__file__).resolve().parents[2]
ns = {'x': 'urn:oasis:names:tc:xliff:document:1.2'}
keys = {u.find('x:source', ns).text for u in ET.parse(root/'l10n/en.xliff').getroot().findall('.//x:trans-unit', ns)}
keys_by_len = collections.defaultdict(list)
for k in keys: keys_by_len[len(k or '')].append(k or '')
def in_xliff(s):
    rx = key_regex(s)
    return any(rx.match(k) for ks in keys_by_len.values() for k in ks)
lit = re.compile(r'"((?:[^"\\]|\\.)*)"')
spanish = re.compile(r'[a-záéíóúñ]{3,}', re.I)
def key_of(s):
    s = re.sub(r'\\\((?:[^()]|\([^()]*\))*\)', '%@', s)   # \(x) → %@ (approx.)
    return s.replace('\\"', '"')
def technical(s, plain):
    """ffmpeg filters, SQL, headers, SRT/VTT, paths and ids: not UI text."""
    if re.search(r'^[\w,\[\]+]*=', plain) and ' ' not in plain.strip(): return True
    if re.match(r'(SELECT |PRAGMA |INSERT |UPDATE |CREATE |DELETE |;FFMETADATA|\[CHAPTER\]|Content-Type|Stream #|Duration: |Error opening input|time=|lyrics=|title=|artist=|language=|multipart/|nohup |sleep |WEBVTT|\[composite_|postPod·thePod|\+faststart|\+genpts|,alimiter|,volume=|highpass=|rtmps?://|mailto:|x-apple\.|bytes=|note:)', s): return True
    if '-->' in s or re.fullmatch(r'%[.\d]*f [A-Za-z]+', s): return True
    if len(''.join(split_interp(s)).strip()) <= 1: return True
    if re.fullmatch(r'[\w\-./%]*/[\w\-./%]*', plain) or re.fullmatch(r'[\w\-.]*\.(mp4|png|json|log|app|dmg|part)', plain): return True   # paths
    return False
skip_prefix = ('http', '/', '-', '#', 'com.', 'space.', 'cache/', 'media/', 'broll/', 'exports', 'estudio.', 'proxy', 'application/')
pending = []
for f in sorted((root/'Sources').rglob('*.swift')):
    if 'StudioTests' in f.name or 'SelfTest' in f.name or f.name == 'SensitiveWords.swift': continue   # dictionary in the transcript's language
    src = f.read_text(); ml = multiline_spans(src)   # what's inside """ """ (scripts, prompts) isn't code
    for ln, line in enumerate(src.splitlines(), 1):
        if ln in ml: continue
        st = line.strip()
        if st.startswith('//') or st.startswith('///'): continue
        for a, z, s in literals(line):
            plain = re.sub(r'\\\((?:[^()]|\([^()]*\))*\)', '', s)
            if not spanish.search(plain) or s.startswith(skip_prefix) or len(plain.strip()) < 4: continue
            if re.fullmatch(r'[\w\-.]+', plain): continue          # identifiers, keys, file names
            if technical(s, plain): continue
            if re.search(r'(NSLog|print|dateFormat\s*=)\s*\(?\s*$', line[:a].rstrip()): continue   # debug logging and date formats
            if in_xliff(s): continue
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
print(f'\n{len(pending)} pending literals · {len(keys)} keys in the xliff', file=sys.stderr)
