"""Tests for chat_api blueprint."""

from db import get_db


def _create_active_event(client, chat_mode="free"):
    rv = client.post("/api/events", json={"title": "Chat AMA", "chat_mode": chat_mode})
    eid = rv.get_json()["id"]
    client.post(f"/api/events/{eid}/start")
    return eid


def _add_participant(client, eid, name="Participante"):
    rv = client.post(f"/api/events/{eid}/request-access", json={"name": name})
    data = rv.get_json()
    return data["id"], data["access_token"]


def test_host_sends_message(client):
    eid = _create_active_event(client)
    rv = client.post(f"/api/events/{eid}/chat", json={"message": "Hola a todos"})
    assert rv.status_code == 201
    data = rv.get_json()
    assert data["is_host"] == 1
    assert data["is_approved"] == 1


def test_participant_sends_message(_app):
    """In free mode, participant messages are auto-approved."""
    with _app.test_client() as host:
        with host.session_transaction() as sess:
            sess["username"] = "admin"
        rv = host.post("/api/events", json={"title": "Free AMA", "chat_mode": "free"})
        eid = rv.get_json()["id"]
        host.post(f"/api/events/{eid}/start")
        rv = host.post(f"/api/events/{eid}/request-access", json={"name": "Anon"})
        token = rv.get_json()["access_token"]

    with _app.test_client() as anon:
        rv = anon.post(
            f"/api/events/{eid}/chat",
            json={"message": "Pregunta", "token": token},
        )
        assert rv.status_code == 201
        assert rv.get_json()["is_approved"] == 1
        assert rv.get_json()["is_host"] == 0


def test_list_messages(client):
    eid = _create_active_event(client)
    client.post(f"/api/events/{eid}/chat", json={"message": "Msg 1"})
    client.post(f"/api/events/{eid}/chat", json={"message": "Msg 2"})
    rv = client.get(f"/api/events/{eid}/chat")
    assert rv.status_code == 200
    assert len(rv.get_json()) == 2


def test_moderated_participant_needs_approval(_app):
    with _app.test_client() as host:
        with host.session_transaction() as sess:
            sess["username"] = "admin"
        rv = host.post("/api/events", json={"title": "Mod AMA", "chat_mode": "moderated"})
        eid = rv.get_json()["id"]
        host.post(f"/api/events/{eid}/start")
        rv = host.post(f"/api/events/{eid}/request-access", json={"name": "Moderado"})
        token = rv.get_json()["access_token"]

    with _app.test_client() as anon:
        rv = anon.post(
            f"/api/events/{eid}/chat",
            json={"message": "Necesita aprobación", "token": token},
        )
        assert rv.status_code == 201
        data = rv.get_json()
        assert data["is_approved"] == 0
        assert data["is_host"] == 0


def test_moderated_host_auto_approved(client):
    eid = _create_active_event(client, chat_mode="moderated")
    rv = client.post(f"/api/events/{eid}/chat", json={"message": "Host msg"})
    assert rv.status_code == 201
    assert rv.get_json()["is_approved"] == 1
    assert rv.get_json()["is_host"] == 1


def test_approve_message(_app):
    with _app.test_client() as host:
        with host.session_transaction() as sess:
            sess["username"] = "admin"
        rv = host.post("/api/events", json={"title": "Approve AMA", "chat_mode": "moderated"})
        eid = rv.get_json()["id"]
        host.post(f"/api/events/{eid}/start")
        rv = host.post(f"/api/events/{eid}/request-access", json={"name": "ApproveMe"})
        token = rv.get_json()["access_token"]

    with _app.test_client() as anon:
        rv = anon.post(
            f"/api/events/{eid}/chat",
            json={"message": "Pendiente", "token": token},
        )
        mid = rv.get_json()["id"]
        assert rv.get_json()["is_approved"] == 0

    with _app.test_client() as host2:
        with host2.session_transaction() as sess:
            sess["username"] = "admin"
        rv = host2.post(f"/api/events/{eid}/chat/{mid}/approve")
        assert rv.status_code == 200
        assert rv.get_json()["is_approved"] == 1


def test_chat_off_rejects(client):
    eid = _create_active_event(client, chat_mode="off")
    rv = client.post(f"/api/events/{eid}/chat", json={"message": "No pasa"})
    assert rv.status_code == 403


