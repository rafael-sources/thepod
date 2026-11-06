#!/usr/bin/env python3
"""Extracts the visible texts from Jinja/HTML templates (landing, docs/_base, planes…): text nodes,
placeholder/title/aria-label/alt, <title> and the strings in inline <script>s that users see.
{{ x }} expressions become * (pattern for pod-i18n.js); {% tags %} split the text.
Usage: extract_jinja.py template.html [...] > texts.json"""
import re, sys, json, html
out = {}
def add(t, where):
    t = html.unescape(re.sub(r'\s+', ' ', t)).strip()
    t = re.sub(r'(\*\s*)+\*', '*', t)
    if not t or not re.search(r'[A-Za-zÁÉÍÓÚáéíóúñÑ]{2,}', t): return
    if re.fullmatch(r'[\*\s·•\-–—:|/.,()]+', t): return
    if re.fullmatch(r'(the|pre|prod|post|pub|ama)?Pod|DOCS|thePod( para Mac)?|[A-Za-z]+Pod', t): return
    if re.search(r'="|=>|\|\||&&|\bfunction\b|\breturn\b|\{\s*$', t) and where in ('text', 'attr'): return
    out.setdefault(t, where)
for path in sys.argv[1:]:
    src = open(path, encoding='utf-8').read()
    scripts = re.findall(r'<script[^>]*>([\s\S]*?)</script>', src)
    tpl = re.sub(r'<script[^>]*>[\s\S]*?</script>', '\x00', src)
    tpl = re.sub(r'<style[^>]*>[\s\S]*?</style>', '\x00', tpl)
    tpl = re.sub(r'\{#[\s\S]*?#\}', '', tpl)
    tpl = re.sub(r'\{\{[^}]*\}\}', '*', tpl)
    tpl = re.sub(r'\{%[^%]*%\}', '\x00', tpl)
    for a in re.finditer(r'(?<![:@\w])(?:placeholder|title|aria-label|alt|content)="([^"]*)"', tpl):
        v = a.group(1)
        if 'content=' in a.group(0) and not re.search(r'name="description"', tpl[max(0, a.start() - 60):a.start()]): continue
        add(v, 'attr')
    body = re.sub(r'<[^>]*>', '\x00', tpl)
    for line in body.split('\x00'): add(line, 'text')
    for js in scripts:
        for m in re.finditer(r'`((?:[^`\\]|\\.)*)`|"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'', js):
            s = next(g for g in m.groups() if g is not None)
            s = re.sub(r'\$\{[^}]*\}', '*', s).replace('\\n', ' ')
            if re.match(r'^(https?:|/|\.|#|[\w\-]+$|[A-Za-z0-9_\-]+\.[a-z]+$)', s): continue
            if not re.search(r'[áéíóúñ¿¡]|\b(de|la|el|los|las|un|una|que|para|con|sin|por|al|del|se|no|es|en|y|o|tu|su)\b', s): continue
            if ' ' not in s.strip() and not re.search(r'[áéíóúñ]', s): continue
            add(s, 'js')
json.dump(out, sys.stdout, ensure_ascii=False, indent=0)
print(file=sys.stderr)
print(len(out), 'texts', file=sys.stderr)
