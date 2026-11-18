"""Format partagé : prompt, entrée et sortie du modèle « Décrire la dépense » (entraînement, éval, backend)."""
import json

FIELDS = ["is_expense", "title", "merchant", "amount", "currency", "date", "paid_by", "participants", "split", "items"]

SYSTEM = (
    "Assistant de saisie EquiPay. Extrais UNE dépense de la phrase, en JSON : is_expense, title, merchant, amount, "
    "currency (ISO), date (AAAA-MM-JJ), paid_by, participants, split (null, equal, ou percent/amounts/shares avec values), "
    "items [{label, qty, price}]. Noms de la liste uniquement, « moi » pour l'utilisateur. Total absent : somme des "
    "articles, sinon 0. Information absente : null."
)

WEEKDAYS = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]


def user_message(sentence: str, members: list[str], me: str, today, currency: str) -> str:
    """members : noms de l'activité ; me : nom de l'utilisateur (affiché « Nom (moi) »)."""
    names = ", ".join(f"{m} (moi)" if m == me else m for m in members)
    return (
        f"Aujourd'hui : {today.isoformat()} ({WEEKDAYS[today.weekday()]})\n"
        f"Devise de l'activité : {currency}\n"
        f"Membres : {names}\n"
        f"Phrase : {sentence}"
    )


def empty(is_expense=True) -> dict:
    return {"is_expense": is_expense, "title": None, "merchant": None, "amount": None, "currency": None,
            "date": None, "paid_by": None, "participants": None, "split": None, "items": None}


def dump(target: dict) -> str:
    return json.dumps({k: target.get(k) for k in FIELDS}, ensure_ascii=False)
