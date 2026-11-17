from fastapi.testclient import TestClient

import localdash.main as main


def test_health():
    response = TestClient(main.create_app()).get("/api/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "version": main.VERSION}


def test_system(monkeypatch):
    monkeypatch.setattr(main, "collect_metrics", lambda: {"cpu_percent": 12.5})
    response = TestClient(main.create_app()).get("/api/system")
    assert response.status_code == 200
    assert response.json() == {"cpu_percent": 12.5}


def test_services(monkeypatch):
    monkeypatch.setattr(main, "list_services", lambda: [{"name": "localdash.service"}])
    response = TestClient(main.create_app()).get("/api/services")
    assert response.status_code == 200
    assert response.json() == {"services": [{"name": "localdash.service"}]}


def test_spa_serves_index_and_assets(tmp_path):
    (tmp_path / "index.html").write_text("<h1>LocalDash</h1>", encoding="utf-8")
    assets = tmp_path / "assets"
    assets.mkdir()
    (assets / "app.js").write_text("console.log(1)", encoding="utf-8")
    client = TestClient(main.create_app(tmp_path))

    root = client.get("/")
    assert root.status_code == 200
    assert "LocalDash" in root.text

    asset = client.get("/assets/app.js")
    assert asset.status_code == 200
    assert asset.text == "console.log(1)"


def test_spa_fallback_for_unknown_path(tmp_path):
    (tmp_path / "index.html").write_text("<h1>LocalDash</h1>", encoding="utf-8")
    response = TestClient(main.create_app(tmp_path)).get("/dashboard/settings")
    assert response.status_code == 200
    assert "LocalDash" in response.text
