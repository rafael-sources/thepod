#!/usr/bin/env python3
"""Saca los textos visibles de un app.js de Vue (plantillas inline): nodos de texto, placeholder/title/aria-label,
y las cadenas que van a podSwal/alert/toast. Las interpolaciones {{ x }} quedan como *.
Uso: extract_vue.py app.js > textos.json"""
import re, sys, json, html
src = open(sys.argv[1], encoding='utf-8').read()
out = {}
def add(t, where):
    t = html.unescape(re.sub(r'\s+', ' ', t)).strip()
    if not t or not re.search(r'[A-Za-zÁÉÍÓÚáéíóúñÑ]{2,}', t): return
    if re.fullmatch(r'[\*\s·•\-–—:|/.,()]+', t): return
    if re.search(r'="|\w+\.\w+\(|=>|\|\||&&', t) and where in ('text', 'attr'): return   # restos de etiquetas o expresiones
    out.setdefault(t, where)
# plantillas: template: `...`
for m in re.finditer(r'template:\s*(?:`((?:[^`\\]|\\[\s\S])*)`|\'((?:[^\'\\]|\\[\s\S])*)\')', src):
    tpl = (m.group(1) if m.group(1) is not None else m.group(2)).replace('\\\n', '\n').replace("\\'", "'")
    raw = tpl
    tpl = re.sub(r'\{\{[^}]*\}\}', '*', tpl)
    # atributos visibles
    for a in re.finditer(r'(?<![:@\w])(?:placeholder|title|aria-label|alt|label)="([^"]*)"', tpl): add(a.group(1), 'attr')
    # atributos ligados (:title="cond ? 'A' : 'B'"): las cadenas de dentro
    for a in re.finditer(r':(?:placeholder|title|aria-label|alt|label)="([^"]*)"', tpl):
        for q in re.finditer(r"'((?:[^'\\]|\\.)*)'", a.group(1)): add(q.group(1), 'bound')
    # texto entre etiquetas
    body = re.sub(r'<[^>]*>', '\n', tpl)
    # {{ cond ? 'A' : 'B' }} y {{ x || 'texto' }}: las cadenas de dentro de las interpolaciones
    for q in re.finditer(r"\{\{[^}]*?'((?:[^'\\]|\\.)*)'[^}]*\}\}", raw):
        for q2 in re.finditer(r"'((?:[^'\\]|\\.)*)'", q.group(0)): add(q2.group(1), 'interp')
    for line in body.split('\n'): add(line, 'text')
# cadenas en JS que ven los usuarios
for m in re.finditer(r'(?:podSwal\.(?:confirm|toast|alert|error|info|success|ask|input)|alert|setError|error\.value\s*=|msg\s*=|note\s*=|toast)\s*\(?\s*(`(?:[^`\\]|\\.)*`|"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')', src):
    s = m.group(1)[1:-1]
    s = re.sub(r'\$\{[^}]*\}', '*', s).replace('\\n', ' ')
    add(s, 'js')
# cualquier otra cadena JS con pinta de texto (etiquetas en listas, estados, mensajes armados)
code = re.sub(r'template:\s*(?:`(?:[^`\\]|\\[\s\S])*`|\'(?:[^\'\\]|\\[\s\S])*\')', '', src)
for m in re.finditer(r'`((?:[^`\\]|\\.)*)`|"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'', code):
    s = next(g for g in m.groups() if g is not None)
    s = re.sub(r'\$\{[^}]*\}', '*', s).replace('\\n', ' ')
    if re.match(r'^(https?:|/|\.|#|[\w\-]+$|[A-Za-z0-9_\-]+\.[a-z]+$)', s): continue          # urls, rutas, ids, archivos
    if not re.search(r'[áéíóúñ¿¡]|\b(de|la|el|los|las|un|una|que|para|con|sin|por|al|del|se|no|es|en|y|o)\b', s): continue
    if ' ' not in s.strip() and not re.search(r'[áéíóúñ]', s): continue
    add(s, 'js2')
json.dump(out, sys.stdout, ensure_ascii=False, indent=0)
print(file=sys.stderr)
print(len(out), 'textos', file=sys.stderr)
