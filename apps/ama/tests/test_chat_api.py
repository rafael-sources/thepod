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
