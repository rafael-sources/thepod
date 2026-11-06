# Idioma de la interfaz (es/en): el diccionario está bien formado, la página declara el idioma según la cookie o el
# navegador, el manual y las páginas legales salen en inglés cuando toca, y cada página en inglés conserva la
# estructura de la española. Correr: python3 tests/i18n_escenarios.py
import json, os, re, sys, tempfile
home = tempfile.mkdtemp(); os.environ["HOME"] = home
os.makedirs(home + "/.podpod")
json.dump({"secret_key": "a", "integration_secret": "b", "cookie_domain": ".castmedia.space"}, open(home + "/.podpod/config.json", "w"))
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, ROOT)
from app import create_app
cl = create_app().test_client()
fails = 0
def ok(cond, msg):
    global fails
    print(("OK  " if cond else "MAL ") + msg)
    if not cond: fails += 1

d = json.load(open(os.path.join(ROOT, "static/i18n/en.json"), encoding="utf-8"))
ok(len(d) > 200, f"diccionario con {len(d)} textos")
ok(all(isinstance(v, str) and v.strip() and k.count("*") == v.count("*") for k, v in d.items()), "los * de cada patrón coinciden")

es = cl.get("/", headers={"Accept-Language": "es-EC"}).data
en = cl.get("/", headers={"Accept-Language": "en-US,en;q=0.9"}).data
ok(b'<html lang="es">' in es and b'<html lang="en">' in en, "la landing declara el idioma del navegador")
ok(b"pod-i18n.js" in es and b'window.POD_COOKIE_DOMAIN = ".castmedia.space"' in es, "la landing carga el switch con el dominio de la cookie")
cl.set_cookie("pod_lang", "en")
ok(b'<html lang="en">' in cl.get("/", headers={"Accept-Language": "es-EC"}).data, "la cookie pod_lang manda sobre el navegador")
cl.set_cookie("pod_lang", "es")
ok(b'<html lang="es">' in cl.get("/", headers={"Accept-Language": "en-US"}).data, "y también para volver al español")
ok(cl.get("/static/i18n/en.json").status_code == 200 and cl.get("/static/js/pod-i18n.js").status_code == 200, "se sirven el diccionario y el script")

# Manual: la versión inglesa existe para cada sección y conserva la estructura de la española
from app import create_app as _c
import app as appmod
apps = {"prepod": 7, "prodpod": 7, "postpod": 7, "postpodapp": 7, "pubpod": 6, "amapod": 6}
missing, broken = [], []
for a in apps:
    for f in os.listdir(os.path.join(ROOT, "templates/docs", a)):
        es_p = os.path.join(ROOT, "templates/docs", a, f); en_p = os.path.join(ROOT, "templates/en/docs", a, f)
        if not os.path.exists(en_p): missing.append(f"{a}/{f}"); continue
        s, e = open(es_p, encoding="utf-8").read(), open(en_p, encoding="utf-8").read()
        for tag in ("<h2", "<h3", "<li", "<p", "{%", "{{"):
            if s.count(tag) != e.count(tag): broken.append(f"{a}/{f}:{tag} {s.count(tag)}≠{e.count(tag)}")
        if sorted(re.findall(r'id="([^"]+)"', s)) != sorted(re.findall(r'id="([^"]+)"', e)): broken.append(f"{a}/{f}: ids")
for f in ("privacidad.html", "terminos.html"):
    if not os.path.exists(os.path.join(ROOT, "templates/en", f)): missing.append(f)
ok(not missing, "cada página del manual y las legales tienen versión en inglés" + (f" — faltan {missing}" if missing else ""))
ok(not broken, "las páginas en inglés conservan la estructura" + (f" — {broken[:5]}" if broken else ""))

cl.set_cookie("pod_lang", "en")
r = cl.get("/docs/prepod/overview")
ok(r.status_code == 200 and b'<html lang="en">' in r.data and "Tu centro de planificación".encode() not in r.data, "el manual sale en inglés con la cookie")
r = cl.get("/privacidad")
ok(r.status_code == 200 and b'<html lang="en">' in r.data, "privacidad en inglés")
cl.set_cookie("pod_lang", "es")
r = cl.get("/docs/prepod/overview")
ok(r.status_code == 200 and "Tu centro de planificación".encode() in r.data, "y en español sin la cookie")
print(f"\n{'TODO OK' if not fails else str(fails) + ' fallos'}")
sys.exit(1 if fails else 0)
