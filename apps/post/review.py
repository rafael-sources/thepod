"""Revisión con marcas de tiempo: la Mac sube una versión (MP3 o MP4) y entrega un enlace; quien lo abre
escucha, marca un segundo y deja un comentario; la Mac se trae los comentarios como marcas en su línea de tiempo.

Sin cuenta para quien revisa: el enlace es la llave (token de 22 letras). Los archivos viven en
projects/<slug>/review/<token>.<ext>; los comentarios en la base del proyecto; el índice token → proyecto en
projects/_review_index.json.
"""
from __future__ import annotations

import json
import re
import secrets
import sqlite3
import time
from pathlib import Path

from flask import Blueprint, Response, abort, jsonify, request, send_file

from auth import require_auth
from config import PROJECTS_DIR
from db import get_db

bp = Blueprint("review", __name__)

INDEX = PROJECTS_DIR / "_review_index.json"
ALLOWED = {"mp3", "m4a", "mp4", "mov"}
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{16,32}$")


def _index() -> dict:
    try:
        return json.loads(INDEX.read_text())
    except (OSError, ValueError):
        return {}


def _save_index(d: dict) -> None:
    INDEX.parent.mkdir(parents=True, exist_ok=True)
    tmp = INDEX.with_suffix(".tmp")
    tmp.write_text(json.dumps(d))
    tmp.replace(INDEX)


