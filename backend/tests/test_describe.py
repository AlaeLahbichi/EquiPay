"""« Décrire la dépense » : correspondance des noms, répartition en %, montant, et route API (sans modèle)."""

import datetime as dt
import json

from fastapi.testclient import TestClient

from app.auth import User, current_user
from app.describe import ExpenseDescriber, member_labels, normalize, to_percentages, user_message
from app.main import app, get_describer

MEMBERS = [
    {"id": "u1", "name": "Alae Lahbichi"},
    {"id": "u2", "name": "Salma Idrissi"},
    {"id": "u3", "name": "Reda"},
    {"id": "u4", "name": "Sara Test"},
    {"id": "u5", "name": "Sara Bennani"},
]
LABELS = member_labels(MEMBERS)


def test_libelles_prenom_ou_nom_complet_si_homonymes():
    assert LABELS == {"u1": "Alae", "u2": "Salma", "u3": "Reda", "u4": "Sara Test", "u5": "Sara Bennani"}
    message = user_message("taxi 20", list(LABELS.values()), "Alae", dt.date(2026, 10, 12), "EUR")
    assert message.splitlines() == [
        "Aujourd'hui : 2026-10-12 (lundi)",
        "Devise de l'activité : EUR",
        "Membres : Alae (moi), Salma, Reda, Sara Test, Sara Bennani",
        "Phrase : taxi 20",
    ]


def test_pourcentages_somme_exacte():
    assert to_percentages({"a": 1, "b": 1, "c": 1}) == {"a": 33.33, "b": 33.33, "c": 33.34}
    assert to_percentages({"a": 3, "b": 1}) == {"a": 75.0, "b": 25.0}
    assert to_percentages({}) is None


def test_noms_moi_fautes_et_parts():
    raw = {"is_expense": True, "title": "Parking", "merchant": None, "amount": 18.78, "currency": "eur",
           "date": "2026-10-11", "paid_by": "moi", "participants": ["moi", "Slma"],
           "split": {"type": "shares", "values": {"moi": 1, "Slma": 4}}, "items": []}
    r = normalize(raw, MEMBERS, "u1", LABELS)
    assert r["paid_by"] == "u1"
    assert r["participants"] == ["u1", "u2"]
    assert r["shares"] == {"u1": 20.0, "u2": 80.0}
    assert r["split_type"] == "shares"
    assert r["currency"] == "EUR"
    assert r["warnings"] == []


def test_montant_absent_somme_des_articles_et_nom_inconnu():
    raw = {"is_expense": True, "title": "Courses", "amount": 0, "currency": None, "date": None,
           "paid_by": "Karim", "participants": ["moi", "reda"], "split": {"type": "equal"},
           "items": [{"label": "Pain", "qty": 2, "price": 3.5}, {"label": "Lait", "qty": None, "price": "1,20"}]}
    r = normalize(raw, MEMBERS, "u1", LABELS)
    assert r["amount"] == 4.7
    assert "Montant calculé à partir des articles" in r["warnings"]
    assert r["paid_by"] is None and r["unknown_names"] == ["Karim"]
    assert r["participants"] == ["u1", "u3"]
    assert r["split_type"] == "equal" and r["shares"] is None
    assert r["items"][1] == {"label": "Lait", "qty": None, "price": 1.2}


def test_montant_absent_sans_articles_et_montants_par_personne():
    r = normalize({"is_expense": True, "amount": 0, "items": []}, MEMBERS, "u1", LABELS)
    assert r["amount"] is None and "Montant non indiqué" in r["warnings"]
    raw = {"is_expense": True, "amount": None, "split": {"type": "amounts", "values": {"moi": 30, "Sara Test": 10}}}
    r = normalize(raw, MEMBERS, "u1", LABELS)
    assert r["amount"] == 40 and r["shares"] == {"u1": 75.0, "u4": 25.0}


def test_phrase_hors_depense_ou_illisible():
    assert normalize({"is_expense": False}, MEMBERS, "u1", LABELS)["is_expense"] is False
    assert normalize(None, MEMBERS, "u1", LABELS)["unreadable"] is True


class FakeDescriber(ExpenseDescriber):
    def __init__(self, answer: dict | None = None, fail: bool = False):
        super().__init__("/nulle/part")
        self.answer, self.fail, self.messages = answer, fail, []
        self.version = "equipay-describe v-test"

    @property
    def ready(self):
        return not self.fail

    def load(self):
        self.error = "absent"

    def generate(self, message):
        self.messages.append(message)
        return json.dumps(self.answer)


client = TestClient(app)


def use(describer):
    app.dependency_overrides.clear()
    app.dependency_overrides[get_describer] = lambda: describer
    app.dependency_overrides[current_user] = lambda: User(id="u1", token="t")


BODY = {"sentence": "resto avec Reda 60/40, j'ai payé 50€ hier", "members": MEMBERS, "currency": "EUR",
        "today": "2026-10-12"}


def test_route_describe():
    fake = FakeDescriber({"is_expense": True, "title": "Restaurant", "amount": 50, "currency": "EUR",
                          "date": "2026-10-11", "paid_by": "moi", "participants": ["moi", "Reda"],
                          "split": {"type": "percent", "values": {"moi": 60, "Reda": 40}}, "items": []})
    use(fake)
    r = client.post("/expenses/describe", json=BODY)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["shares"] == {"u1": 60.0, "u3": 40.0}
    assert body["paid_by"] == "u1" and body["date"] == "2026-10-11"
    assert body["model_version"] == "equipay-describe v-test"
    assert "Membres : Alae (moi), Salma, Reda" in fake.messages[0]
    app.dependency_overrides.clear()


def test_route_describe_erreurs():
    use(FakeDescriber(fail=True))
    assert client.post("/expenses/describe", json=BODY).status_code == 503
    use(FakeDescriber({}))
    other = dict(BODY, members=[{"id": "u9", "name": "Autre"}])
    assert client.post("/expenses/describe", json=other).status_code == 403
    app.dependency_overrides.clear()
    assert client.post("/expenses/describe", json=BODY).status_code == 401
