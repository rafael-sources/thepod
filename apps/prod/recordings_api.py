"""
Client-side recording upload + listing + download.

The browser records its own tracks with MediaRecorder and uploads the final
blob(s) here when the host calls /stop. We don't rely on LiveKit Egress so
no Docker volume mounts are needed.
"""

import io
import json
import mimetypes
import os
import re
import subprocess
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import requests
from flask import Blueprint, Response, abort, jsonify, request

from auth import current_user, require_auth
from config import INTEGRATION_SECRET, POSTPOD_URL, SESSIONS_DIR
from db import get_db, session_dir
from integrations import notify_source


bp = Blueprint("recordings_api", __name__)


ALLOWED_KINDS = {"audio", "video", "screen", "mixed_output", "soundboard"}
ALLOWED_EXTS = {".webm", ".mp4", ".mp3", ".wav", ".ogg", ".m4a"}


def _remux_webm(path: Path) -> None:
    """Rewrite a MediaRecorder .webm so the container carries duration metadata.

    MediaRecorder emits streamable webm without a known duration — players show
    duration=N/A and seeking is broken. `ffmpeg -c copy` re-muxes into a fully
    indexed Matroska/webm. On any failure we keep the original file.
    """
    if path.suffix.lower() != ".webm":
        return
    fixed = path.with_name(path.stem + ".fixed" + path.suffix)
    try:
        proc = subprocess.run(
            ["ffmpeg", "-y", "-i", str(path), "-c", "copy", str(fixed)],
            capture_output=True, timeout=120,
        )
        if proc.returncode == 0 and fixed.exists() and fixed.stat().st_size > 0:
            path.unlink()
            fixed.rename(path)
        else:
            if fixed.exists():
                fixed.unlink()
    except (subprocess.SubprocessError, OSError):
        try:
            if fixed.exists():
                fixed.unlink()
        except OSError:
            pass


def _probe_duration(path: Path) -> float:
    try:
        proc = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "json", str(path)],
            capture_output=True, timeout=30, text=True,
        )
        if proc.returncode == 0:
            data = json.loads(proc.stdout or "{}")
            d = (data.get("format") or {}).get("duration")
            if d is not None:
                return float(d)
    except (subprocess.SubprocessError, OSError, ValueError, json.JSONDecodeError):
        pass
    return 0.0


def _serialize_recording(row):
    d = {
        "id": row["id"],
        "session_id": row["session_id"],
        "participant_id": row["participant_id"],
        "track_type": row["track_type"],
        "filename": row["filename"],
        "duration_seconds": row["duration_seconds"],
        "size_bytes": row["size_bytes"],
        "mime_type": row["mime_type"],
        "created_at": row["created_at"],
        "url": f"/api/sessions/{row['session_id']}/recordings/{row['filename']}",
    }
    try:
        d["exported_to_postpod_at"] = row["exported_to_postpod_at"]
    except (KeyError, IndexError):
        d["exported_to_postpod_at"] = None
    return d


def _is_session_member(db, sid, username):
    if not username:
        return False
    s = db.execute("SELECT created_by FROM sessions WHERE id=?", (sid,)).fetchone()
    if not s:
        return False
    if s["created_by"] == username:
        return True
    p = db.execute(
        "SELECT id FROM participants WHERE session_id=? AND username=?",
        (sid, username),
    ).fetchone()
    return bool(p)


@bp.post("/api/sessions/<int:sid>/chapter-markers")
def save_chapter_marker(sid):
    """Append a single chapter marker captured during recording."""
    db = get_db()
    try:
        sess = db.execute("SELECT id FROM sessions WHERE id=?", (sid,)).fetchone()
        if not sess:
            return jsonify({"error": "sesión no encontrada"}), 404

        body = request.get_json(silent=True) or {}
        token = request.args.get("token") or body.get("token")
        participant_id = None
        if token:
            p = db.execute(
                "SELECT id FROM participants WHERE session_id=? AND invite_token=?",
                (sid, token),
            ).fetchone()
            if not p:
                return jsonify({"error": "token inválido"}), 401
            participant_id = p["id"]
        else:
            username = current_user()
            if not username or not _is_session_member(db, sid, username):
                return jsonify({"error": "no autorizado"}), 401
            p = db.execute(
                "SELECT id FROM participants WHERE session_id=? AND username=?",
                (sid, username),
            ).fetchone()
            participant_id = p["id"] if p else None

        try:
            off = float(body.get("tl_offset_seconds") or 0)
        except (TypeError, ValueError):
            return jsonify({"error": "tl_offset_seconds inválido"}), 400
        label = (body.get("label") or "").strip()[:200]
        if off < 0:
            return jsonify({"error": "tl_offset_seconds < 0"}), 400

        cur = db.execute(
            "INSERT INTO chapter_markers (session_id, participant_id, label, tl_offset_seconds) "
            "VALUES (?, ?, ?, ?)",
            (sid, participant_id, label, off),
        )
        db.commit()
        return jsonify({"id": cur.lastrowid, "label": label, "tl_offset_seconds": off}), 201
    finally:
        db.close()


@bp.get("/api/sessions/<int:sid>/chapter-markers")
@require_auth
def list_chapter_markers(sid):
    db = get_db()
    try:
        if not _is_session_member(db, sid, current_user()):
            return jsonify({"error": "no autorizado"}), 401
        rows = db.execute(
            "SELECT id, label, tl_offset_seconds, is_planned, kind, "
            "sponsor_name, sponsor_copy, sponsor_logo_url, planned_offset_seconds, created_at "
            "FROM chapter_markers WHERE session_id=? ORDER BY tl_offset_seconds",
            (sid,),
        ).fetchall()
        return jsonify([dict(r) for r in rows])
    finally:
        db.close()


