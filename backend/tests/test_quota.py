from fastapi.testclient import TestClient

from app import quota
from app.auth import User, current_user
from app.main import app, get_trip_writer


class FakeResponse:
    def __init__(self, data):
        self.data = data

    def raise_for_status(self):
        pass

    def json(self):
        return self.data


def test_message_de_limite():
    assert quota.limit_message("scan", "free", 5) == (
        "Tu as utilisé tes 5 scans de tickets du mois avec l'offre Gratuit. "
        "Passe à l'offre Plus pour profiter de 30 scans de tickets par mois."
    )
    assert "illimités" in quota.limit_message("trip", "pro", 40)
    assert "Passe" not in quota.limit_message("trip", "premium", 40)


def test_quota_atteint_refuse_en_402(monkeypatch):
    calls = []

    def fake_rpc(user, name, feature):
        calls.append(name)
        return FakeResponse({"allowed": False, "plan": "free", "used": 2, "limit": 2})

    monkeypatch.setattr(quota, "_rpc", fake_rpc)
    app.dependency_overrides[current_user] = lambda: User(id="u1", token="t")
    app.dependency_overrides[get_trip_writer] = lambda: None
    body = {"stops": [{"id": "a", "name": "A", "latitude": 48.8, "longitude": 2.3}]}
    r = TestClient(app).post("/trips/optimize", json=body)
    app.dependency_overrides.clear()
    assert r.status_code == 402
    assert r.json()["detail"]["feature"] == "trip"
    assert "2 organisations de trajet" in r.json()["detail"]["message"]
    assert calls == ["ai_quota"]  # rien n'est compté quand c'est refusé


def test_supabase_injoignable_laisse_passer(monkeypatch):
    def broken(user, name, feature):
        raise OSError("réseau coupé")

    monkeypatch.setattr(quota, "_rpc", broken)
    quota.check(User(id="u1", token="t"), "scan")  # ne lève rien
    quota.record(User(id="u1", token="t"), "scan")
