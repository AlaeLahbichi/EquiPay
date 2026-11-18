"""Historique des conversations dans Supabase (table chat_messages), au nom de l'utilisateur."""

import logging

import httpx

from . import config
from .auth import User

log = logging.getLogger("equipay.chat_store")


def _headers(user: User) -> dict:
    return {
        "apikey": config.SUPABASE_PUBLISHABLE_KEY,
        "Authorization": f"Bearer {user.token}",
        "Content-Type": "application/json",
    }


def save_exchange(user: User, question: str, answer: str, activity_id: str | None) -> None:
    """Enregistre la question et la réponse. Un échec n'empêche pas de répondre."""
    rows = [
        {"user_id": user.id, "activity_id": activity_id, "role": role, "content": content}
        for role, content in [("user", question), ("assistant", answer)]
    ]
    try:
        r = httpx.post(f"{config.SUPABASE_URL}/rest/v1/chat_messages", json=rows,
                       headers=_headers(user), timeout=10)
        r.raise_for_status()
    except httpx.HTTPError as e:
        log.warning("Historique non enregistré : %s", e)


def history(user: User, limit: int = 50) -> list[dict]:
    """Derniers messages de l'utilisateur, du plus ancien au plus récent."""
    r = httpx.get(
        f"{config.SUPABASE_URL}/rest/v1/chat_messages",
        params={"select": "id,role,content,created_at", "order": "created_at.desc", "limit": limit},
        headers=_headers(user), timeout=10,
    )
    r.raise_for_status()
    return list(reversed(r.json()))
