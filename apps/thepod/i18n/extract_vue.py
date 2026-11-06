#!/usr/bin/env python3
"""Extracts the visible texts from a Vue app.js (inline templates): text nodes, placeholder/title/aria-label,
and the strings passed to podSwal/alert/toast. {{ x }} interpolations become *.
Usage: extract_vue.py app.js > texts.json"""
import re, sys, json, html
src = open(sys.argv[1], encoding='utf-8').read()
out = {}
def add(t, where):
    t = html.unescape(re.sub(r'\s+', ' ', t)).strip()
    if not t or not re.search(r'[A-Za-zÁÉÍÓÚáéíóúñÑ]{2,}', t): return
    if re.fullmatch(r'[\*\s·•\-–—:|/.,()]+', t): return
    if re.search(r'="|\w+\.\w+\(|=>|\|\||&&', t) and where in ('text', 'attr'): return   # leftovers of tags or expressions
    out.setdefault(t, where)
# templates: template: `...`
for m in re.finditer(r'template:\s*(?:`((?:[^`\\]|\\[\s\S])*)`|\'((?:[^\'\\]|\\[\s\S])*)\')', src):
    tpl = (m.group(1) if m.group(1) is not None else m.group(2)).replace('\\\n', '\n').replace("\\'", "'")
    raw = tpl
    tpl = re.sub(r'\{\{[^}]*\}\}', '*', tpl)
    # visible attributes
    for a in re.finditer(r'(?<![:@\w])(?:placeholder|title|aria-label|alt|label)="([^"]*)"', tpl): add(a.group(1), 'attr')
    # bound attributes (:title="cond ? 'A' : 'B'"): the strings inside
    for a in re.finditer(r':(?:placeholder|title|aria-label|alt|label)="([^"]*)"', tpl):
        for q in re.finditer(r"'((?:[^'\\]|\\.)*)'", a.group(1)): add(q.group(1), 'bound')
    # text between tags
    body = re.sub(r'<[^>]*>', '\n', tpl)
    # {{ cond ? 'A' : 'B' }} and {{ x || 'text' }}: the strings inside interpolations
    for q in re.finditer(r"\{\{[^}]*?'((?:[^'\\]|\\.)*)'[^}]*\}\}", raw):
        for q2 in re.finditer(r"'((?:[^'\\]|\\.)*)'", q.group(0)): add(q2.group(1), 'interp')
    for line in body.split('\n'): add(line, 'text')
# JS strings that users see
for m in re.finditer(r'(?:podSwal\.(?:confirm|toast|alert|error|info|success|ask|input)|alert|setError|error\.value\s*=|msg\s*=|note\s*=|toast)\s*\(?\s*(`(?:[^`\\]|\\.)*`|"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')', src):
    s = m.group(1)[1:-1]
    s = re.sub(r'\$\{[^}]*\}', '*', s).replace('\\n', ' ')
    add(s, 'js')
# any other JS string that looks like text (labels in lists, states, assembled messages)
code = re.sub(r'template:\s*(?:`(?:[^`\\]|\\[\s\S])*`|\'(?:[^\'\\]|\\[\s\S])*\')', '', src)
for m in re.finditer(r'`((?:[^`\\]|\\.)*)`|"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'', code):
    s = next(g for g in m.groups() if g is not None)
    s = re.sub(r'\$\{[^}]*\}', '*', s).replace('\\n', ' ')
    if re.match(r'^(https?:|/|\.|#|[\w\-]+$|[A-Za-z0-9_\-]+\.[a-z]+$)', s): continue          # urls, paths, ids, files
    if not re.search(r'[áéíóúñ¿¡]|\b(de|la|el|los|las|un|una|que|para|con|sin|por|al|del|se|no|es|en|y|o)\b', s): continue
    if ' ' not in s.strip() and not re.search(r'[áéíóúñ]', s): continue
    add(s, 'js2')
json.dump(out, sys.stdout, ensure_ascii=False, indent=0)
print(file=sys.stderr)
print(len(out), 'texts', file=sys.stderr)
