"""Tests for integrations blueprint."""

from config import INTEGRATION_SECRET


def test_create_event_from_prodpod(anon_client):
    rv = anon_client.post(
        "/api/integrations/prodpod/create-event",
        json={"title": "Desde prodPod", "host_username": "admin"},
        headers={"X-PodPod-Secret": INTEGRATION_SECRET},
    )
    assert rv.status_code == 201
    data = rv.get_json()
    assert "event_id" in data
    assert "embed_url" in data


def test_create_event_requires_secret(anon_client):
    rv = anon_client.post(
        "/api/integrations/prodpod/create-event",
        json={"title": "Sin secret"},
    )
    assert rv.status_code == 401


def test_export_requires_auth(anon_client):
    rv = anon_client.post(
        "/api/integrations/postpod/export",
        json={"event_id": 1},
    )
    assert rv.status_code == 401
