"""Organisation du trajet : algorithme d'ordre, répartition par jour, route /trips/optimize (sans réseau ni modèle)."""

import datetime as dt

from fastapi.testclient import TestClient

from app import trips
from app.auth import User, current_user
from app.main import app, get_trip_writer
from app.trips import Stop, best_order, estimated_matrix, optimize, path_cost, split_days

# Rabat : 4 lieux le long d'une ligne ouest → est
OUDAYAS = Stop("o", "Kasbah des Oudayas", 34.0313, -6.8358)
MEDINA = Stop("m", "Médina", 34.0270, -6.8300)
HASSAN = Stop("h", "Tour Hassan", 34.0240, -6.8226)
AGDAL = Stop("a", "Emsi Agdal", 34.0062, -6.8458)


def matrix(stops):
    return estimated_matrix(stops, "walking")


def test_ordre_optimal_teste_toutes_les_combinaisons():
    # Donnés dans le désordre : l'ordre optimal suit la ligne (Agdal en bout, le plus au sud)
    stops = [HASSAN, OUDAYAS, AGDAL, MEDINA]
    d, _ = matrix(stops)
    order = best_order(list(range(4)), stops, d)
    names = [stops[i].name for i in order]
    assert path_cost(order, d) <= path_cost([0, 1, 2, 3], d)
    assert names.index("Médina") in (1, 2)  # au milieu du parcours, jamais aux extrémités
    assert {names[0], names[-1]} & {"Emsi Agdal", "Tour Hassan", "Kasbah des Oudayas"}


def test_les_heures_fixees_restent_dans_l_ordre():
    stops = [
        Stop("o", "Oudayas", OUDAYAS.latitude, OUDAYAS.longitude, time=dt.time(9, 0)),
        Stop("h", "Hassan", HASSAN.latitude, HASSAN.longitude, time=dt.time(8, 0)),
        MEDINA,
    ]
    d, _ = matrix(stops)
    order = best_order([0, 1, 2], stops, d)
    timed = [stops[i].name for i in order if stops[i].time]
    assert timed == ["Hassan", "Oudayas"]


def test_heuristique_au_dela_de_8_lieux():
    stops = [Stop(str(i), f"L{i}", 34.0 + 0.01 * (i % 5), -6.8 - 0.01 * (i // 5)) for i in range(11)]
    d, _ = matrix(stops)
    order = best_order(list(range(11)), stops, d)
    assert sorted(order) == list(range(11))
    assert path_cost(order, d) < path_cost(list(range(11)), d)


def test_lieux_sans_date_sur_le_jour_le_plus_proche_avec_maximum():
    d1, d2 = dt.date(2026, 10, 20), dt.date(2026, 10, 21)
    stops = [
        Stop("o", "Oudayas", OUDAYAS.latitude, OUDAYAS.longitude, date=d1),
        Stop("a", "Agdal", AGDAL.latitude, AGDAL.longitude, date=d2),
        Stop("m", "Médina", MEDINA.latitude, MEDINA.longitude),  # près des Oudayas
        Stop("x", "Près d'Agdal", AGDAL.latitude + 0.001, AGDAL.longitude),
    ]
    d, _ = matrix(stops)
    days = split_days(stops, d, max_per_day=None)
    assert sorted(days[d1]) == [0, 2] and sorted(days[d2]) == [1, 3]
    # Maximum 1 par jour : les lieux sans date restent « à caser »
    days = split_days(stops, d, max_per_day=1)
    assert sorted(days[None]) == [2, 3]


def test_optimize_ecarte_les_lieux_votes_contre_et_compte_le_gain():
    day = dt.date(2026, 10, 20)
    # Programme actuel en zigzag : Oudayas → Agdal → Médina → Hassan
    stops = [
        Stop("o", "Oudayas", OUDAYAS.latitude, OUDAYAS.longitude, date=day, up=2),
        Stop("a", "Agdal", AGDAL.latitude, AGDAL.longitude, date=day),
        Stop("m", "Médina", MEDINA.latitude, MEDINA.longitude, date=day),
        Stop("h", "Hassan", HASSAN.latitude, HASSAN.longitude, date=day),
        Stop("z", "Zoo", 33.95, -6.89, date=day, up=1, down=3),
    ]

    class Writer:
        version = "faux"

        def write(self, message):
            assert "Zoo" in message and "Écartés" in message  # le modèle sait ce qui a été écarté
            return "**Jour 1** : programme."

    result = optimize(stops, "walking", None, "pas trop tôt", Writer(), matrix=lambda s, mode: matrix(s))
    assert [e["name"] for e in result["excluded"]] == ["Zoo"]
    assert len(result["days"]) == 1 and len(result["days"][0]["stops"]) == 4
    assert result["saved_seconds"] > 0
    assert result["total_seconds"] + result["saved_seconds"] == result["current_seconds"]
    assert result["summary"] == "**Jour 1** : programme."  # nettoyé par le vrai TripWriter, pas par optimize
    first = result["days"][0]["stops"][0]
    assert first["time"] == "09:00" and first["next_seconds"] > 0


def test_osrm_injoignable_temps_estimes():
    def broken(stops, mode):
        raise RuntimeError("réseau")

    result = optimize([OUDAYAS, HASSAN], "driving", None, None, None, matrix=broken)
    assert result["estimated"] is True
    assert result["summary"] is None


class FakeWriter:
    version = "Qwen3-4B-test"

    def write(self, message):
        return "Commencez par la Kasbah."


def test_route_optimize(monkeypatch):
    monkeypatch.setattr(trips, "osrm_matrix", lambda stops, mode: estimated_matrix(stops, mode))
    monkeypatch.setattr("app.main._log_trip_run", lambda *a: None)
    app.dependency_overrides[current_user] = lambda: User(id="u1", token="t")
    app.dependency_overrides[get_trip_writer] = lambda: FakeWriter()
    try:
        client = TestClient(app)
        body = {
            "mode": "walking",
            "stops": [
                {"id": "o", "name": "Kasbah", "latitude": OUDAYAS.latitude, "longitude": OUDAYAS.longitude},
                {"id": "h", "name": "Hassan", "latitude": HASSAN.latitude, "longitude": HASSAN.longitude,
                 "date": "2026-10-20", "time": "10:00:00"},
            ],
        }
        r = client.post("/trips/optimize", json=body)
        assert r.status_code == 200, r.text
        data = r.json()
        assert data["summary"] == "Commencez par la Kasbah."
        assert data["model_version"] == "Qwen3-4B-test"
        stops = data["days"][0]["stops"]
        assert {s["id"] for s in stops} == {"o", "h"}
        assert next(s for s in stops if s["id"] == "o")["date_assigned"] is True
        assert client.post("/trips/optimize", json={**body, "mode": "avion"}).status_code == 422
    finally:
        app.dependency_overrides.clear()


def test_route_optimize_connexion_requise():
    r = TestClient(app).post("/trips/optimize", json={"stops": []})
    assert r.status_code in (401, 422)
