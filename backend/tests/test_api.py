"""Tests de l'API sans modèle ni Supabase (dépendances remplacées par des faux)."""

from fastapi.testclient import TestClient

from app import chat_store
from app.auth import User, current_user, optional_user
from app.main import app, get_assistant


class FakeAssistant:
    ready, version, error = True, "equipay-assistant v-test", None

    def __init__(self, fail=False):
        self.fail = fail

    def answer(self, question: str) -> str:
        if self.fail:
            raise RuntimeError("MLflow arrêté")
        return f"Réponse à : {question}"


client = TestClient(app)  # sans « with » : le modèle n'est pas chargé


def use(assistant):
    app.dependency_overrides[get_assistant] = lambda: assistant
    app.dependency_overrides[current_user] = lambda: User(id="u1", token="t")
    app.dependency_overrides[optional_user] = lambda: User(id="u1", token="t")


def test_health():
    use(FakeAssistant())
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["assistant"]["ready"] is True


def test_chat_sans_connexion_repond_sans_enregistrer(monkeypatch):
    saved = []
    monkeypatch.setattr(chat_store, "save_exchange", lambda *a: saved.append(a))
    app.dependency_overrides.clear()
    app.dependency_overrides[get_assistant] = lambda: FakeAssistant()
    r = client.post("/chat", json={"message": "Bonjour"})
    assert r.status_code == 200
    assert saved == []  # visiteur anonyme : rien n'est enregistré


def test_chat_jeton_invalide_refuse():
    app.dependency_overrides.clear()
    app.dependency_overrides[get_assistant] = lambda: FakeAssistant()
    r = client.post("/chat", json={"message": "Bonjour"}, headers={"Authorization": "Bearer faux"})
    assert r.status_code == 401


def test_historique_exige_connexion():
    app.dependency_overrides.clear()
    assert client.get("/chat/history").status_code == 401


def test_chat_repond_et_enregistre(monkeypatch):
    saved = []
    monkeypatch.setattr(chat_store, "save_exchange", lambda *a: saved.append(a))
    use(FakeAssistant())
    r = client.post("/chat", json={"message": "  Comment rejoindre ?  "})
    assert r.status_code == 200
    assert r.json()["answer"] == "Réponse à : Comment rejoindre ?"
    assert r.json()["model_version"] == "equipay-assistant v-test"
    assert saved and saved[0][1] == "Comment rejoindre ?"


def test_chat_message_vide_refuse():
    use(FakeAssistant())
    assert client.post("/chat", json={"message": ""}).status_code == 422


def test_chat_assistant_indisponible(monkeypatch):
    monkeypatch.setattr(chat_store, "save_exchange", lambda *a: None)
    use(FakeAssistant(fail=True))
    r = client.post("/chat", json={"message": "Bonjour"})
    assert r.status_code == 503


# ------------------------------------------------------------------ scanner de reçus

from app.main import get_receipts  # noqa: E402
from app.receipts import normalize  # noqa: E402


class FakeScanner:
    ready, version, error = True, "equipay-receipt v-test", None

    def __init__(self, fail=None):
        self.fail = fail

    def scan(self, data: bytes) -> dict:
        if self.fail:
            raise self.fail
        return {"ok": True, **normalize({"merchant": "CAFE", "amount": 11.5, "amount_text": "11,50", "currency": "eur",
                                         "date": "2026-10-10", "items": [{"label": "Cafe", "qty": 2, "price": 11.5}]})}


def test_scan_exige_connexion():
    app.dependency_overrides.clear()
    app.dependency_overrides[get_receipts] = lambda: FakeScanner()
    r = client.post("/receipts/scan", files={"file": ("t.jpg", b"x", "image/jpeg")})
    assert r.status_code == 401


def test_scan_renvoie_les_champs():
    use(FakeAssistant())
    app.dependency_overrides[get_receipts] = lambda: FakeScanner()
    r = client.post("/receipts/scan", files={"file": ("t.jpg", b"x", "image/jpeg")})
    assert r.status_code == 200
    body = r.json()
    assert body["amount"] == 11.5 and body["currency"] == "EUR" and body["date"] == "2026-10-10"
    assert body["checks"] == {"amount_matches_text": True, "items_sum": 11.5, "items_match_total": True}
    assert body["model_version"] == "equipay-receipt v-test"


def test_scan_indisponible_503():
    use(FakeAssistant())
    app.dependency_overrides[get_receipts] = lambda: FakeScanner(fail=RuntimeError("pas de modèle"))
    r = client.post("/receipts/scan", files={"file": ("t.jpg", b"x", "image/jpeg")})
    assert r.status_code == 503


def test_normalize_nettoie_les_valeurs_douteuses():
    import datetime as dt

    out = normalize({"amount": "1.250,50", "amount_text": "1.250,50 €", "currency": "euro", "date": "2031-01-01",
                     "items": [{"label": "A", "price": "x"}, {"label": "B", "qty": -1, "price": "3,5"}]},
                    today=dt.date(2026, 10, 11))
    assert out["amount"] == 1250.5
    assert out["currency"] is None  # pas un code ISO à 3 lettres
    assert out["date"] is None  # date dans le futur
    assert out["items"] == [{"label": "B", "qty": None, "price": 3.5}]
    assert out["checks"]["amount_matches_text"] is True
    assert normalize(None)["amount"] is None
