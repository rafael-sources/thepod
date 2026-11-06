"""Tests for queue_api blueprint."""

import json


def _create_active_event(client):
    rv = client.post("/api/events", json={"title": "AMA Queue"})
    eid = rv.get_json()["id"]
    client.post(f"/api/events/{eid}/start")
    return eid


def test_request_access(client):
    eid = _create_active_event(client)
    rv = client.post(f"/api/events/{eid}/request-access", json={"name": "Ana"})
    assert rv.status_code == 201
    data = rv.get_json()
    assert data["status"] == "pending"
    assert "access_token" in data


def test_request_access_duplicate_name(client):
    eid = _create_active_event(client)
    client.post(f"/api/events/{eid}/request-access", json={"name": "Carlos"})
    rv = client.post(f"/api/events/{eid}/request-access", json={"name": "Carlos"})
    assert rv.status_code == 409


def test_request_access_requires_name(client):
    eid = _create_active_event(client)
    rv = client.post(f"/api/events/{eid}/request-access", json={})
    assert rv.status_code == 400


def test_approve_participant(client):
    eid = _create_active_event(client)
    rv = client.post(f"/api/events/{eid}/request-access", json={"name": "Luis"})
    pid = rv.get_json()["id"]
    rv = client.post(f"/api/events/{eid}/approve/{pid}")
    assert rv.status_code == 200
    assert rv.get_json()["status"] == "in_queue"
    assert rv.get_json()["queue_position"] == 1


def test_reject_participant(client):
    eid = _create_active_event(client)
    rv = client.post(f"/api/events/{eid}/request-access", json={"name": "Pedro"})
    pid = rv.get_json()["id"]
    rv = client.post(f"/api/events/{eid}/reject/{pid}")
    assert rv.status_code == 200
    assert rv.get_json()["status"] == "rejected"


def test_queue_ordering(client):
    eid = _create_active_event(client)
    pids = []
    for name in ["A", "B", "C"]:
        rv = client.post(f"/api/events/{eid}/request-access", json={"name": name})
        pids.append(rv.get_json()["id"])
    for pid in pids:
        client.post(f"/api/events/{eid}/approve/{pid}")

    rv = client.get(f"/api/events/{eid}/queue")
    assert rv.status_code == 200
    data = rv.get_json()
    assert len(data) == 3
    assert data[0]["queue_position"] == 1
    assert data[1]["queue_position"] == 2
    assert data[2]["queue_position"] == 3


def test_next_turn(client):
    eid = _create_active_event(client)
    rv = client.post(f"/api/events/{eid}/request-access", json={"name": "Primero"})
    pid1 = rv.get_json()["id"]
    rv = client.post(f"/api/events/{eid}/request-access", json={"name": "Segundo"})
    pid2 = rv.get_json()["id"]
    client.post(f"/api/events/{eid}/approve/{pid1}")
    client.post(f"/api/events/{eid}/approve/{pid2}")

    # First next: Primero goes on_air
    rv = client.post(f"/api/events/{eid}/next")
    assert rv.status_code == 200
    assert rv.get_json()["display_name"] == "Primero"
    assert rv.get_json()["status"] == "on_air"


def test_rotation(client):
    """After next twice, first participant should be done, second on_air."""
    eid = _create_active_event(client)
    rv1 = client.post(f"/api/events/{eid}/request-access", json={"name": "Uno"})
    pid1 = rv1.get_json()["id"]
    rv2 = client.post(f"/api/events/{eid}/request-access", json={"name": "Dos"})
    pid2 = rv2.get_json()["id"]
    client.post(f"/api/events/{eid}/approve/{pid1}")
    client.post(f"/api/events/{eid}/approve/{pid2}")

    client.post(f"/api/events/{eid}/next")  # Uno on_air
    rv = client.post(f"/api/events/{eid}/next")  # Uno→done, Dos on_air
    assert rv.get_json()["display_name"] == "Dos"
    assert rv.get_json()["status"] == "on_air"


def test_remove_from_queue(client):
    eid = _create_active_event(client)
    rv = client.post(f"/api/events/{eid}/request-access", json={"name": "Remover"})
    pid = rv.get_json()["id"]
    client.post(f"/api/events/{eid}/approve/{pid}")
    rv = client.delete(f"/api/events/{eid}/remove/{pid}")
    assert rv.status_code == 200


def test_censor_participant(client):
    eid = _create_active_event(client)
    rv = client.post(f"/api/events/{eid}/request-access", json={"name": "Censurado"})
    pid = rv.get_json()["id"]
    client.post(f"/api/events/{eid}/approve/{pid}")
    rv = client.post(f"/api/events/{eid}/censor/{pid}")
    assert rv.status_code == 200
    assert rv.get_json()["is_censored"] == 1


def test_uncensor_participant(client):
    eid = _create_active_event(client)
    rv = client.post(f"/api/events/{eid}/request-access", json={"name": "Libre"})
    pid = rv.get_json()["id"]
    client.post(f"/api/events/{eid}/approve/{pid}")
    client.post(f"/api/events/{eid}/censor/{pid}")
    rv = client.post(f"/api/events/{eid}/uncensor/{pid}")
    assert rv.status_code == 200
    assert rv.get_json()["is_censored"] == 0


def test_my_status(client):
    eid = _create_active_event(client)
    rv = client.post(f"/api/events/{eid}/request-access", json={"name": "Estado"})
    data = rv.get_json()
    token = data["access_token"]
    pid = data["id"]

    rv = client.get(f"/api/events/{eid}/my-status?token={token}")
    assert rv.status_code == 200
    result = rv.get_json()
    assert result["status"] == "pending"
    assert "approximate_position" in result


def test_participant_leaves_queue(client):
    eid = _create_active_event(client)
    a = client.post(f"/api/events/{eid}/request-access", json={"name": "Primero"}).get_json()
    b = client.post(f"/api/events/{eid}/request-access", json={"name": "Segundo"}).get_json()
    client.post(f"/api/events/{eid}/approve/{a['id']}")
    client.post(f"/api/events/{eid}/approve/{b['id']}")
    rv = client.post(f"/api/events/{eid}/leave?token={a['access_token']}")
    assert rv.status_code == 200
    assert rv.get_json()["status"] == "left"
    queue = client.get(f"/api/events/{eid}/queue").get_json()
    assert [p["id"] for p in queue] == [b["id"]]
    assert queue[0]["queue_position"] == 1


def test_participant_leave_requires_valid_token(client):
    eid = _create_active_event(client)
    assert client.post(f"/api/events/{eid}/leave").status_code == 400
    assert client.post(f"/api/events/{eid}/leave?token=nope").status_code == 404
