import pytest

from app import main


@pytest.fixture
def client():
    with main.app.test_client() as c:
        yield c


def test_index_reports_its_own_version(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "v-test")
    monkeypatch.setenv("FAIL_RATE", "0")
    resp = client.get("/")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["version"] == "v-test"
    assert "pod" in body


def test_healthz_is_always_ok_regardless_of_fail_rate(client, monkeypatch):
    # This is the behavior the whole canary demo depends on: healthz must
    # stay green even when FAIL_RATE is cranked up, so a "bad" canary still
    # receives traffic long enough for the analysis to catch it via metrics
    # rather than being pulled out of rotation by its own liveness probe.
    monkeypatch.setenv("APP_VERSION", "v-bad")
    monkeypatch.setenv("FAIL_RATE", "1")
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"


def test_fail_rate_one_always_fails_index(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "v-bad")
    monkeypatch.setenv("FAIL_RATE", "1")
    resp = client.get("/")
    assert resp.status_code == 500


def test_fail_rate_zero_never_fails_index(client, monkeypatch):
    monkeypatch.setenv("FAIL_RATE", "0")
    for _ in range(20):
        assert client.get("/").status_code == 200


def test_metrics_endpoint_exposes_prometheus_format(client):
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert b"shrtn_requests_total" in resp.data


def test_metrics_count_requests(client):
    client.get("/")
    client.get("/")
    resp = client.get("/metrics")
    text = resp.data.decode()
    assert "shrtn_requests_total{" in text
