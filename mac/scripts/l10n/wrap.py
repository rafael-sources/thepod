#!/usr/bin/env python3
"""Envuelve en String(localized:) los literales en español que el compilador no ve como localizables.
Salta claves, rutas, comparaciones y patrones. Idempotente."""
import re, sys, pathlib, xml.etree.ElementTree as ET
sys.path.insert(0, str(pathlib.Path(__file__).parent)); from swiftlit import literals
root = pathlib.Path(__file__).resolve().parents[2]
ns = {'x': 'urn:oasis:names:tc:xliff:document:1.2'}
keys = {u.find('x:source', ns).text for u in ET.parse(root/'l10n/en.xliff').getroot().findall('.//x:trans-unit', ns)}
interp = re.compile(r'\\\((?:[^()]|\([^()]*\))*\)')
spanish = re.compile(r'[a-záéíóúñ]{3,}', re.I)
skip_prefix = ('http', '/', '-', '#', 'com.', 'space.', 'cache/', 'media/', 'broll/', 'exports', 'estudio.', 'proxy', 'application/', 'ritmo-', 'capas/', 'sfx/', 'musica/', 'fondos/', 'looks/', 'pistas_')
skip_ctx = re.compile(r'(?<![\w])(case|==|!=|\.contains|\.hasPrefix|\.hasSuffix|forKey|key|rel|\.appendingPathComponent|dateFormat|NSLog|print|\.query|keys|track|URL|string:|withExtension|fileURLWithPath|localized:|verbatim:|Keychain|UserDefaults|\.set\(|object\(|\.range|replacingOccurrences|split|components|separator:|identifier|rawValue|name:|\.name ==|systemImage|systemName|AVAudioUnit|AudioComponent|fileName|filename|baseName|\.path|slug|command|\[|tag\(|forHTTPHeaderField|setValue|arguments|executableURL|lastPathComponent|regularExpression|pattern|withName|extension|ext|\.joined|domain)\s*[:(=]?\s*$')
def key_of(s): return interp.sub('%@', s).replace('\\"', '"')
def wrappable(s, before):
    plain = interp.sub('', s)
    if not spanish.search(plain) or s.startswith(skip_prefix) or len(plain.strip()) < 4: return False
    if re.fullmatch(r'[\w\-.]+', plain): return False
    if re.search(r'\.(caf|mp4|mp3|wav|m4a|png|jpg|json|txt|srt|vtt|pdf|cube|mov)\b', s): return False
    if '/' in plain and ' ' not in plain: return False
    k = key_of(s)
    if k in keys or k.replace('%@', '%lld') in keys: return False
    b = before.rstrip()
    if b.endswith('String(localized:') or b.endswith('localized:'): return False
    if skip_ctx.search(b[-48:]): return False
    if re.search(r'\b(case|switch)\b[^{:]*$', b) and not re.search(r'\b(return|=|\+|\?|\(|,)\s*$', b): return False
    return True
total = 0
for f in sorted((root/'Sources').rglob('*.swift')):
    if f.name in ('StudioTests.swift', 'SelfTest.swift', 'Language.swift'): continue
    src = f.read_text(); out = []; changed = 0
    for line in src.splitlines(keepends=True):
        pos = 0; new = ''
        for a, z, s in literals(line):
            if wrappable(s, line[:a]):
                new += line[pos:a] + 'String(localized: ' + line[a:z] + ')'; pos = z; changed += 1
        new += line[pos:]; out.append(new)
    if changed: f.write_text(''.join(out)); total += changed; print(f'{changed:4d}  {f.relative_to(root)}')
print(f'{total} literales envueltos', file=sys.stderr)
