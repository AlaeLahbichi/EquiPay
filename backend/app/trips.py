"""Organisation du trajet d'un voyage : meilleur ordre de visite jour par jour, puis texte rédigé par l'IA.

  1. temps de trajet réels entre les lieux : OSRM (routing.openstreetmap.de, gratuit), à pied, à vélo
     ou en voiture. Sans réponse d'OSRM : estimation à vol d'oiseau, signalée comme telle.
  2. ordre de visite : un algorithme (pas l'IA). Les lieux datés restent sur leur jour, les autres vont sur
     le jour le plus proche ; dans chaque jour, l'ordre qui minimise le temps de trajet en gardant
     les heures fixées dans l'ordre. Toutes les combinaisons jusqu'à 8 lieux, sinon plus proche voisin + 2-opt.
  3. texte : Qwen3-4B (MLX 4 bits, modèle de base du cache Hugging Face) reçoit l'ordre et les temps
     calculés et les met en mots. Il ne calcule jamais rien.
"""

import datetime as dt
import itertools
import logging
import math
import re
import threading
import time
from dataclasses import dataclass, field

import httpx

from . import config

log = logging.getLogger("equipay.trips")

# Profils OSRM des serveurs routing.openstreetmap.de
OSRM_PROFILES = {"walking": ("routed-foot", "foot"), "cycling": ("routed-bike", "bike"), "driving": ("routed-car", "driving")}
# Estimation sans OSRM : vitesse moyenne (km/h) et détour des rues par rapport à la ligne droite
FALLBACK_SPEED = {"walking": 4.5, "cycling": 14.0, "driving": 28.0}
DETOUR = 1.35
MODE_LABELS = {"walking": "à pied", "cycling": "à vélo", "driving": "en voiture"}

VISIT_MINUTES = 90  # durée d'une visite pour proposer les heures
DAY_START = dt.time(9, 0)
EXACT_LIMIT = 8  # au-delà, l'ordre est cherché par heuristique


@dataclass
class Stop:
    id: str
    name: str
    latitude: float
    longitude: float
    place: str | None = None
    date: dt.date | None = None
    time: dt.time | None = None
    up: int = 0
    down: int = 0


@dataclass
class DayPlan:
    date: dt.date | None
    order: list[int]  # indices dans la liste des lieux retenus
    seconds: float = 0
    legs: list[float] = field(default_factory=list)  # durée vers le lieu suivant (s)
    meters: list[float] = field(default_factory=list)
    times: list[dt.time] = field(default_factory=list)  # heure fixée ou proposée


# ---------- 1. Temps de trajet ----------


def haversine_m(a: Stop, b: Stop) -> float:
    r = 6_371_000
    p1, p2 = math.radians(a.latitude), math.radians(b.latitude)
    dp, dl = p2 - p1, math.radians(b.longitude - a.longitude)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def estimated_matrix(stops: list[Stop], mode: str) -> tuple[list[list[float]], list[list[float]]]:
    meters = [[haversine_m(a, b) * DETOUR for b in stops] for a in stops]
    speed = FALLBACK_SPEED[mode] * 1000 / 3600
    return [[m / speed for m in row] for row in meters], meters


def osrm_matrix(stops: list[Stop], mode: str, client: httpx.Client | None = None) -> tuple[list[list[float]], list[list[float]]]:
    """Durées (s) et distances (m) entre tous les lieux, en une seule requête OSRM « table »."""
    server, profile = OSRM_PROFILES[mode]
    coords = ";".join(f"{s.longitude:.6f},{s.latitude:.6f}" for s in stops)
    url = f"{config.OSRM_URL}/{server}/table/v1/{profile}/{coords}"
    http = client or httpx.Client(timeout=15, headers={"User-Agent": "EquiPay (student project)"})
    try:
        res = http.get(url, params={"annotations": "duration,distance"})
        res.raise_for_status()
        data = res.json()
    finally:
        if client is None:
            http.close()
    if data.get("code") != "Ok":
        raise RuntimeError(f"OSRM : {data.get('code')}")
    durations, distances = data["durations"], data["distances"]
    # Une paire sans itinéraire (île, zone non couverte) : estimation pour cette paire
    est_d, est_m = estimated_matrix(stops, mode)
    n = len(stops)
    durations = [[durations[i][j] if durations[i][j] is not None else est_d[i][j] for j in range(n)] for i in range(n)]
    distances = [[distances[i][j] if distances[i][j] is not None else est_m[i][j] for j in range(n)] for i in range(n)]
    return durations, distances