@bp.patch("/api/sessions/<int:sid>/chapter-markers/<int:mid>/delay")
@require_auth
def delay_chapter_marker(sid, mid):
    """Push a planned sponsor marker forward by N seconds (default 90)."""
    db = get_db()
    try:
        if not _is_session_member(db, sid, current_user()):
            return jsonify({"error": "no autorizado"}), 401
        row = db.execute(
            "SELECT id, tl_offset_seconds, planned_offset_seconds "
            "FROM chapter_markers WHERE id=? AND session_id=?", (mid, sid),
        ).fetchone()
        if not row:
            return jsonify({"error": "marker no encontrado"}), 404
        body = request.get_json(silent=True) or {}
        delay = float(body.get("delay_seconds", 90))
        new_off = (row["planned_offset_seconds"] or row["tl_offset_seconds"]) + delay
        db.execute(
            "UPDATE chapter_markers SET tl_offset_seconds=?, planned_offset_seconds=? WHERE id=?",
            (new_off, new_off, mid),
        )
        db.commit()
        return jsonify({"id": mid, "tl_offset_seconds": new_off, "planned_offset_seconds": new_off})
    finally:
        db.close()


@bp.get("/api/sessions/<int:sid>/sound-triggers/stats")
@require_auth
def sound_trigger_stats(sid):
    db = get_db()
    try:
        n = db.execute(
            "SELECT COUNT(*) AS n FROM sound_triggers WHERE session_id=?", (sid,)
        ).fetchone()["n"]
        return jsonify({"count": n})
    finally:
        db.close()


@bp.post("/api/sessions/<int:sid>/sound-triggers")
def save_sound_triggers(sid):
    """
    Append one batch of soundboard trigger events captured client-side during
    a recording. Each trigger is {filename, tl_offset_seconds}. Auth: cookie
    session OR invite token.
    """
    db = get_db()
    try:
        sess = db.execute("SELECT id FROM sessions WHERE id=?", (sid,)).fetchone()
        if not sess:
            return jsonify({"error": "sesión no encontrada"}), 404

        body = request.get_json(silent=True) or {}
        token = request.args.get("token") or body.get("token")
        participant_id = None
        if token:
            p = db.execute(
                "SELECT id FROM participants WHERE session_id=? AND invite_token=?",
                (sid, token),
            ).fetchone()
            if not p:
                return jsonify({"error": "token inválido"}), 401
            participant_id = p["id"]
        else:
            username = current_user()
            if not username or not _is_session_member(db, sid, username):
                return jsonify({"error": "no autorizado"}), 401
            p = db.execute(
                "SELECT id FROM participants WHERE session_id=? AND username=?",
                (sid, username),
            ).fetchone()
            participant_id = p["id"] if p else None

        triggers = body.get("triggers") or []
        if not isinstance(triggers, list):
            return jsonify({"error": "triggers debe ser una lista"}), 400

        inserted = 0
        for t in triggers:
            try:
                fname = (t.get("filename") or "").strip()
                off = float(t.get("tl_offset_seconds") or 0)
            except (ValueError, AttributeError):
                continue
            if not fname or off < 0:
                continue
            db.execute(
                "INSERT INTO sound_triggers (session_id, participant_id, sound_filename, tl_offset_seconds) "
                "VALUES (?, ?, ?, ?)",
                (sid, participant_id, fname, off),
            )
            inserted += 1
        db.commit()
        return jsonify({"inserted": inserted})
    finally:
        db.close()


