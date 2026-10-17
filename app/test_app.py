import app as quote_app

client = quote_app.app.test_client()


def test_healthz():
    assert client.get("/healthz").status_code == 200


def test_readyz():
    assert client.get("/readyz").status_code == 200


def test_quote_returns_json():
    resp = client.get("/api/quote")
    assert resp.status_code == 200
    assert resp.get_json()["quote"] in quote_app.QUOTES


def test_metrics_exposes_custom_counter():
    client.get("/api/quote")
    body = client.get("/metrics").get_data(as_text=True)
    assert "quotes_served_total" in body
    assert 'http_requests_total{method="GET",path="/api/quote",status="200"}' in body