# ---------- 2. Ordre de visite ----------


def path_cost(order: list[int], d: list[list[float]]) -> float:
    return sum(d[a][b] for a, b in itertools.pairwise(order))


def respects_times(order: list[int], stops: list[Stop]) -> bool:
    """Les lieux avec une heure fixée restent dans l'ordre de leurs heures."""
    timed = [stops[i].time for i in order if stops[i].time is not None]
    return all(a <= b for a, b in itertools.pairwise(timed))


def best_order(indices: list[int], stops: list[Stop], d: list[list[float]]) -> list[int]:
    """Ordre de visite d'une journée qui minimise le temps de trajet (chemin ouvert)."""
    if len(indices) <= 2:
        return sorted(indices, key=lambda i: (stops[i].time is None, stops[i].time or dt.time()))
    if len(indices) <= EXACT_LIMIT:
        best, best_cost = None, math.inf
        for perm in itertools.permutations(indices):
            if not respects_times(list(perm), stops):
                continue
            cost = path_cost(list(perm), d)
            if cost < best_cost - 1e-9:
                best, best_cost = list(perm), cost
        return best or list(indices)
    # Heuristique : plus proche voisin depuis chaque départ, puis améliorations 2-opt
    best, best_cost = list(indices), math.inf
    for start in indices:
        order, rest = [start], set(indices) - {start}
        while rest:
            nxt = min(rest, key=lambda j: d[order[-1]][j])
            order.append(nxt)
            rest.remove(nxt)
        improved = True
        while improved:
            improved = False
            for i in range(1, len(order) - 1):
                for k in range(i + 1, len(order)):
                    candidate = order[:i] + order[i : k + 1][::-1] + order[k + 1 :]
                    if path_cost(candidate, d) < path_cost(order, d) - 1e-9 and respects_times(candidate, stops):
                        order, improved = candidate, True
        if respects_times(order, stops) and path_cost(order, d) < best_cost:
            best, best_cost = order, path_cost(order, d)
    return best


def split_days(stops: list[Stop], d: list[list[float]], max_per_day: int | None) -> dict[dt.date | None, list[int]]:
    """Lieux datés sur leur jour ; lieux sans date sur le jour dont un lieu est le plus proche
    (en respectant le maximum par jour). Sans aucune date : un seul jour."""
    days: dict[dt.date | None, list[int]] = {}
    for i, s in enumerate(stops):
        if s.date is not None:
            days.setdefault(s.date, []).append(i)
    undated = [i for i, s in enumerate(stops) if s.date is None]
    if not days:
        return {None: undated} if undated else {}
    # Les plus appréciés sont placés en premier
    for i in sorted(undated, key=lambda i: -(stops[i].up - stops[i].down)):
        open_days = [day for day, idx in days.items() if max_per_day is None or len(idx) < max_per_day]
        if not open_days:
            days.setdefault(None, []).append(i)  # plus de place : « à caser »
            continue
        day = min(open_days, key=lambda day: min(d[j][i] for j in days[day]))
        days[day].append(i)
    return days


