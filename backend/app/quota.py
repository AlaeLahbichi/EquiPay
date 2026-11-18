"""Quotas mensuels des fonctions d'IA selon l'offre de l'utilisateur (règles dans Supabase : plan_limit)."""

import logging

import httpx
from fastapi import HTTPException

from . import config
from .auth import User

log = logging.getLogger("equipay.quota")

# Nom affiché de chaque fonction et de chaque offre, pour les messages
FEATURES = {"scan": "scans de tickets", "describe": "descriptions par phrase", "trip": "organisations de trajet"}
PLANS = {"free": "Gratuit", "plus": "Plus", "pro": "Pro", "premium": "Premium"}
NEXT_PLAN = {"free": "plus", "plus": "pro", "pro": "premium"}
# Mêmes limites mensuelles que plan_limit dans Supabase (None : illimité)
LIMITS = {
    "scan": {"free": 5, "plus": 30, "pro": 100, "premium": None},
    "describe": {"free": 10, "plus": 60, "pro": 200, "premium": None},
    "trip": {"free": 2, "plus": 10, "pro": 40, "premium": None},
}


def _rpc(user: User, name: str, feature: str) -> httpx.Response:
    return httpx.post(
        f"{config.SUPABASE_URL}/rest/v1/rpc/{name}",
        json={"p_feature": feature},
        headers={
            "apikey": config.SUPABASE_PUBLISHABLE_KEY,
            "Authorization": f"Bearer {user.token}",
            "Content-Type": "application/json",
        },
        timeout=10,
    )


def limit_message(feature: str, plan: str, limit: int) -> str:
    message = f"Tu as utilisé tes {limit} {FEATURES[feature]} du mois avec l'offre {PLANS.get(plan, plan)}."
    upgrade = NEXT_PLAN.get(plan)
    if not upgrade:
        return message
    more = LIMITS[feature][upgrade]
    gain = f"{more} {FEATURES[feature]} par mois" if more else f"des {FEATURES[feature]} illimités"
    return f"{message} Passe à l'offre {PLANS[upgrade]} pour profiter de {gain}."


def check(user: User, feature: str) -> None:
    """Refuse (402) quand le quota du mois est atteint. Si Supabase ne répond pas, on laisse passer :
    une panne du suivi ne doit pas bloquer l'utilisateur."""
    try:
        r = _rpc(user, "ai_quota", feature)
        r.raise_for_status()
        quota = r.json()
    except Exception as e:  # noqa: BLE001
        log.warning("Quota %s non vérifié : %s", feature, e)
        return
    if not quota.get("allowed", True):
        raise HTTPException(
            402,
            {
                "message": limit_message(feature, quota.get("plan", "free"), quota.get("limit") or 0),
                "feature": feature,
                "plan": quota.get("plan"),
                "limit": quota.get("limit"),
            },
        )


def record(user: User, feature: str) -> None:
    """Compte une utilisation réussie. Un échec n'empêche pas de répondre."""
    try:
        _rpc(user, "record_ai_usage", feature).raise_for_status()
    except Exception as e:  # noqa: BLE001
        log.warning("Utilisation %s non comptée : %s", feature, e)
