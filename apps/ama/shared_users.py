"""
Shared user database for the podpod suite. Stored as SQLite at
`~/.podpod/users.db` so the three apps (prePod / prodPod / postPod) read
from the same source. SQLite handles concurrent reads + serialized writes
via WAL mode, and gives us atomic transactions, indexes, and audit fields
out of the box (vs. the previous flat-JSON store).

Migration: on first start, if a legacy `~/.podpod/users.json` exists, its
contents are imported and the JSON is left in place as `.bak`.
"""

import hashlib
import json
import os
import secrets
import sqlite3
import threading
import time
from pathlib import Path


SHARED_DIR = Path.home() / ".podpod"
USERS_DB   = SHARED_DIR / "users.db"
LEGACY_JSON = SHARED_DIR / "users.json"

# Process-local connection lock — SQLite already serializes writes across
# processes via the file lock, but in-process we still want a fast path.
_lock = threading.Lock()
_cache = {"snapshot": None, "checked": 0.0}
_CACHE_TTL = 3.0  # seconds


_DEFAULT_PALETTE = [
    "#e85a4f", "#6bb3c4", "#b56bd9", "#8db36a",
    "#f4c770", "#5a8bff", "#c87a9e", "#7d8aa8",
]


def md5(s: str) -> str:
    """Hash viejo (MD5 sin sal). Solo se usa para reconocer contraseñas guardadas antes de scrypt."""
    return hashlib.md5(s.encode()).hexdigest()


# Contraseñas: scrypt con sal propia por usuario, guardado como "scrypt$n$r$p$sal$hash" (hex).
# La columna se sigue llamando password_md5 por compatibilidad; puede tener un hash viejo de MD5
# (32 caracteres hex) hasta que ese usuario vuelva a entrar: verify_password lo convierte entonces.
_SCRYPT_N, _SCRYPT_R, _SCRYPT_P = 2 ** 14, 8, 1


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    h = hashlib.scrypt(password.encode(), salt=salt, n=_SCRYPT_N, r=_SCRYPT_R, p=_SCRYPT_P, dklen=32)
    return f"scrypt${_SCRYPT_N}${_SCRYPT_R}${_SCRYPT_P}${salt.hex()}${h.hex()}"


def check_password(password: str, stored: str | None) -> bool:
    """¿Esta contraseña corresponde a este hash guardado (scrypt o MD5 viejo)?"""
    if not stored or password is None:
        return False
    if stored.startswith("scrypt$"):
        try:
            _, n, r, p, salt, h = stored.split("$")
            got = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt), n=int(n), r=int(r), p=int(p), dklen=len(h) // 2)
        except (ValueError, TypeError):
            return False
        return secrets.compare_digest(got.hex(), h)
    if len(stored) == 32:
        return secrets.compare_digest(md5(password), stored)
    return False


def verify_password(username: str, password: str) -> bool:
    """Comprueba la contraseña de un usuario. Si estaba guardada con el MD5 viejo y es correcta,
    la vuelve a guardar con scrypt en ese momento: nadie tiene que cambiarla."""
    user = get_user(username) if username else None
    stored = (user or {}).get("password_md5")
    if not check_password(password, stored):
        return False
    if not stored.startswith("scrypt$"):
        try:
            update_user_fields(username, {"password_md5": hash_password(password)})
        except Exception:
            pass
    return True


def random_password(n: int = 12) -> str:
    return secrets.token_urlsafe(9).replace("_", "x").replace("-", "y")[:n]


# ---------------------------------------------------------------------------
# DB plumbing
# ---------------------------------------------------------------------------

_SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    username        TEXT PRIMARY KEY,
    password_md5    TEXT NOT NULL,
    display_name    TEXT,
    avatar_color    TEXT,
    is_admin        INTEGER NOT NULL DEFAULT 0,
    max_podcasts    INTEGER,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
    last_login_at   TEXT
);
"""


def _connect() -> sqlite3.Connection:
    SHARED_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(USERS_DB), timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA synchronous = NORMAL")
    conn.executescript(_SCHEMA)
    _migrate_columns(conn)
    return conn


def _migrate_columns(conn: sqlite3.Connection):
    cols = {r["name"] for r in conn.execute("PRAGMA table_info(users)")}
    if "email" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN email TEXT")
    return conn


def _bootstrap_defaults(conn: sqlite3.Connection):
    """Primer arranque con la base vacía: un solo administrador. Usuario y contraseña salen de
    THEPOD_ADMIN_USER (por defecto "admin") y THEPOD_ADMIN_PASSWORD; si no hay contraseña, se
    genera una y se escribe una sola vez en el log del servicio."""
    import logging
    username = (os.environ.get("THEPOD_ADMIN_USER") or "admin").strip().lower()
    password = os.environ.get("THEPOD_ADMIN_PASSWORD") or ""
    if not password:
        password = random_password(16)
        logging.getLogger(__name__).warning(
            "thePod: se creó el administrador '%s' con la contraseña %s — cámbiala al entrar.", username, password)
    conn.execute(
        "INSERT INTO users (username, password_md5, display_name, avatar_color, is_admin, max_podcasts) "
        "VALUES (?, ?, ?, ?, 1, NULL)",
        (username, hash_password(password), username.title(), _DEFAULT_PALETTE[0]),
    )
    conn.commit()


def default_owner() -> str:
    """Dueño de lo que se creó antes de que hubiera dueños (podcasts y proyectos viejos) y de lo que
    llega de otra app sin usuario: el primer administrador de la base."""
    _ensure_initialized()
    conn = _connect()
    try:
        r = conn.execute("SELECT username FROM users WHERE is_admin = 1 ORDER BY rowid LIMIT 1").fetchone()
        return r["username"] if r else "admin"
    finally:
        conn.close()


def _import_from_legacy_json(conn: sqlite3.Connection):
    """Idempotent: copy users from the old users.json (if present and DB empty)."""
    if not LEGACY_JSON.exists():
        return
    try:
        with LEGACY_JSON.open() as f:
            data = json.load(f)
    except (OSError, ValueError):
        return
    if not isinstance(data, dict) or "users" not in data:
        return
    for username, row in data["users"].items():
        try:
            conn.execute(
                "INSERT OR IGNORE INTO users "
                "(username, password_md5, display_name, avatar_color, is_admin, max_podcasts) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (
                    username,
                    row.get("password_md5", ""),
                    row.get("display_name") or username.title(),
                    row.get("avatar_color"),
                    1 if row.get("is_admin") else 0,
                    row.get("max_podcasts"),
                ),
            )
        except sqlite3.Error:
            continue
    conn.commit()
    # Rename the old file so we don't re-import on every boot.
    try:
        LEGACY_JSON.rename(LEGACY_JSON.with_suffix(".json.bak"))
    except OSError:
        pass


_initialized = False


def _ensure_initialized():
    """Create DB + bootstrap admin if it's empty. Safe to call repeatedly.
    Lazy: only runs the first time a real query is needed, and any failure
    is logged but never raised — so module import never crashes the app."""
    global _initialized
    if _initialized:
        return
    try:
        conn = _connect()
        try:
            n = conn.execute("SELECT COUNT(*) AS n FROM users").fetchone()["n"]
            if n == 0:
                _import_from_legacy_json(conn)
                n = conn.execute("SELECT COUNT(*) AS n FROM users").fetchone()["n"]
            if n == 0:
                _bootstrap_defaults(conn)
            _initialized = True
        finally:
            conn.close()
    except Exception as e:
        import logging
        logging.getLogger(__name__).error("shared_users init failed: %s", e)
        # Don't set _initialized — we'll retry next time.


# ---------------------------------------------------------------------------
# CRUD primitives (used by users_admin.py)
# ---------------------------------------------------------------------------

def _row_to_dict(r) -> dict:
    return {
        "username": r["username"],
        "password_md5": r["password_md5"],
        "display_name": r["display_name"] or r["username"].title(),
        "email": r["email"] or "",
        "avatar_color": r["avatar_color"] or _DEFAULT_PALETTE[hash(r["username"]) % len(_DEFAULT_PALETTE)],
        "is_admin": bool(r["is_admin"]),
        "max_podcasts": r["max_podcasts"],
        "created_at": r["created_at"],
        "updated_at": r["updated_at"],
        "last_login_at": r["last_login_at"],
    }


def list_user_rows() -> list[dict]:
    _ensure_initialized()
    conn = _connect()
    try:
        rows = conn.execute(
            "SELECT * FROM users ORDER BY is_admin DESC, username ASC"
        ).fetchall()
        return [_row_to_dict(r) for r in rows]
    finally:
        conn.close()


def get_user(username: str) -> dict | None:
    _ensure_initialized()
    if not username:
        return None
    conn = _connect()
    try:
        r = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
        return _row_to_dict(r) if r else None
    finally:
        conn.close()


def create_user(username: str, password: str, *, display_name: str = None,
                email: str = None, avatar_color: str = None,
                is_admin: bool = False, max_podcasts: int | None = None):
    """Insert a new user. Raises ValueError if it already exists."""
    if not password or len(password) < 6:
        raise ValueError("la contraseña debe tener al menos 6 caracteres")
    conn = _connect()
    try:
        with _lock, conn:
            try:
                conn.execute(
                    "INSERT INTO users (username, password_md5, display_name, email, avatar_color, "
                    "is_admin, max_podcasts) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (username, hash_password(password),
                     (display_name or username).strip().title(),
                     (email or "").strip() or None,
                     (avatar_color or "").strip() or None,
                     1 if is_admin else 0,
                     None if is_admin else max_podcasts),
                )
            except sqlite3.IntegrityError:
                raise ValueError(f"el usuario '{username}' ya existe")
        _invalidate_cache()
        return get_user(username)
    finally:
        conn.close()


def update_user_fields(username: str, fields: dict):
    """Partial update: only the keys present in `fields` are applied."""
    if not username:
        raise ValueError("username requerido")
    allowed = {"password_md5", "display_name", "email", "avatar_color", "is_admin", "max_podcasts"}
    use = {k: v for k, v in fields.items() if k in allowed}
    if not use:
        return get_user(username)
    cols = ", ".join(f"{k}=?" for k in use) + ", updated_at=datetime('now')"
    params = list(use.values()) + [username]
    conn = _connect()
    try:
        with _lock, conn:
            cur = conn.execute(f"UPDATE users SET {cols} WHERE username=?", params)
            if cur.rowcount == 0:
                raise ValueError("usuario no encontrado")
        _invalidate_cache()
        return get_user(username)
    finally:
        conn.close()


def delete_user_by_name(username: str):
    conn = _connect()
    try:
        with _lock, conn:
            cur = conn.execute("DELETE FROM users WHERE username=?", (username,))
            if cur.rowcount == 0:
                raise ValueError("usuario no encontrado")
        _invalidate_cache()
    finally:
        conn.close()


def touch_last_login(username: str):
    conn = _connect()
    try:
        with _lock, conn:
            conn.execute(
                "UPDATE users SET last_login_at=datetime('now') WHERE username=?",
                (username,),
            )
    finally:
        conn.close()


def admins_count_excluding(username: str) -> int:
    conn = _connect()
    try:
        r = conn.execute(
            "SELECT COUNT(*) AS n FROM users WHERE is_admin=1 AND username != ?",
            (username,),
        ).fetchone()
        return int(r["n"])
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Cached snapshots used by config.py's live_dicts and policy_for
# ---------------------------------------------------------------------------

def _invalidate_cache():
    _cache["snapshot"] = None
    _cache["checked"] = 0.0


def _snapshot() -> dict:
    """Return a {username: row_dict} cache, refreshed every _CACHE_TTL secs."""
    now = time.time()
    if _cache["snapshot"] is not None and now - _cache["checked"] < _CACHE_TTL:
        return _cache["snapshot"]
    snap = {r["username"]: r for r in list_user_rows()}
    _cache["snapshot"] = snap
    _cache["checked"] = now
    return snap


def users_passwords() -> dict:
    return {u: r["password_md5"] for u, r in _snapshot().items()}


def users_profiles() -> dict:
    return {u: {"display_name": r["display_name"], "avatar_color": r["avatar_color"]}
            for u, r in _snapshot().items()}


def users_policy() -> dict:
    return {u: {"see_all": bool(r["is_admin"]), "max_podcasts": r["max_podcasts"]}
            for u, r in _snapshot().items()}


def policy_for(username: str) -> dict:
    return users_policy().get(username or "", {"see_all": False, "max_podcasts": None})


# ---------------------------------------------------------------------------
# Backward-compat shim — older callers used to do load_users()/save_users().
# ---------------------------------------------------------------------------

def load_users(force: bool = False) -> dict:
    """Legacy shape: {'users': {username: {password_md5, display_name, ...}}}."""
    if force:
        _invalidate_cache()
    return {"users": {u: dict(r) for u, r in _snapshot().items()}}


def save_users(data: dict) -> dict:
    """Legacy bulk-replace. Replaces ALL users with the provided dict in one tx."""
    new = data.get("users") or {}
    conn = _connect()
    try:
        with _lock, conn:
            conn.execute("DELETE FROM users")
            for username, row in new.items():
                conn.execute(
                    "INSERT INTO users (username, password_md5, display_name, avatar_color, "
                    "is_admin, max_podcasts) VALUES (?, ?, ?, ?, ?, ?)",
                    (username,
                     row.get("password_md5", ""),
                     row.get("display_name") or username.title(),
                     row.get("avatar_color"),
                     1 if row.get("is_admin") else 0,
                     row.get("max_podcasts")),
                )
        _invalidate_cache()
    finally:
        conn.close()
    return load_users(force=True)