def _ensure_tables(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS review_versions (
            token TEXT PRIMARY KEY,
            file TEXT NOT NULL,
            title TEXT,
            created_at REAL NOT NULL,
            revoked INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS review_comments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            token TEXT NOT NULL,
            t REAL NOT NULL,
            author TEXT,
            text TEXT NOT NULL,
            created_at REAL NOT NULL,
            resolved INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS review_comments_token ON review_comments(token, t);
        """
    )


def _version(token: str):
    """(slug, fila) de la versión, o None."""
    if not TOKEN_RE.match(token or ""):
        return None
    slug = _index().get(token)
    if not slug:
        return None
    conn = get_db(slug)
    _ensure_tables(conn)
    row = conn.execute("SELECT * FROM review_versions WHERE token = ? AND revoked = 0", (token,)).fetchone()
    conn.close()
    return (slug, row) if row else None


def _serialize(row) -> dict:
    return {
        "id": row["id"], "t": row["t"], "author": row["author"] or "", "text": row["text"],
        "created_at": row["created_at"], "resolved": bool(row["resolved"]),
    }


# ----- Desde la Mac (con sesión) -----

@bp.post("/api/projects/<slug>/review")
@require_auth
def create_version(slug):
    f = request.files.get("file")
    if not f or not f.filename:
        return jsonify({"error": "falta el archivo"}), 400
    ext = f.filename.rsplit(".", 1)[-1].lower()
    if ext not in ALLOWED:
        return jsonify({"error": "solo MP3, M4A, MP4 o MOV"}), 400
    folder = PROJECTS_DIR / slug
    if not folder.is_dir():
        return jsonify({"error": "proyecto no encontrado"}), 404
    token = secrets.token_urlsafe(16)
    dest = folder / "review"
    dest.mkdir(parents=True, exist_ok=True)
    path = dest / f"{token}.{ext}"
    f.save(path)
    conn = get_db(slug)
    _ensure_tables(conn)
    conn.execute("INSERT INTO review_versions(token, file, title, created_at) VALUES (?, ?, ?, ?)",
                 (token, path.name, (request.form.get("title") or "").strip()[:200], time.time()))
    conn.commit()
    conn.close()
    idx = _index()
    idx[token] = slug
    _save_index(idx)
    return jsonify({"token": token, "url": request.host_url.rstrip("/") + f"/r/{token}"})


@bp.get("/api/projects/<slug>/review/<token>/comments")
@require_auth
def list_comments(slug, token):
    v = _version(token)
    if not v or v[0] != slug:
        return jsonify({"error": "no existe"}), 404
    conn = get_db(slug)
    rows = conn.execute("SELECT * FROM review_comments WHERE token = ? ORDER BY t", (token,)).fetchall()
    conn.close()
    return jsonify({"comments": [_serialize(r) for r in rows]})


@bp.post("/api/projects/<slug>/review/<token>/comments/<int:cid>/resolve")
@require_auth
def resolve_comment(slug, token, cid):
    v = _version(token)
    if not v or v[0] != slug:
        return jsonify({"error": "no existe"}), 404
    resolved = 1 if (request.get_json(silent=True) or {}).get("resolved", True) else 0
    conn = get_db(slug)
    conn.execute("UPDATE review_comments SET resolved = ? WHERE id = ? AND token = ?", (resolved, cid, token))
    conn.commit()
    conn.close()
    return jsonify({"ok": True})


@bp.delete("/api/projects/<slug>/review/<token>")
@require_auth
def revoke(slug, token):
    v = _version(token)
    if not v or v[0] != slug:
        return jsonify({"error": "no existe"}), 404
    conn = get_db(slug)
    conn.execute("UPDATE review_versions SET revoked = 1 WHERE token = ?", (token,))
    conn.commit()
    conn.close()
    try:
        (PROJECTS_DIR / slug / "review" / v[1]["file"]).unlink()
    except OSError:
        pass
    return jsonify({"ok": True})


# ----- Público (el enlace es la llave) -----

@bp.get("/r/<token>/media")
def media(token):
    v = _version(token)
    if not v:
        abort(404)
    path = PROJECTS_DIR / v[0] / "review" / v[1]["file"]
    if not path.is_file():
        abort(404)
    return send_file(path, conditional=True)


@bp.get("/r/<token>/comments")
def public_comments(token):
    v = _version(token)
    if not v:
        return jsonify({"error": "no existe"}), 404
    conn = get_db(v[0])
    rows = conn.execute("SELECT * FROM review_comments WHERE token = ? ORDER BY t", (token,)).fetchall()
    conn.close()
    return jsonify({"comments": [_serialize(r) for r in rows]})


@bp.post("/r/<token>/comments")
def add_comment(token):
    v = _version(token)
    if not v:
        return jsonify({"error": "no existe"}), 404
    data = request.get_json(silent=True) or {}
    try:
        t = max(0.0, float(data.get("t", 0)))
    except (TypeError, ValueError):
        return jsonify({"error": "tiempo inválido"}), 400
    text = (data.get("text") or "").strip()
    author = (data.get("author") or "").strip()[:80]
    if not text:
        return jsonify({"error": "escribe el comentario"}), 400
    if len(text) > 2000:
        return jsonify({"error": "comentario demasiado largo"}), 400
    conn = get_db(v[0])
    cur = conn.execute("INSERT INTO review_comments(token, t, author, text, created_at) VALUES (?, ?, ?, ?, ?)",
                       (token, t, author, text, time.time()))
    conn.commit()
    row = conn.execute("SELECT * FROM review_comments WHERE id = ?", (cur.lastrowid,)).fetchone()
    conn.close()
    return jsonify(_serialize(row)), 201


@bp.get("/r/<token>")
def page(token):
    v = _version(token)
    if not v:
        abort(404)
    row = v[1]
    is_video = row["file"].rsplit(".", 1)[-1].lower() in ("mp4", "mov")
    title = row["title"] or "Episodio para revisar"
    return Response(PAGE.replace("{{TITLE}}", _esc(title)).replace("{{TOKEN}}", token)
                    .replace("{{MEDIA_TAG}}", "video" if is_video else "audio"), mimetype="text/html")


def _esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


PAGE = """<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{TITLE}} · revisión</title>
<style>
:root{--bg:#141110;--panel:#1b1714;--text:#efe3d0;--muted:#9d9078;--accent:#f4c770;--line:#3a2f22}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:-apple-system,"SF Pro Text",system-ui,sans-serif;font-size:15px;line-height:1.45}
.wrap{max-width:720px;margin:0 auto;padding:20px 16px 60px}
h1{font-size:20px;margin:0 0 4px}.sub{color:var(--muted);font-size:13px;margin-bottom:18px}
audio,video{width:100%;border-radius:10px;background:#000}
.bar{display:flex;gap:8px;align-items:center;margin:12px 0 18px;flex-wrap:wrap}
button{height:40px;padding:0 14px;border-radius:8px;border:1px solid var(--line);background:#221c16;color:var(--text);font-size:14px;cursor:pointer}
button.primary{background:var(--accent);color:#1a1511;border:0;font-weight:600}
input,textarea{width:100%;background:#0f0c0a;color:var(--text);border:1px solid var(--line);border-radius:8px;padding:10px;font:inherit}
textarea{min-height:80px;resize:vertical}
.form{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px;display:flex;flex-direction:column;gap:10px}
.at{font-family:ui-monospace,Menlo,monospace;color:var(--accent);font-size:15px}
.list{margin-top:22px;display:flex;flex-direction:column;gap:8px}
.c{display:flex;gap:12px;padding:10px 12px;border:1px solid var(--line);border-radius:10px;background:var(--panel)}
.c .t{font-family:ui-monospace,Menlo,monospace;color:var(--accent);min-width:64px;cursor:pointer}
.c .who{color:var(--muted);font-size:12px}.c.done{opacity:.5}
.empty{color:var(--muted);text-align:center;padding:20px}
.foot{margin-top:30px;color:var(--muted);font-size:12px;text-align:center}
</style>
</head>
<body><div class="wrap">
<h1>{{TITLE}}</h1>
<div class="sub">Escucha, para donde quieras comentar y escribe. El segundo exacto se guarda con tu nota; quien edita lo ve en su línea de tiempo.</div>
<{{MEDIA_TAG}} id="m" controls preload="metadata" src="/r/{{TOKEN}}/media"></{{MEDIA_TAG}}>
<div class="bar">
  <button id="mark">Marcar aquí</button>
  <span class="at" id="at">00:00</span>
  <span style="color:var(--muted);font-size:13px">← el comentario irá en este segundo</span>
</div>
<div class="form">
  <input id="who" placeholder="Tu nombre (opcional)" maxlength="80">
  <textarea id="txt" placeholder="¿Qué cambiarías en este punto?"></textarea>
  <div style="display:flex;gap:8px;justify-content:flex-end"><button class="primary" id="send">Enviar comentario</button></div>
</div>
<div class="list" id="list"><div class="empty">Cargando…</div></div>
<div class="foot">thePod · revisión compartida</div>
</div>
<script>
const m=document.getElementById('m'),at=document.getElementById('at'),list=document.getElementById('list');
let mark=0;const fmt=s=>{s=Math.max(0,Math.floor(s));const h=Math.floor(s/3600),mm=Math.floor(s%3600/60),ss=s%60;return (h?h+':':'')+String(mm).padStart(2,'0')+':'+String(ss).padStart(2,'0')};
function setMark(t){mark=t;at.textContent=fmt(t)}
document.getElementById('mark').onclick=()=>{m.pause();setMark(m.currentTime)};
m.addEventListener('pause',()=>setMark(m.currentTime));
try{document.getElementById('who').value=localStorage.getItem('thepod.review.who')||''}catch(e){}
async function load(){const r=await fetch('/r/{{TOKEN}}/comments');const j=await r.json();render(j.comments||[])}
function render(cs){list.innerHTML='';if(!cs.length){list.innerHTML='<div class="empty">Todavía no hay comentarios. Sé quien deje el primero.</div>';return}
for(const c of cs){const d=document.createElement('div');d.className='c'+(c.resolved?' done':'');
const t=document.createElement('div');t.className='t';t.textContent=fmt(c.t);t.onclick=()=>{m.currentTime=c.t;m.play()};
const b=document.createElement('div');const w=document.createElement('div');w.className='who';w.textContent=(c.author||'Alguien')+(c.resolved?' · resuelto':'');
const x=document.createElement('div');x.textContent=c.text;b.append(w,x);d.append(t,b);list.append(d)}}
document.getElementById('send').onclick=async()=>{const txt=document.getElementById('txt'),who=document.getElementById('who');
if(!txt.value.trim()){txt.focus();return}
try{localStorage.setItem('thepod.review.who',who.value)}catch(e){}
const r=await fetch('/r/{{TOKEN}}/comments',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({t:mark,author:who.value,text:txt.value})});
if(r.ok){txt.value='';load()}else{alert('No se pudo enviar. Prueba de nuevo.')}};
load();
</script>
</body></html>
"""