@bp.post("/api/sessions/<int:sid>/recordings/stream")
def stream_recording_chunk(sid):
    """Accept a chunk of recording data and append to a streaming file.
    When finalize=1, register the completed file in the DB."""
    db = get_db()
    try:
        sess = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        if not sess:
            return jsonify({"error": "sesión no encontrada"}), 404

        token = request.args.get("token") or request.form.get("token")
        p = None
        if token:
            p = db.execute(
                "SELECT id FROM participants WHERE session_id=? AND invite_token=?",
                (sid, token),
            ).fetchone()
        if not p:
            username = current_user()
            if username:
                p = db.execute(
                    "SELECT id FROM participants WHERE session_id=? AND username=?",
                    (sid, username),
                ).fetchone()
        if not p:
            return jsonify({"error": "no autorizado"}), 401
        participant_id = p["id"]

        track_type = (request.form.get("track_type") or "video").strip().lower()
        ext = request.form.get("ext") or ".webm"
        if not ext.startswith("."):
            ext = "." + ext

        # take_id (opcional): un uuid por grabación. Mismo take_id = misma
        # toma (los reintentos van al mismo archivo); take_id distinto = toma
        # nueva que se guarda aparte. Sin take_id: comportamiento histórico.
        take_id = re.sub(r"[^A-Za-z0-9_-]", "", request.form.get("take_id") or "")[:64] or None

        dest_dir = session_dir(sid) / "recordings"
        dest_dir.mkdir(parents=True, exist_ok=True)
        take_suffix = f"_t{take_id}" if take_id else ""
        streaming_name = f"p{participant_id}_{track_type}_streaming{take_suffix}{ext}"
        streaming_path = dest_dir / streaming_name

        finalize = request.form.get("finalize") == "1"

        if take_id:
            already_finalized = db.execute(
                "SELECT id, filename, file_path, size_bytes FROM recordings "
                "WHERE session_id=? AND participant_id=? AND track_type=? AND take_id=?",
                (sid, participant_id, track_type, take_id),
            ).fetchone()
        else:
            # Clientes legacy: una grabación por participante+pista, entre
            # las filas sin take_id (las tomas nuevas no se tocan).
            already_finalized = db.execute(
                "SELECT id, filename, file_path, size_bytes FROM recordings "
                "WHERE session_id=? AND participant_id=? AND track_type=? AND take_id IS NULL",
                (sid, participant_id, track_type),
            ).fetchone()

        chunk = request.files.get("chunk")
        if chunk:
            offset_raw = request.form.get("offset")
            if offset_raw is None:
                # Sin offset: comportamiento histórico (append ciego).
                with open(str(streaming_path), "ab") as out:
                    while True:
                        buf = chunk.stream.read(65536)
                        if not buf:
                            break
                        out.write(buf)
            else:
                # Subida segura por partes: el cliente dice en qué byte
                # empieza este chunk. Así un reintento nunca duplica datos
                # y un hueco se detecta con 409 en vez de corromper el archivo.
                try:
                    offset = int(offset_raw)
                except ValueError:
                    return jsonify({"error": "offset inválido"}), 400
                cur_size = streaming_path.stat().st_size if streaming_path.exists() else 0
                if offset > cur_size:
                    return jsonify({"error": "faltan bytes anteriores",
                                    "bytes_received": cur_size}), 409
                data = chunk.stream.read()
                if offset < cur_size and cur_size >= offset + len(data):
                    pass  # chunk repetido completo: ignorar
                else:
                    # offset == cur_size (caso normal) o el final del archivo
                    # quedó a medias por un request cortado: truncar al offset
                    # y volver a escribir el chunk completo.
                    with open(str(streaming_path), "r+b" if streaming_path.exists() else "wb") as out:
                        out.truncate(offset)
                        out.seek(offset)
                        out.write(data)

        if finalize:
            if not streaming_path.exists():
                if already_finalized:
                    return jsonify({"finalized": True, "recording": _serialize_recording(
                        db.execute("SELECT * FROM recordings WHERE id=?",
                                   (already_finalized["id"],)).fetchone()),
                                    "size_bytes": already_finalized["size_bytes"]}), 201
                return jsonify({"error": "no hay datos de streaming"}), 400
            fname = f"p{participant_id}_{track_type}{take_suffix}_{uuid.uuid4().hex[:8]}{ext}"
            final_path = dest_dir / fname
            streaming_path.rename(final_path)

            dur = 0.0
            try:
                dur = float(request.form.get("duration_seconds") or 0)
            except ValueError:
                pass

            size = final_path.stat().st_size
            mime, _ = mimetypes.guess_type(str(final_path))

            if already_finalized and size > (already_finalized["size_bytes"] or 0):
                old_path = Path(already_finalized["file_path"])
                if old_path.exists():
                    old_path.unlink()
                db.execute(
                    "UPDATE recordings SET filename=?, file_path=?, duration_seconds=?, "
                    "size_bytes=?, mime_type=? WHERE id=?",
                    (fname, str(final_path), dur, size, mime or "video/webm",
                     already_finalized["id"]),
                )
                db.commit()
                row = db.execute("SELECT * FROM recordings WHERE id=?",
                                 (already_finalized["id"],)).fetchone()
            else:
                if already_finalized:
                    final_path.unlink(missing_ok=True)
                    row = db.execute("SELECT * FROM recordings WHERE id=?",
                                     (already_finalized["id"],)).fetchone()
                else:
                    cur = db.execute(
                        "INSERT INTO recordings (session_id, participant_id, track_type, filename, file_path, "
                        "duration_seconds, size_bytes, mime_type, take_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        (sid, participant_id, track_type, fname, str(final_path), dur, size, mime or "video/webm", take_id),
                    )
                    db.commit()
                    row = db.execute("SELECT * FROM recordings WHERE id=?", (cur.lastrowid,)).fetchone()
                    size = row["size_bytes"]
            body = {"finalized": True, "recording": _serialize_recording(row), "size_bytes": size}
            db.close()
            try:
                maybe_auto_export(sid)
            except Exception:
                pass   # el envío automático nunca debe romper el registro de la grabación
            return jsonify(body), 201

        size = streaming_path.stat().st_size if streaming_path.exists() else 0
        return jsonify({"ok": True, "bytes_received": size})
    finally:
        db.close()


def _resolve_participant(db, sid, token):
    """Participante por invite token, o por username de la sesión iniciada.
    El mismo esquema de autorización que el streaming de chunks."""
    p = None
    if token:
        p = db.execute(
            "SELECT id FROM participants WHERE session_id=? AND invite_token=?",
            (sid, token),
        ).fetchone()
    if not p:
        username = current_user()
        if username:
            p = db.execute(
                "SELECT id FROM participants WHERE session_id=? AND username=?",
                (sid, username),
            ).fetchone()
    return p


def backup_enabled() -> bool:
    """Respaldo por servidor: solo cuando el contenedor de egress ya monta
    ~/prodpod/sessions (si no, escribiría el MP4 dentro del contenedor).
    Se enciende con "egress_backup": true en ~/.podpod/config.json."""
    from shared_config import load_shared_config
    return bool(load_shared_config().get("egress_backup"))


@bp.post("/api/sessions/<int:sid>/backup/start")
def start_backup(sid):
    """Cada participante pide su propio respaldo al empezar a grabar (así
    también quedan cubiertos los que entran tarde). El servidor graba su
    señal de la sala en 720p mientras siga conectado."""
    if not backup_enabled():
        return jsonify({"enabled": False})
    db = get_db()
    try:
        sess = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        if not sess:
            return jsonify({"error": "sesión no encontrada"}), 404
        body = request.get_json(silent=True) or {}
        p = _resolve_participant(db, sid, request.args.get("token") or body.get("token"))
        if not p:
            return jsonify({"error": "no autorizado"}), 401
        pid = p["id"]
        role = db.execute("SELECT role FROM participants WHERE id=?", (pid,)).fetchone()["role"]
        if role == "director":
            return jsonify({"enabled": True, "skipped": "director"})
        active = db.execute(
            "SELECT egress_id FROM backup_egress WHERE session_id=? AND participant_id=? AND stopped_at IS NULL",
            (sid, pid),
        ).fetchone()
        if active:
            return jsonify({"enabled": True, "egress_id": active["egress_id"], "already": True})
        room = sess["livekit_room_name"]
    finally:
        db.close()

    from livekit_service import start_participant_backup
    bdir = session_dir(sid) / "backups"
    bdir.mkdir(parents=True, exist_ok=True)
    fpath = str(bdir / f"p{pid}_respaldo_{datetime.now(timezone.utc):%Y%m%dT%H%M%S}.mp4")
    info = start_participant_backup(room, f"participant_{pid}", fpath)
    egress_id = getattr(info, "egress_id", None) if info else None
    if not egress_id:
        return jsonify({"enabled": True, "error": "no se pudo iniciar el respaldo"}), 502
    db = get_db()
    try:
        db.execute(
            "INSERT INTO backup_egress (session_id, participant_id, egress_id, file_path) VALUES (?, ?, ?, ?)",
            (sid, pid, egress_id, fpath),
        )
        db.commit()
    finally:
        db.close()
    return jsonify({"enabled": True, "egress_id": egress_id})