# ── Chat del público (0.29) ──────────────────────────────────────────

def _viewer(_app, eid, name="Ana"):
    c = _app.test_client()
    rv = c.post(f"/api/events/{eid}/chat/join", json={"name": name})
    assert rv.status_code == 201, rv.data
    return c, rv.get_json()["chat_token"]


def test_viewer_chat_moderated_flow(_app):
    with _app.test_client() as host:
        with host.session_transaction() as s:
            s["username"] = "admin"
        eid = _create_active_event(host, chat_mode="moderated")
        viewer, ct = _viewer(_app, eid)
        rv = viewer.post(f"/api/events/{eid}/chat", json={"message": "Hola!", "chat_token": ct})
        assert rv.status_code == 201 and rv.get_json()["pending"] is True and rv.get_json()["mine"] is True
        mid = rv.get_json()["id"]
        # el resto del público no lo ve todavía; quien lo escribió sí, y el anfitrión también
        assert _app.test_client().get(f"/api/events/{eid}/chat").get_json() == []
        own = viewer.get(f"/api/events/{eid}/chat?chat_token={ct}").get_json()
        assert len(own) == 1 and own[0]["pending"]
        hostlist = host.get(f"/api/events/{eid}/chat").get_json()
        assert len(hostlist) == 1 and hostlist[0]["pending"] and hostlist[0]["can_block"]
        # aprobado: lo ven todos
        assert host.post(f"/api/events/{eid}/chat/{mid}/approve").status_code == 200
        pub = _app.test_client().get(f"/api/events/{eid}/chat").get_json()
        assert len(pub) == 1 and not pub[0]["pending"]


def test_viewer_rate_limit_and_length(_app):
    with _app.test_client() as host:
        with host.session_transaction() as s:
            s["username"] = "admin"
        eid = _create_active_event(host)
    viewer, ct = _viewer(_app, eid)
    assert viewer.post(f"/api/events/{eid}/chat", json={"message": "uno", "chat_token": ct}).status_code == 201
    assert viewer.post(f"/api/events/{eid}/chat", json={"message": "dos", "chat_token": ct}).status_code == 429
    viewer2, ct2 = _viewer(_app, eid, "Beto")
    assert viewer2.post(f"/api/events/{eid}/chat", json={"message": "x" * 301, "chat_token": ct2}).status_code == 400


def test_block_sender(_app):
    with _app.test_client() as host:
        with host.session_transaction() as s:
            s["username"] = "admin"
        eid = _create_active_event(host)
        viewer, ct = _viewer(_app, eid, "Troll")
        mid = viewer.post(f"/api/events/{eid}/chat", json={"message": "spam", "chat_token": ct}).get_json()["id"]
        rv = host.post(f"/api/events/{eid}/chat/{mid}/block")
        assert rv.status_code == 200 and rv.get_json()["removed"] == 1
        import time; time.sleep(3.1)
        assert viewer.post(f"/api/events/{eid}/chat", json={"message": "otra vez", "chat_token": ct}).status_code == 403
        assert host.get(f"/api/events/{eid}/chat").get_json() == []


def test_join_requires_name_and_chat_on(_app):
    with _app.test_client() as host:
        with host.session_transaction() as s:
            s["username"] = "admin"
        eid = _create_active_event(host, chat_mode="off")
        eid2 = _create_active_event(host)
    c = _app.test_client()
    assert c.post(f"/api/events/{eid}/chat/join", json={"name": "Ana"}).status_code == 403
    assert c.post(f"/api/events/{eid2}/chat/join", json={"name": "   "}).status_code == 400


def test_only_host_moderates(_app):
    with _app.test_client() as host:
        with host.session_transaction() as s:
            s["username"] = "admin"
        eid = _create_active_event(host, chat_mode="moderated")
    viewer, ct = _viewer(_app, eid)
    mid = viewer.post(f"/api/events/{eid}/chat", json={"message": "hola", "chat_token": ct}).get_json()["id"]
    with _app.test_client() as other:
        with other.session_transaction() as s:
            s["username"] = "otro"
        assert other.post(f"/api/events/{eid}/chat/{mid}/approve").status_code == 403
        assert other.post(f"/api/events/{eid}/chat/{mid}/block").status_code == 403
