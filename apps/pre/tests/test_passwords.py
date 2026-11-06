"""Passwords: salted scrypt, the old MD5 is accepted and converted on login, and the first boot creates
a single administrator (with the password from THEPOD_ADMIN_PASSWORD)."""
import importlib
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


def _fresh(tmp_path, monkeypatch, admin_pw="clave-de-prueba-1"):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("THEPOD_ADMIN_PASSWORD", admin_pw)
    monkeypatch.delenv("THEPOD_ADMIN_USER", raising=False)
    import shared_users
    shared_users = importlib.reload(shared_users)
    return shared_users


def test_first_run_creates_a_single_admin(tmp_path, monkeypatch):
    su = _fresh(tmp_path, monkeypatch)
    rows = su.list_user_rows()
    assert [r["username"] for r in rows] == ["admin"]
    assert rows[0]["is_admin"]
    assert su.verify_password("admin", "clave-de-prueba-1")
    assert not su.verify_password("admin", "otra")
    assert su.default_owner() == "admin"


def test_scrypt_is_salted_and_checks(tmp_path, monkeypatch):
    su = _fresh(tmp_path, monkeypatch)
    a, b = su.hash_password("hola123"), su.hash_password("hola123")
    assert a != b and a.startswith("scrypt$")
    assert su.check_password("hola123", a) and not su.check_password("hola124", a)
    assert not su.check_password("x", None) and not su.check_password("x", "basura")


def test_old_md5_is_accepted_once_and_upgraded(tmp_path, monkeypatch):
    su = _fresh(tmp_path, monkeypatch)
    su.create_user("ana", "secreta1")
    con = sqlite3.connect(str(su.USERS_DB))
    con.execute("UPDATE users SET password_md5 = ? WHERE username = 'ana'", (su.md5("secreta1"),))
    con.commit()
    su._invalidate_cache()
    assert not su.verify_password("ana", "mala")
    assert len(su.get_user("ana")["password_md5"]) == 32          # a wrong password leaves it untouched
    assert su.verify_password("ana", "secreta1")
    stored = su.get_user("ana")["password_md5"]
    assert stored.startswith("scrypt$")                              # converted on login
    assert su.verify_password("ana", "secreta1")


def test_new_users_never_store_md5(tmp_path, monkeypatch):
    su = _fresh(tmp_path, monkeypatch)
    su.create_user("beto", "secreta2")
    assert su.get_user("beto")["password_md5"].startswith("scrypt$")