def stop_session_backups(sid):
    """Cierra todos los respaldos activos de la sala (al detener la grabación)."""
    from livekit_service import stop_egress
    db = get_db()
    try:
        rows = db.execute(
            "SELECT id, egress_id FROM backup_egress WHERE session_id=? AND stopped_at IS NULL", (sid,)
        ).fetchall()
        for r in rows:
            if r["egress_id"]:
                stop_egress(r["egress_id"])
            db.execute("UPDATE backup_egress SET stopped_at=datetime('now') WHERE id=?", (r["id"],))
        db.commit()
        return len(rows)
    finally:
        db.close()


@bp.post("/api/net-test")
def net_test():
    """Recibe un blob de prueba y lo descarta: el cliente mide Mbps de subida
    cronometrando este POST. Autoriza cualquier usuario con sesión o cualquier
    invite token válido."""
    authorized = current_user() is not None
    token = request.args.get("token")
    if not authorized and token:
        db = get_db()
        try:
            authorized = db.execute(
                "SELECT 1 FROM participants WHERE invite_token=?", (token,)
            ).fetchone() is not None
        finally:
            db.close()
    if not authorized:
        return jsonify({"error": "no autorizado"}), 401
    if (request.content_length or 0) > 8 * 1024 * 1024:
        return jsonify({"error": "blob de prueba demasiado grande"}), 413
    data = request.get_data(cache=False)
    return jsonify({"ok": True, "bytes": len(data)})


@bp.post("/api/sessions/<int:sid>/recording-quality")
def set_recording_quality(sid):
    """Guarda la calidad de grabación local que decidió la prueba inicial,
    para mostrarla en el Control Room del director."""
    db = get_db()
    try:
        sess = db.execute("SELECT id FROM sessions WHERE id=?", (sid,)).fetchone()
        if not sess:
            return jsonify({"error": "sesión no encontrada"}), 404
        body = request.get_json(silent=True) or {}
        token = request.args.get("token") or body.get("token")
        p = _resolve_participant(db, sid, token)
        if not p:
            return jsonify({"error": "no autorizado"}), 401
        quality = (body.get("quality") or "").strip()
        if quality not in ("1080p", "720p"):
            return jsonify({"error": "quality debe ser 1080p o 720p"}), 400
        try:
            bitrate = int(body.get("bitrate") or 0)
        except (TypeError, ValueError):
            return jsonify({"error": "bitrate inválido"}), 400
        if not (500_000 <= bitrate <= 20_000_000):
            return jsonify({"error": "bitrate fuera de rango"}), 400
        db.execute(
            "UPDATE participants SET recording_quality=?, recording_bitrate=? WHERE id=?",
            (quality, bitrate, p["id"]),
        )
        db.commit()
        return jsonify({"ok": True, "quality": quality, "bitrate": bitrate})
    finally:
        db.close()


