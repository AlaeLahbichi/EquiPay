"""« Décrire la dépense » : une phrase libre → les champs de la dépense (modèle equipay-describe).

Le modèle (Qwen3-4B affiné, converti en MLX 4 bits) est lu dans model/equipay-describe/mlx_model.
Il répond avec des prénoms et « moi » ; on les relie ici aux membres de l'activité (identifiants),
et la répartition est convertie en pourcentages. Rien n'est créé : l'app pré-remplit le formulaire.
"""

import datetime as dt
import difflib
import json
import logging
import re
import threading
import time
import unicodedata
from pathlib import Path

from . import config
from .receipts import parse_json, to_number

log = logging.getLogger("equipay.describe")

WEEKDAYS = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
SPLIT_TYPES = {"equal", "percent", "amounts", "shares"}


def norm(text) -> str:
    """« Élodie » → « elodie » (sans accents ni ponctuation)."""
    text = unicodedata.normalize("NFKD", str(text or "")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"\s+", " ", re.sub(r"[^\w]+", " ", text)).strip()


def member_labels(members: list[dict]) -> dict[str, str]:
    """Nom montré au modèle pour chaque membre : son prénom, ou son nom complet si le prénom est partagé."""
    first = {m["id"]: (m["name"].split() or [m["name"]])[0] for m in members}
    counts: dict[str, int] = {}
    for name in first.values():
        counts[norm(name)] = counts.get(norm(name), 0) + 1
    return {m["id"]: (first[m["id"]] if counts[norm(first[m["id"]])] == 1 else m["name"]) for m in members}


def user_message(sentence: str, labels: list[str], me: str, today: dt.date, currency: str) -> str:
    """Même format qu'à l'entraînement (ml/describe/schema.py)."""
    names = ", ".join(f"{m} (moi)" if m == me else m for m in labels)
    return (
        f"Aujourd'hui : {today.isoformat()} ({WEEKDAYS[today.weekday()]})\n"
        f"Devise de l'activité : {currency}\n"
        f"Membres : {names}\n"
        f"Phrase : {sentence}"
    )


class MemberMatcher:
    """Relie un nom écrit par le modèle (« moi », « Slma », « reda ») à l'identifiant d'un membre."""

    def __init__(self, members: list[dict], me_id: str, labels: dict[str, str]):
        self.me_id = me_id
        self.keys: list[tuple[str, str]] = []  # (nom normalisé, id)
        for m in members:
            for key in {norm(labels[m["id"]]), norm(m["name"]), norm(m["name"]).split(" ")[0]}:
                if key:
                    self.keys.append((key, m["id"]))

    def __call__(self, name) -> str | None:
        key = norm(name)
        if not key:
            return None
        if key in ("moi", "me", "ana", "je"):
            return self.me_id
        exact = {mid for k, mid in self.keys if k == key}
        if len(exact) == 1:
            return exact.pop()
        # Faute de frappe (« Slma » → Salma) : le nom le plus proche, s'il est assez proche et sans ambiguïté
        scored = sorted(((difflib.SequenceMatcher(None, key, k).ratio(), mid) for k, mid in self.keys), reverse=True)
        if scored and scored[0][0] >= 0.75 and all(mid == scored[0][1] for r, mid in scored if r >= scored[0][0] - 0.05):
            return scored[0][1]
        return None


def to_percentages(weights: dict[str, float]) -> dict[str, float] | None:
    """Poids (parts, montants, %) → pourcentages au centième dont la somme fait exactement 100."""
    weights = {k: v for k, v in weights.items() if v > 0}
    total = sum(weights.values())
    if not weights or total <= 0:
        return None
    ids = list(weights)
    cents = [round(weights[i] / total * 10000) for i in ids]
    cents[-1] += 10000 - sum(cents)
    return {i: c / 100 for i, c in zip(ids, cents)}


