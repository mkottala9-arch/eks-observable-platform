import pytest
from app import app, index_response

@pytest.fixture
def client():
    app.config["TESTING"] = True

    with app.test_client() as test_client:
        yield test_client


def test_healthz_returns_200(client):
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.data == b"OK"


def test_readyz_returns_200(client):
    response = client.get("/readyz")

    assert response.status_code == 200
    assert response.data == b"Ready"


def test_version_contains_expected_fields(client):
    response = client.get("/version")
    data = response.get_json()

    assert response.status_code == 200
    assert "version" in data
    assert "commit" in data
    assert "environment" in data


def test_index_response_when_fault_mode_false():
    body, status = index_response(False)

    assert status == 200
    assert body == "OK"


def test_index_response_when_fault_mode_true():
    body, status = index_response(True)

    assert status == 500
    assert body == "Internal Server Error"


def test_metrics_endpoint_returns_200(client):
    response = client.get("/metrics")

    assert response.status_code == 200
    assert b"app_build_info" in response.data
    assert b"app_fault_mode" in response.data
    assert b"app_requests_total" in response.data
    assert b"app_request_latency_seconds" in response.data