@bp.post("/api/sessions/<int:sid>/recordings")
def upload_recording(sid):
    """
    Upload a recording file from a participant's browser.
    Accepts either session user (host) or invited participant via `?token=...`.
    multipart/form-data: file, track_type, [duration_seconds], [participant_id]
    """
    db = get_db()
    try:
        sess = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        if not sess:
            return jsonify({"error": "sesión no encontrada"}), 404

        # Auth: cookie session OR invite token
        token = request.args.get("token") or request.form.get("token")
        participant_id = None
        if token:
            p = db.execute(
                "SELECT id FROM participants WHERE session_id=? AND invite_token=?",
                (sid, token),
            ).fetchone()
            if not p:
                return jsonify({"error": "token inválido"}), 401
            participant_id = p["id"]
        else:
            username = current_user()
            if not username or not _is_session_member(db, sid, username):
                return jsonify({"error": "no autorizado"}), 401
            p = db.execute(
                "SELECT id FROM participants WHERE session_id=? AND username=?",
                (sid, username),
            ).fetchone()
            if not p:
                cur = db.execute(
                    "INSERT INTO participants (session_id, username, display_name, role) VALUES (?, ?, ?, 'host')",
                    (sid, username, username.title()),
                )
                db.commit()
                participant_id = cur.lastrowid
            else:
                participant_id = p["id"]

        f = request.files.get("file")
        if not f or not f.filename:
            return jsonify({"error": "archivo requerido en 'file'"}), 400

        track_type = (request.form.get("track_type") or "").strip().lower()
        if track_type not in ALLOWED_KINDS:
            return jsonify({"error": f"track_type inválido: {track_type}"}), 400

        ext = Path(f.filename).suffix.lower()
        if ext not in ALLOWED_EXTS:
            return jsonify({"error": f"extensión no soportada: {ext}"}), 400

        try:
            dur = float(request.form.get("duration_seconds") or 0)
        except ValueError:
            dur = 0.0

        dest_dir = session_dir(sid) / "recordings"
        dest_dir.mkdir(parents=True, exist_ok=True)

        fname = f"p{participant_id or 'anon'}_{track_type}_{uuid.uuid4().hex[:8]}{ext}"
        dest = dest_dir / fname
        f.save(str(dest))

        if ext == ".webm":
            _remux_webm(dest)
            probed = _probe_duration(dest)
            if probed > 0:
                dur = probed

        size = dest.stat().st_size
        mime, _ = mimetypes.guess_type(str(dest))

        cur = db.execute(
            """
            INSERT INTO recordings (session_id, participant_id, track_type, filename, file_path,
                                    duration_seconds, size_bytes, mime_type)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (sid, participant_id, track_type, fname, str(dest), dur, size, mime or "video/webm"),
        )
        db.commit()

        row = db.execute("SELECT * FROM recordings WHERE id=?", (cur.lastrowid,)).fetchone()
        return jsonify(_serialize_recording(row)), 201
    finally:
        db.close()


@bp.get("/api/sessions/<int:sid>/recordings")
@require_auth
def list_recordings(sid):
    db = get_db()
    try:
        if not _is_session_member(db, sid, current_user()):
            return jsonify({"error": "no autorizado"}), 401
        _recover_orphaned_streams(db, sid)
        rows = db.execute(
            "SELECT * FROM recordings WHERE session_id=? ORDER BY created_at", (sid,)
        ).fetchall()
        return jsonify([_serialize_recording(r) for r in rows])
    finally:
        db.close()


def _recover_orphaned_streams(db, sid):
    rec_dir = session_dir(sid) / "recordings"
    if not rec_dir.exists():
        return
    for f in rec_dir.glob("*_streaming.*"):
        parts = f.stem.split("_")
        if len(parts) < 3:
            continue
        try:
            pid = int(parts[0].lstrip("p"))
        except ValueError:
            continue
        track_type = parts[1]
        already = db.execute(
            "SELECT id FROM recordings WHERE session_id=? AND participant_id=? AND track_type=?",
            (sid, pid, track_type),
        ).fetchone()
        if already:
            f.unlink(missing_ok=True)
            continue
        ext = f.suffix
        fname = f"p{pid}_{track_type}_{uuid.uuid4().hex[:8]}{ext}"
        final = rec_dir / fname
        f.rename(final)
        if ext == ".webm":
            _remux_webm(final)
        dur = _probe_duration(final)
        size = final.stat().st_size
        mime, _ = mimetypes.guess_type(str(final))
        db.execute(
            "INSERT INTO recordings (session_id, participant_id, track_type, filename, file_path, "
            "duration_seconds, size_bytes, mime_type) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (sid, pid, track_type, fname, str(final), dur, size, mime or "video/webm"),
        )
        db.commit()


@bp.post("/api/sessions/<int:sid>/recordings/export-to-postpod")
@require_auth
def export_recordings_to_postpod(sid):
    """
    Push every not-yet-exported recording of this session to postPod, where
    they land as media files of the matching shared_project_id project.
    Host or director, idempotent per file via exported_to_postpod_at.
    """
    db = get_db()
    try:
        sess = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        if not sess:
            return jsonify({"error": "sesión no encontrada"}), 404
        username = current_user()
        is_host = sess["created_by"] == username
        is_director = bool(db.execute(
            "SELECT 1 FROM participants WHERE session_id=? AND username=? AND role='director'",
            (sid, username),
        ).fetchone())
        if not is_host and not is_director:
            already = db.execute(
                "SELECT COUNT(*) AS n FROM recordings WHERE session_id=? AND exported_to_postpod_at IS NOT NULL "
                "AND exported_to_postpod_at NOT LIKE '_exporting_%'", (sid,)
            ).fetchone()
            host_name = db.execute(
                "SELECT display_name FROM participants WHERE session_id=? AND username=?",
                (sid, sess["created_by"]),
            ).fetchone()
            hname = host_name["display_name"] if host_name else sess["created_by"]
            if already and already["n"] > 0:
                return jsonify({"error": f"Ya fue enviado a postPod por {hname}"}), 200
            return jsonify({"error": f"Solo {hname} (host) o un director puede enviar a postPod"}), 403
    finally:
        db.close()
    body, status = export_session_to_postpod(sid)
    return jsonify(body), status


_AUTO_EXPORT_STALE_SECS = 20 * 60   # una subida sin escribir en 20 min se da por abandonada


def maybe_auto_export(sid):
    """Envío automático a postPod: cuando la sala ya terminó y no queda
    ninguna subida en curso, manda lo pendiente sin que nadie apriete el
    botón. Se llama al registrarse cada grabación y al detener la sala.
    Una subida abandonada (pestaña cerrada) no bloquea a las demás."""
    import time
    db = get_db()
    try:
        sess = db.execute("SELECT status FROM sessions WHERE id=?", (sid,)).fetchone()
        if not sess or sess["status"] != "finished":
            return False
        pending = db.execute(
            "SELECT COUNT(*) AS n FROM recordings WHERE session_id=? AND exported_to_postpod_at IS NULL",
            (sid,),
        ).fetchone()["n"]
    finally:
        db.close()
    if not pending:
        return False
    rec_dir = session_dir(sid) / "recordings"
    now = time.time()
    for f in rec_dir.glob("*_streaming*"):
        try:
            if now - f.stat().st_mtime < _AUTO_EXPORT_STALE_SECS:
                return False   # alguien sigue subiendo: esperar a su finalize
        except OSError:
            continue

    import logging
    import threading

    def _run():
        try:
            body, status = export_session_to_postpod(sid)
            logging.getLogger(__name__).info(
                "envío automático sesión %s → postPod: %s (exportadas=%s, fallidas=%s)",
                sid, status, body.get("exported"), body.get("failed"))
        except Exception:
            logging.getLogger(__name__).exception("envío automático sesión %s falló", sid)

    threading.Thread(target=_run, daemon=True).start()
    return True


def adopt_backups(sid):
    """Quien no tiene grabación principal (cerró la pestaña, su subida quedó
    abandonada) pero sí un respaldo terminado en el servidor: registra el
    respaldo como su grabación para que llegue a postPod. Devuelve cuántos."""
    import time
    from livekit_service import egress_status
    adopted = 0
    db = get_db()
    try:
        rows = db.execute(
            "SELECT b.* FROM backup_egress b WHERE b.session_id=? AND b.stopped_at IS NOT NULL "
            "AND NOT EXISTS (SELECT 1 FROM recordings r WHERE r.session_id=b.session_id "
            "                AND r.participant_id=b.participant_id AND r.track_type='video') "
            "ORDER BY b.id DESC",
            (sid,),
        ).fetchall()
        seen = set()
        for b in rows:
            if b["participant_id"] in seen:
                continue
            path = Path(b["file_path"])
            if not path.is_file() or path.stat().st_size == 0:
                continue
            st = egress_status(b["egress_id"]) if b["egress_id"] else None
            if st not in ("EGRESS_COMPLETE", None):
                continue   # todavía cerrándose o falló
            if st is None and time.time() - path.stat().st_mtime < 120:
                continue   # sin estado: esperar a que el archivo deje de crecer
            dur = 0.0
            try:
                out = subprocess.run(
                    ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                     "-of", "default=nw=1:nk=1", str(path)],
                    capture_output=True, text=True, timeout=60)
                dur = float(out.stdout.strip() or 0)
            except (subprocess.SubprocessError, ValueError, OSError):
                pass
            db.execute(
                "INSERT INTO recordings (session_id, participant_id, track_type, filename, file_path, "
                "duration_seconds, size_bytes, mime_type, take_id) VALUES (?, ?, 'video', ?, ?, ?, ?, 'video/mp4', ?)",
                (sid, b["participant_id"], path.name, str(path), dur, path.stat().st_size, f"respaldo-{b['id']}"),
            )
            seen.add(b["participant_id"])
            adopted += 1
        db.commit()
    finally:
        db.close()
    return adopted


def export_session_to_postpod(sid):
    """Envía a postPod todas las grabaciones de la sesión que aún no se
    enviaron. Sin chequeo de permisos: lo usan el botón (que ya los revisó)
    y el envío automático al registrarse la última grabación.
    Devuelve (dict, status_http)."""
    try:
        adopt_backups(sid)
    except Exception:
        import logging
        logging.getLogger(__name__).exception("no se pudieron adoptar respaldos de la sesión %s", sid)
    db = get_db()
    try:
        sess = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        if not sess:
            return {"error": "sesión no encontrada"}, 404
        spid = sess["shared_project_id"]
        if not spid:
            # Auto-generate and persist a shared_project_id so postPod can
            # link back. Future exports re-use the same id (idempotent).
            spid = uuid.uuid4().hex
            db.execute("UPDATE sessions SET shared_project_id=? WHERE id=?", (spid, sid))
            db.commit()

        # Mark pending rows as "exporting" atomically to prevent duplicate
        # exports when the button is clicked multiple times.
        sentinel = f"_exporting_{uuid.uuid4().hex[:8]}"
        db.execute(
            "UPDATE recordings SET exported_to_postpod_at = ? "
            "WHERE session_id = ? AND exported_to_postpod_at IS NULL",
            (sentinel, sid),
        )
        db.commit()

        rows = db.execute(
            """
            SELECT r.*, COALESCE(p.display_name, p.username, 'anon') AS participant_name
            FROM recordings r
            LEFT JOIN participants p ON p.id = r.participant_id
            WHERE r.session_id=? AND r.exported_to_postpod_at = ?
            ORDER BY r.created_at
            """,
            (sid, sentinel),
        ).fetchall()
        pending = [dict(r) for r in rows]
    finally:
        db.close()

    if not pending:
        return {"exported": 0, "failed": 0, "project": None, "message": "sin pistas nuevas"}, 200

    endpoint = POSTPOD_URL.rstrip("/") + "/api/integrations/prodpod/import-track"
    headers = {"X-PodPod-Secret": INTEGRATION_SECRET}
    base = (SESSIONS_DIR / str(sid) / "recordings").resolve()

    exported = 0
    failed = 0
    errors = []
    project_info = None
    now_iso = datetime.now(timezone.utc).isoformat(timespec="seconds")

    # Map prodPod track_type to postPod media type expectations:
    # video -> keep the .webm (video type). soundboard/audio -> also .webm,
    # postPod classifies by extension so both land as 'video'. That's OK for
    # now since .webm isn't in the audio ALLOWED_EXTS; postPod places them as
    # video and the editor can still use them as audio sources.
    for idx, r in enumerate(pending):
        fpath = (base / r["filename"]).resolve()
        if not str(fpath).startswith(str(base) + os.sep) or not fpath.is_file():
            failed += 1
            errors.append({"recording_id": r["id"], "error": "archivo local no encontrado"})
            continue

        # Name as sent to postPod (human readable)
        pname = re.sub(r"[^A-Za-z0-9_-]+", "_", r["participant_name"] or "anon").strip("_") or "anon"
        file_ext = Path(r["filename"]).suffix or ".webm"
        original_name = f"{pname}_{r['track_type']}_{r['id']}{file_ext}"

        # Owner of this prodPod session is the host. Co-host usernames go in
        # extra_hosts so postPod grants them visibility too.
        session_owner = sess["created_by"]
        co_host_rows = []
        try:
            db = get_db()
            try:
                co_host_rows = db.execute(
                    "SELECT username FROM participants "
                    "WHERE session_id=? AND role IN ('host','co-host') AND username IS NOT NULL "
                    "AND username != ?",
                    (sid, session_owner),
                ).fetchall()
            finally:
                db.close()
        except Exception:
            co_host_rows = []
        extra_hosts = ",".join(sorted({h["username"] for h in co_host_rows}))

        try:
            with open(fpath, "rb") as fh:
                resp = requests.post(
                    endpoint,
                    headers=headers,
                    data={
                        "shared_project_id": spid,
                        "source_episode_id": str(sess["source_episode_id"] or ""),
                        "original_name": original_name,
                        "track_type": r["track_type"],
                        "duration_seconds": str(r["duration_seconds"] or 0),
                        "participant_name": r["participant_name"] or "anon",
                        "project_name": sess["title"],
                        "owner_username": session_owner,
                        "extra_hosts": extra_hosts,
                        "track_number": str(idx + 1),
                    },
                    files={"file": (original_name, fh, r["mime_type"] or "video/webm")},
                    # (conexión, respuesta): con pistas de varios GB postPod tarda
                    # minutos en generar miniatura y forma de onda antes de responder.
                    timeout=(30, 3600),
                )
            if resp.status_code not in (200, 201):
                failed += 1
                errors.append({"recording_id": r["id"], "status": resp.status_code, "body": resp.text[:200]})
                db = get_db()
                try:
                    db.execute("UPDATE recordings SET exported_to_postpod_at=NULL WHERE id=?", (r["id"],))
                    db.commit()
                finally:
                    db.close()
                continue
            data = resp.json()
            if not project_info:
                project_info = data.get("project")

            db = get_db()
            try:
                db.execute(
                    "UPDATE recordings SET exported_to_postpod_at=? WHERE id=?",
                    (now_iso, r["id"]),
                )
                db.commit()
            finally:
                db.close()
            exported += 1
        except requests.RequestException as e:
            failed += 1
            errors.append({"recording_id": r["id"], "error": str(e)})
            db = get_db()
            try:
                db.execute("UPDATE recordings SET exported_to_postpod_at=NULL WHERE id=?", (r["id"],))
                db.commit()
            finally:
                db.close()

    # Dueño y co-hosts: van en cada push para que, si postPod crea el
    # proyecto antes de recibir pistas, nazca visible para ellos (y no solo
    # para los admins).
    db = get_db()
    try:
        _co_rows = db.execute(
            "SELECT username FROM participants WHERE session_id=? "
            "AND role IN ('host','co-host') AND username IS NOT NULL AND username != ?",
            (sid, sess["created_by"]),
        ).fetchall()
    finally:
        db.close()
    owner_fields = {
        "owner_username": sess["created_by"],
        "extra_hosts": ",".join(sorted({r["username"] for r in _co_rows})),
    }

    # Ship chapter markers as postPod moments
    chapters_sent = 0
    chapters_endpoint = POSTPOD_URL.rstrip("/") + "/api/integrations/prodpod/import-chapters"
    db = get_db()
    try:
        ch_rows = db.execute(
            "SELECT label, tl_offset_seconds, kind, sponsor_name, sponsor_copy, sponsor_logo_url "
            "FROM chapter_markers "
            "WHERE session_id=? ORDER BY tl_offset_seconds",
            (sid,),
        ).fetchall()
    finally:
        db.close()
    if ch_rows:
        try:
            chapters = []
            for r in ch_rows:
                ch = {"label": r["label"], "tl_offset_seconds": r["tl_offset_seconds"]}
                if r["kind"] == "sponsor" and r["sponsor_name"]:
                    ch["kind"] = "sponsor"
                    ch["sponsor_name"] = r["sponsor_name"]
                    ch["sponsor_copy"] = r["sponsor_copy"]
                    ch["sponsor_logo_url"] = r["sponsor_logo_url"]
                chapters.append(ch)
            payload = {
                "shared_project_id": spid,
                "source_episode_id": sess["source_episode_id"],
                "project_name": sess["title"],
                "chapters": chapters,
                **owner_fields,
            }
            resp = requests.post(chapters_endpoint, headers=headers, json=payload, timeout=60)
            if resp.status_code in (200, 201):
                chapters_sent = (resp.json() or {}).get("created_moments", 0)
            else:
                errors.append({"chapters_status": resp.status_code, "body": resp.text[:200]})
        except requests.RequestException as e:
            errors.append({"chapters_error": str(e)})

    # Ship the soundboard trigger log so postPod places each sound on its
    # audio lane at the exact session offset (vs the legacy "record audio
    # stream" approach).
    triggers_sent = 0
    triggers_endpoint = POSTPOD_URL.rstrip("/") + "/api/integrations/prodpod/import-sound-triggers"
    db = get_db()
    try:
        trig_rows = db.execute(
            """SELECT t.sound_filename, t.tl_offset_seconds,
                      COALESCE(p.display_name, p.username, 'anon') AS participant_name
               FROM sound_triggers t
               LEFT JOIN participants p ON p.id = t.participant_id
               WHERE t.session_id=? ORDER BY t.tl_offset_seconds""",
            (sid,),
        ).fetchall()
    finally:
        db.close()
    if trig_rows:
        try:
            payload = {
                "shared_project_id": spid,
                "source_episode_id": sess["source_episode_id"],
                "project_name": sess["title"],
                **owner_fields,
                "triggers": [
                    {"filename": r["sound_filename"],
                     "tl_offset_seconds": r["tl_offset_seconds"],
                     "participant_name": r["participant_name"]}
                    for r in trig_rows
                ],
            }
            resp = requests.post(triggers_endpoint, headers=headers, json=payload, timeout=60)
            if resp.status_code in (200, 201):
                triggers_sent = (resp.json() or {}).get("created_clips", 0)
            else:
                errors.append({"triggers_status": resp.status_code, "body": resp.text[:200]})
        except requests.RequestException as e:
            errors.append({"triggers_error": str(e)})

    # Ship director events (overlay timeline) so postPod can render them
    director_events_sent = 0
    director_events_endpoint = POSTPOD_URL.rstrip("/") + "/api/integrations/prodpod/import-director-events"
    db = get_db()
    try:
        dev_rows = db.execute(
            "SELECT * FROM director_events WHERE session_id=? ORDER BY injected_at",
            (sid,),
        ).fetchall()
    finally:
        db.close()
    if dev_rows:
        try:
            events_payload = [
                {
                    "event_type": ev["event_type"],
                    "payload": ev["payload"],
                    "recording_offset_seconds": ev["recording_offset_seconds"],
                    "duration_seconds": ev["duration_seconds"],
                    "file_path": ev["file_path"],
                    "created_by": ev["created_by"],
                    "injected_at": ev["injected_at"],
                    "removed_at": ev["removed_at"],
                }
                for ev in dev_rows
            ]
            resp = requests.post(
                director_events_endpoint,
                headers=headers,
                json={
                    "shared_project_id": spid,
                    "source_episode_id": sess["source_episode_id"],
                    "project_name": sess["title"],
                    "events": events_payload,
                    **owner_fields,
                },
                timeout=30,
            )
            if resp.status_code in (200, 201):
                director_events_sent = (resp.json() or {}).get("created_events", 0)
            else:
                errors.append({"director_events_status": resp.status_code, "body": resp.text[:200]})
        except requests.RequestException as e:
            errors.append({"director_events_error": str(e)})

    # Ship director asset files (graphics uploaded by the director)
    director_assets_sent = 0
    assets_dir = session_dir(sid) / "director_assets"
    if assets_dir.exists():
        asset_endpoint = POSTPOD_URL.rstrip("/") + "/api/integrations/prodpod/import-director-asset"
        for f in sorted(assets_dir.iterdir()):
            if not f.is_file():
                continue
            try:
                with open(f, "rb") as fh:
                    resp = requests.post(
                        asset_endpoint,
                        files={"file": (f.name, fh)},
                        data={"shared_project_id": spid, "session_id": str(sid),
                              "source_episode_id": str(sess["source_episode_id"] or "")},
                        headers=headers,
                        timeout=30,
                    )
                if resp.status_code in (200, 201):
                    director_assets_sent += 1
                else:
                    errors.append({"director_asset": f.name, "status": resp.status_code})
            except requests.RequestException as e:
                errors.append({"director_asset_error": f.name, "detail": str(e)})

    if exported > 0:
        db = get_db()
        try:
            row = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        finally:
            db.close()
        postpod_project_url = None
        if project_info and project_info.get("slug"):
            postpod_project_url = f"{POSTPOD_URL.rstrip('/')}/#/projects/{project_info['slug']}"
        notify_source(row, "exported_to_postpod", {
            "exported_count": exported,
            "failed_count": failed,
            "postpod_project_slug": (project_info or {}).get("slug"),
            "postpod_url": postpod_project_url,
        })

    return {
        "exported": exported,
        "failed": failed,
        "errors": errors,
        "project": project_info,
        "postpod_url": POSTPOD_URL,
        "triggers_sent": triggers_sent,
        "chapters_sent": chapters_sent,
        "director_events_sent": director_events_sent,
        "director_assets_sent": director_assets_sent,
    }, (200 if failed == 0 else 207)


@bp.get("/api/sessions/<int:sid>/recordings/bundle.zip")
@require_auth
def download_bundle(sid):
    """
    Download every recording of a session as a single ZIP, with filenames
    rewritten to identify the participant so postPod can import them as
    separate tracks.
    """
    db = get_db()
    try:
        if not _is_session_member(db, sid, current_user()):
            return jsonify({"error": "no autorizado"}), 401
        sess = db.execute("SELECT title FROM sessions WHERE id=?", (sid,)).fetchone()
        rows = db.execute(
            """
            SELECT r.*, COALESCE(p.display_name, p.username, 'anon') AS participant_name
            FROM recordings r
            LEFT JOIN participants p ON p.id = r.participant_id
            WHERE r.session_id=?
            ORDER BY r.created_at
            """,
            (sid,),
        ).fetchall()
    finally:
        db.close()

    if not rows:
        return jsonify({"error": "no hay grabaciones"}), 404

    base = (SESSIONS_DIR / str(sid) / "recordings").resolve()
    title_slug = re.sub(r"[^a-zA-Z0-9_-]+", "_", (sess["title"] if sess else f"session_{sid}")).strip("_") or f"session_{sid}"

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as zf:
        for r in rows:
            fpath = (base / r["filename"]).resolve()
            if not str(fpath).startswith(str(base) + os.sep) or not fpath.is_file():
                continue
            pname = re.sub(r"[^a-zA-Z0-9_-]+", "_", r["participant_name"] or "anon").strip("_") or "anon"
            arc = f"{title_slug}/{pname}_{r['track_type']}_{r['id']}{fpath.suffix}"
            zf.write(str(fpath), arc)

    data = buf.getvalue()
    resp = Response(data, mimetype="application/zip")
    resp.headers["Content-Disposition"] = f'attachment; filename="{title_slug}_tracks.zip"'
    resp.headers["Content-Length"] = str(len(data))
    return resp


@bp.get("/api/sessions/<int:sid>/recordings/<path:filename>")
@require_auth
def download_recording(sid, filename):
    db = get_db()
    try:
        if not _is_session_member(db, sid, current_user()):
            return jsonify({"error": "no autorizado"}), 401
    finally:
        db.close()

    base = (SESSIONS_DIR / str(sid) / "recordings").resolve()
    target = (base / filename).resolve()
    if not str(target).startswith(str(base) + os.sep):
        abort(403)
    if not target.is_file():
        abort(404)

    # Range support for playback
    file_size = target.stat().st_size
    mime, _ = mimetypes.guess_type(str(target))
    mime = mime or "application/octet-stream"
    range_header = request.headers.get("Range")
    if not range_header:
        def full():
            with open(target, "rb") as fh:
                while True:
                    chunk = fh.read(64 * 1024)
                    if not chunk:
                        break
                    yield chunk
        resp = Response(full(), mimetype=mime)
        resp.headers["Content-Length"] = str(file_size)
        resp.headers["Accept-Ranges"] = "bytes"
        return resp

    m = re.match(r"bytes=(\d*)-(\d*)", range_header.strip())
    if not m:
        abort(416)
    s, e = m.group(1), m.group(2)
    start = int(s) if s else 0
    end = int(e) if e else file_size - 1
    end = min(end, file_size - 1)
    length = end - start + 1

    def stream():
        with open(target, "rb") as fh:
            fh.seek(start)
            rem = length
            while rem > 0:
                ch = fh.read(min(64 * 1024, rem))
                if not ch:
                    break
                rem -= len(ch)
                yield ch
    resp = Response(stream(), status=206, mimetype=mime)
    resp.headers["Content-Range"] = f"bytes {start}-{end}/{file_size}"
    resp.headers["Accept-Ranges"] = "bytes"
    resp.headers["Content-Length"] = str(length)
    return resp