def suggest_times(order: list[int], stops: list[Stop], legs: list[float]) -> list[dt.time]:
    """Heure de chaque visite : l'heure fixée si elle existe, sinon après la visite précédente et le trajet."""
    times, clock = [], dt.datetime.combine(dt.date.today(), DAY_START)
    for k, i in enumerate(order):
        fixed = stops[i].time
        if fixed is not None:
            clock = dt.datetime.combine(clock.date(), fixed)
        else:
            # Arrondi au quart d'heure suivant
            minutes = (clock.minute + 14) // 15 * 15
            clock = clock.replace(minute=0, second=0) + dt.timedelta(minutes=minutes)
        times.append(clock.time())
        if k < len(legs):
            clock += dt.timedelta(minutes=VISIT_MINUTES, seconds=legs[k])
    return times


def plan_days(stops: list[Stop], d: list[list[float]], m: list[list[float]], max_per_day: int | None) -> list[DayPlan]:
    plans = []
    for date, indices in split_days(stops, d, max_per_day).items():
        order = best_order(indices, stops, d)
        legs = [d[a][b] for a, b in itertools.pairwise(order)]
        plan = DayPlan(date=date, order=order, seconds=sum(legs), legs=legs, meters=[m[a][b] for a, b in itertools.pairwise(order)])
        plan.times = suggest_times(order, stops, legs)
        plans.append(plan)
    plans.sort(key=lambda p: (p.date is None, p.date or dt.date.min))
    return plans


def current_seconds(stops: list[Stop], d: list[list[float]]) -> float:
    """Temps de trajet du programme tel qu'il est (ordre chronologique, jour par jour)."""
    total = 0.0
    by_day: dict[dt.date | None, list[int]] = {}
    for i, s in enumerate(stops):
        by_day.setdefault(s.date, []).append(i)
    for indices in by_day.values():
        indices.sort(key=lambda i: (stops[i].time is None, stops[i].time or dt.time()))
        total += path_cost(indices, d)
    return total


# ---------- 3. Texte de l'IA ----------

SYSTEM = (
    "Tu es l'organisateur de voyages de l'application EquiPay. On te donne un programme déjà calculé : "
    "l'ordre des visites, les heures et les temps de trajet sont exacts et définitifs. Rédige en français, "
    "en tutoyant le groupe, un court programme jour par jour (2 à 4 phrases par jour) qui explique pourquoi "
    "cet ordre fait gagner du temps et donne un ou deux conseils pratiques. Ne change jamais l'ordre, les heures "
    "ni les durées, et n'invente aucun lieu ni aucune distance. Pas de titre, pas de liste à puces, pas de markdown."
)


def fmt_duration(seconds: float) -> str:
    minutes = max(1, round(seconds / 60))
    return f"{minutes} min" if minutes < 60 else f"{minutes // 60} h {minutes % 60:02d}"


def llm_message(stops: list[Stop], plans: list[DayPlan], mode: str, saved: float, excluded: list[Stop], notes: str | None) -> str:
    lines = [f"Déplacements {MODE_LABELS[mode]}. Temps gagné par rapport au programme actuel : {fmt_duration(saved)}."]
    for p in plans:
        title = "Lieux à caser (aucun jour disponible)" if p.date is None and len(plans) > 1 else (
            f"Jour du {p.date.strftime('%d/%m/%Y')}" if p.date else "Journée"
        )
        lines.append(f"\n{title} :")
        for k, i in enumerate(p.order):
            s = stops[i]
            votes = f" (votes : {s.up} pour, {s.down} contre)" if s.up or s.down else ""
            lines.append(f"- {p.times[k].strftime('%H:%M')} {s.name}{f' ({s.place})' if s.place and s.place != s.name else ''}{votes}")
            if k < len(p.legs):
                lines.append(f"  puis {fmt_duration(p.legs[k])} de trajet ({p.meters[k] / 1000:.1f} km)")
    if excluded:
        lines.append("\nÉcartés car le groupe a voté plutôt contre : " + ", ".join(s.name for s in excluded) + ".")
    if notes:
        lines.append(f"\nConsigne du groupe : {notes}")
    return "\n".join(lines)