def normalize(raw: dict | None, members: list[dict], me_id: str, labels: dict[str, str]) -> dict:
    """Réponse brute du modèle → champs du formulaire (identifiants des membres, pourcentages)."""
    warnings: list[str] = []
    unknown: list[str] = []
    if raw is None:
        return {"is_expense": False, "unreadable": True, "warnings": ["Phrase non comprise"], "unknown_names": []}
    match = MemberMatcher(members, me_id, labels)

    def resolve(name):
        member = match(name)
        if member is None and isinstance(name, str) and name.strip() and name not in unknown:
            unknown.append(name.strip())
        return member

    if raw.get("is_expense") is False:
        return {"is_expense": False, "unreadable": False, "warnings": [], "unknown_names": []}

    def text(key, limit=120):
        value = raw.get(key)
        return " ".join(value.split())[:limit] if isinstance(value, str) and value.strip() else None

    # Articles : « price » est le prix de la ligne (quantité comprise)
    items = []
    for item in raw.get("items") or []:
        if not isinstance(item, dict) or not isinstance(item.get("label"), str):
            continue
        qty = to_number(item.get("qty"))
        items.append({
            "label": " ".join(item["label"].split())[:80],
            "qty": int(qty) if qty and qty == int(qty) and qty > 0 else None,
            "price": to_number(item.get("price")),
        })

    amount = to_number(raw.get("amount"))
    if not amount or amount <= 0:
        priced = [i["price"] for i in items if i["price"]]
        amount = round(sum(priced), 2) if priced else None
        warnings.append("Montant calculé à partir des articles" if amount else "Montant non indiqué")

    currency = raw.get("currency")
    currency = currency.upper() if isinstance(currency, str) and re.fullmatch(r"[A-Za-z]{3}", currency) else None

    date = None
    if isinstance(raw.get("date"), str):
        try:
            date = dt.date.fromisoformat(raw["date"]).isoformat()
        except ValueError:
            pass

    paid_by = resolve(raw["paid_by"]) if raw.get("paid_by") else None

    participants: list[str] = []
    for name in raw.get("participants") or []:
        member = resolve(name)
        if member and member not in participants:
            participants.append(member)

    split = raw.get("split") if isinstance(raw.get("split"), dict) else None
    split_type = split.get("type") if split and split.get("type") in SPLIT_TYPES else None
    shares = None
    if split_type in ("percent", "amounts", "shares"):
        weights: dict[str, float] = {}
        for name, value in (split.get("values") or {}).items():
            member, number = resolve(name), to_number(value)
            if member and number is not None:
                weights[member] = weights.get(member, 0) + number
                if member not in participants:
                    participants.append(member)
        if split_type == "amounts" and not amount and weights:
            amount = round(sum(weights.values()), 2)
            warnings = [w for w in warnings if w != "Montant non indiqué"] + ["Montant calculé à partir des parts"]
        shares = to_percentages(weights)
        if shares is None:
            split_type = None
    if unknown:
        warnings.append("Nom inconnu dans l'activité : " + ", ".join(unknown))

    return {
        "is_expense": True,
        "unreadable": False,
        "title": text("title", 80),
        "merchant": text("merchant", 80),
        "amount": amount,
        "currency": currency,
        "date": date,
        "paid_by": paid_by,
        "participants": participants or None,
        "split_type": split_type,
        "shares": shares,
        "items": items,
        "warnings": warnings,
        "unknown_names": unknown,
    }


class ExpenseDescriber:
    def __init__(self, model_dir: str | None = None) -> None:
        self.model_dir = Path(model_dir or config.DESCRIBE_MODEL_DIR)
        self._model = None
        self._tokenizer = None
        self._system = None
        self._lock = threading.Lock()  # MLX traite une phrase à la fois
        self.version: str | None = None
        self.error: str | None = None

    @property
    def ready(self) -> bool:
        return self._model is not None

    def load(self) -> None:
        try:
            from mlx_lm import load

            start = time.perf_counter()
            self._system = (self.model_dir.parent / "system_prompt.txt").read_text().strip()
            self._model, self._tokenizer = load(str(self.model_dir))
            self.version = config.DESCRIBE_MODEL_VERSION
            self.error = None
            log.info("Décrire la dépense prêt : %s (%.1fs)", self.version, time.perf_counter() - start)
        except Exception as e:  # dossier absent, mémoire…
            self._model = None
            self.error = f"{type(e).__name__}: {e}"
            log.error("Décrire la dépense indisponible : %s", self.error)

    def generate(self, message: str) -> str:
        from mlx_lm import generate

        prompt = self._tokenizer.apply_chat_template(
            [{"role": "system", "content": self._system}, {"role": "user", "content": message}],
            add_generation_prompt=True,
            tokenize=False,
        )
        return generate(self._model, self._tokenizer, prompt=prompt, max_tokens=320, verbose=False)

    def describe(self, sentence: str, members: list[dict], me_id: str, today: dt.date, currency: str) -> dict:
        """members : [{id, name}] de l'activité ; me_id : l'utilisateur connecté (doit en faire partie)."""
        if not self.ready:
            with self._lock:
                if not self.ready:
                    self.load()
        if not self.ready:
            raise RuntimeError(self.error or "Modèle indisponible")
        labels = member_labels(members)
        message = user_message(sentence, [labels[m["id"]] for m in members], labels[me_id], today, currency)
        with self._lock:
            text = self.generate(message)
        raw = parse_json(re.sub(r"<think>.*?</think>", "", text, flags=re.S))
        log.info("Phrase décrite : %s", json.dumps(raw, ensure_ascii=False)[:300])
        return normalize(raw, members, me_id, labels)
