"""Tests for events_api blueprint."""

import json


def test_create_event(client):
    rv = client.post("/api/events", json={"title": "Mi AMA"})
    assert rv.status_code == 201
    data = rv.get_json()
    assert data["title"] == "Mi AMA"
    assert data["status"] == "created"
    assert data["host_username"] == "admin"
    assert data["livekit_room_name"] is not None


def test_create_event_needs_title(client):
    rv = client.post("/api/events", json={"description": "sin título"})
    assert rv.status_code == 400


def test_create_event_needs_auth(anon_client):
    rv = anon_client.post("/api/events", json={"title": "AMA"})
    assert rv.status_code == 401


def test_list_events(client):
    client.post("/api/events", json={"title": "Evento 1"})
    client.post("/api/events", json={"title": "Evento 2"})
    rv = client.get("/api/events")
    assert rv.status_code == 200
    data = rv.get_json()
    assert len(data) == 2


def test_get_event(client):
    rv = client.post("/api/events", json={"title": "Detalle"})
    eid = rv.get_json()["id"]
    rv = client.get(f"/api/events/{eid}")
    assert rv.status_code == 200
    assert rv.get_json()["title"] == "Detalle"


def test_update_event(client):
    rv = client.post("/api/events", json={"title": "Original"})
    eid = rv.get_json()["id"]
    rv = client.put(f"/api/events/{eid}", json={"title": "Editado", "chat_mode": "moderated"})
    assert rv.status_code == 200
    data = rv.get_json()
    assert data["title"] == "Editado"
    assert data["chat_mode"] == "moderated"


def test_delete_event_only_if_created(client):
    rv = client.post("/api/events", json={"title": "Para borrar"})
    eid = rv.get_json()["id"]
    # Start the event first
    client.post(f"/api/events/{eid}/start")
    # Should not be deletable once active
    rv = client.delete(f"/api/events/{eid}")
    assert rv.status_code == 400
    # A created event should be deletable
    rv2 = client.post("/api/events", json={"title": "Borrable"})
    eid2 = rv2.get_json()["id"]
    rv = client.delete(f"/api/events/{eid2}")
    assert rv.status_code == 200


def test_start_event(client):
    rv = client.post("/api/events", json={"title": "Arrancar"})
    eid = rv.get_json()["id"]
    rv = client.post(f"/api/events/{eid}/start")
    assert rv.status_code == 200
    assert rv.get_json()["status"] == "active"


def test_finish_event(client):
    rv = client.post("/api/events", json={"title": "Finalizar"})
    eid = rv.get_json()["id"]
    client.post(f"/api/events/{eid}/start")
    rv = client.post(f"/api/events/{eid}/finish")
    assert rv.status_code == 200
    assert rv.get_json()["status"] == "finished"


def test_cannot_start_finished_event(client):
    rv = client.post("/api/events", json={"title": "Ciclo"})
    eid = rv.get_json()["id"]
    client.post(f"/api/events/{eid}/start")
    client.post(f"/api/events/{eid}/finish")
    rv = client.post(f"/api/events/{eid}/start")
    assert rv.status_code == 400


def test_clone_to_template(client):
    rv = client.post("/api/events", json={"title": "Plantilla base", "chat_mode": "moderated"})
    assert rv.status_code == 201
    eid = rv.get_json()["id"]
    rv = client.post(f"/api/events/{eid}/clone-template")
    assert rv.status_code == 201
    tpl = rv.get_json()
    assert tpl["title"] == "Plantilla base"
    assert tpl["chat_mode"] == "moderated"


def test_create_from_template(client):
    rv = client.post("/api/events", json={"title": "Desde tpl"})
    eid = rv.get_json()["id"]
    rv = client.post(f"/api/events/{eid}/clone-template")
    tid = rv.get_json()["id"]
    rv = client.post(f"/api/events/from-template/{tid}")
    assert rv.status_code == 201
    new = rv.get_json()
    assert new["title"] == "Desde tpl"
    assert new["id"] != eid


def test_list_templates(client):
    rv = client.post("/api/events", json={"title": "TplList"})
    eid = rv.get_json()["id"]
    client.post(f"/api/events/{eid}/clone-template")
    rv = client.get("/api/events/templates")
    assert rv.status_code == 200
    assert len(rv.get_json()) >= 1