class TripWriter:
    """Qwen3-4B (MLX 4 bits), chargé au premier usage."""

    def __init__(self, model: str | None = None) -> None:
        self.model_name = model or config.TRIP_MODEL
        self._model = None
        self._tokenizer = None
        self._lock = threading.Lock()
        self.version: str | None = None
        self.error: str | None = None

    @property
    def ready(self) -> bool:
        return self._model is not None

    def load(self) -> None:
        try:
            from mlx_lm import load

            start = time.perf_counter()
            self._model, self._tokenizer = load(self.model_name)
            self.version = self.model_name.split("/")[-1]
            self.error = None
            log.info("Organisation du trajet prête : %s (%.1fs)", self.version, time.perf_counter() - start)
        except Exception as e:  # modèle absent du cache, mémoire…
            self._model = None
            self.error = f"{type(e).__name__}: {e}"
            log.error("Texte du trajet indisponible : %s", self.error)

    def write(self, message: str) -> str:
        from mlx_lm import generate

        with self._lock:
            if not self.ready:
                self.load()
            if not self.ready:
                raise RuntimeError(self.error or "Modèle indisponible")
            prompt = self._tokenizer.apply_chat_template(
                [{"role": "system", "content": SYSTEM}, {"role": "user", "content": message}],
                add_generation_prompt=True,
                tokenize=False,
            )
            text = generate(self._model, self._tokenizer, prompt=prompt, max_tokens=500, verbose=False)
        text = re.sub(r"<think>.*?</think>", "", text, flags=re.S)
        return re.sub(r"[*#]+", "", text).strip()


# ---------- Tout ensemble ----------


def optimize(
    stops: list[Stop],
    mode: str,
    max_per_day: int | None,
    notes: str | None,
    writer: TripWriter | None,
    matrix=None,
) -> dict:
    excluded = [s for s in stops if s.down > s.up]
    kept = [s for s in stops if s.down <= s.up]
    if not kept:
        raise ValueError("Aucun lieu à organiser : ajoute des lieux avec une adresse trouvée sur la carte.")
    estimated = False
    try:
        d, m = (matrix or osrm_matrix)(kept, mode) if len(kept) > 1 else estimated_matrix(kept, mode)
    except Exception as e:  # OSRM injoignable : estimation, signalée à l'utilisateur
        log.warning("OSRM indisponible (%s) : temps estimés", e)
        d, m = estimated_matrix(kept, mode)
        estimated = True
    plans = plan_days(kept, d, m, max_per_day)
    total = sum(p.seconds for p in plans)
    before = current_seconds(kept, d)
    saved = max(0.0, before - total)

    text, text_error = None, None
    if writer is not None:
        try:
            text = writer.write(llm_message(kept, plans, mode, saved, excluded, notes))
        except Exception as e:  # le programme calculé reste utile sans le texte
            text_error = str(e)
            log.error("Texte du trajet non rédigé : %s", e)

    return {
        "mode": mode,
        "estimated": estimated,
        "total_seconds": round(total),
        "current_seconds": round(before),
        "saved_seconds": round(saved),
        "days": [
            {
                "date": p.date.isoformat() if p.date else None,
                "travel_seconds": round(p.seconds),
                "stops": [
                    {
                        "id": kept[i].id,
                        "name": kept[i].name,
                        "time": p.times[k].strftime("%H:%M"),
                        "time_fixed": kept[i].time is not None,
                        "date_assigned": kept[i].date is None and p.date is not None,
                        "next_seconds": round(p.legs[k]) if k < len(p.legs) else None,
                        "next_meters": round(p.meters[k]) if k < len(p.meters) else None,
                    }
                    for k, i in enumerate(p.order)
                ],
            }
            for p in plans
        ],
        "excluded": [{"id": s.id, "name": s.name} for s in excluded],
        "summary": text,
        "summary_error": text_error,
        "model_version": writer.version if writer and text else None,
    }
