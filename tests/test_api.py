import importlib

import pytest


@pytest.fixture
def client(monkeypatch):
    # Reload the app module per-test so APP_VERSION/FAIL_RATE env changes
    # (module-level constants) actually take effect -- Flask app objects
    # don't re-read the environment after import.
    monkeypatch.setenv("APP_VERSION", "v-test")
    monkeypatch.setenv("FAIL_RATE", "0")
    from app import main

    importlib.reload(main)
    with main.app.test_client() as c:
        yield c


def test_index_reports_its_own_version(client):
    resp = client.get("/")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["version"] == "v-test"
    assert "pod" in body


def test_healthz_is_always_ok_regardless_of_fail_rate(monkeypatch):
    # This is the behavior the whole canary demo depends on: healthz must
    # stay green even when FAIL_RATE is cranked up, so a "bad" canary still
    # receives traffic long enough for the analysis to catch it via metrics
    # rather than being pulled out of rotation by its own liveness probe.
    monkeypatch.setenv("APP_VERSION", "v-bad")
    monkeypatch.setenv("FAIL_RATE", "1")
    from app import main

    importlib.reload(main)
    with main.app.test_client() as c:
        resp = c.get("/healthz")
        assert resp.status_code == 200
        assert resp.get_json()["status"] == "ok"


def test_fail_rate_one_always_fails_index(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "v-bad")
    monkeypatch.setenv("FAIL_RATE", "1")
    from app import main

    importlib.reload(main)
    with main.app.test_client() as c:
        resp = c.get("/")
        assert resp.status_code == 500


def test_metrics_endpoint_exposes_prometheus_format(client):
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert b"shrtn_requests_total" in resp.data


def test_metrics_count_requests(client):
    client.get("/")
    client.get("/")
    resp = client.get("/metrics")
    text = resp.data.decode()
    assert 'shrtn_requests_total{' in text
