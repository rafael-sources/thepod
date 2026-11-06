# Interface language (es/en): the dictionary is well formed, the page declares the language based on the cookie or the
# browser, the manual and the legal pages come out in English when appropriate, and each English page keeps the
# structure of the Spanish one. Run: python3 tests/i18n_escenarios.py
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
    print(("OK  " if cond else "FAIL ") + msg)
    if not cond: fails += 1

d = json.load(open(os.path.join(ROOT, "static/i18n/en.json"), encoding="utf-8"))
ok(len(d) > 200, f"dictionary with {len(d)} texts")
ok(all(isinstance(v, str) and v.strip() and k.count("*") == v.count("*") for k, v in d.items()), "the * of each pattern match")

es = cl.get("/", headers={"Accept-Language": "es-EC"}).data
en = cl.get("/", headers={"Accept-Language": "en-US,en;q=0.9"}).data
ok(b'<html lang="es">' in es and b'<html lang="en">' in en, "the landing page declares the browser language")
ok(b"pod-i18n.js" in es and b'window.POD_COOKIE_DOMAIN = ".castmedia.space"' in es, "the landing page loads the switch with the cookie domain")
cl.set_cookie("pod_lang", "en")
ok(b'<html lang="en">' in cl.get("/", headers={"Accept-Language": "es-EC"}).data, "the pod_lang cookie overrides the browser")
cl.set_cookie("pod_lang", "es")
ok(b'<html lang="es">' in cl.get("/", headers={"Accept-Language": "en-US"}).data, "and also to switch back to Spanish")
ok(cl.get("/static/i18n/en.json").status_code == 200 and cl.get("/static/js/pod-i18n.js").status_code == 200, "the dictionary and the script are served")

# Manual: the English version exists for every section and keeps the structure of the Spanish one
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
ok(not missing, "every manual page and the legal pages have an English version" + (f" — missing {missing}" if missing else ""))
ok(not broken, "the English pages keep the structure" + (f" — {broken[:5]}" if broken else ""))

cl.set_cookie("pod_lang", "en")
r = cl.get("/docs/prepod/overview")
ok(r.status_code == 200 and b'<html lang="en">' in r.data and "Tu centro de planificación".encode() not in r.data, "the manual comes out in English with the cookie")
r = cl.get("/privacidad")
ok(r.status_code == 200 and b'<html lang="en">' in r.data, "privacy page in English")
cl.set_cookie("pod_lang", "es")
r = cl.get("/docs/prepod/overview")
ok(r.status_code == 200 and "Tu centro de planificación".encode() in r.data, "and in Spanish without the cookie")
print(f"\n{'ALL OK' if not fails else str(fails) + ' failures'}")
sys.exit(1 if fails else 0)
