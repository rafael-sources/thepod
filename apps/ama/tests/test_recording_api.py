"""Tests for recording_api blueprint — mocks LiveKit egress calls."""

from unittest.mock import patch, MagicMock


def _create_active_event(client):
    rv = client.post("/api/events", json={"title": "Rec Event"})
    eid = rv.get_json()["id"]
    client.post(f"/api/events/{eid}/start")
    return eid


def test_start_recording(client):
    eid = _create_active_event(client)
    mock_result = MagicMock()
    mock_result.egress_id = "egress_123"
    with patch("recording_api.start_recording_egress", return_value=mock_result):
        rv = client.post(f"/api/events/{eid}/recording/start")
    assert rv.status_code == 200
    data = rv.get_json()
    assert data["egress_id"] == "egress_123"


def test_start_requires_active_event(client):
    rv = client.post("/api/events", json={"title": "No activo"})
    eid = rv.get_json()["id"]
    rv = client.post(f"/api/events/{eid}/recording/start")
    assert rv.status_code == 400


def test_stop_recording(client):
    eid = _create_active_event(client)
    mock_result = MagicMock()
    mock_result.egress_id = "egress_456"
    with patch("recording_api.start_recording_egress", return_value=mock_result):
        client.post(f"/api/events/{eid}/recording/start")
    with patch("recording_api.stop_egress", return_value=None):
        rv = client.post(f"/api/events/{eid}/recording/stop")
    assert rv.status_code == 200
    assert rv.get_json()["stopped"] is True


def test_recording_status(client):
    eid = _create_active_event(client)
    rv = client.get(f"/api/events/{eid}/recording/status")
    assert rv.status_code == 200
    data = rv.get_json()
    assert data["recording"] is False
    assert data["egress_id"] is None
