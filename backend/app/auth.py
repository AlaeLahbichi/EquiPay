"""Vérifie le jeton de connexion Supabase envoyé par l'app (en-tête Authorization)."""

from dataclasses import dataclass

import jwt
from fastapi import Header, HTTPException, status

from . import config

# Clés publiques Supabase (ES256), mises en cache
_jwks = jwt.PyJWKClient(config.SUPABASE_JWKS_URL, cache_keys=True, lifespan=3600)


@dataclass
class User:
    id: str
    token: str  # renvoyé à Supabase pour agir au nom de l'utilisateur (règles RLS)


def current_user(authorization: str | None = Header(default=None)) -> User:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Connexion requise")
    token = authorization.split(" ", 1)[1]
    try:
        key = _jwks.get_signing_key_from_jwt(token).key
        claims = jwt.decode(token, key, algorithms=["ES256"], audience="authenticated")
    except jwt.PyJWTError as e:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Session invalide ou expirée") from e
    return User(id=claims["sub"], token=token)


def optional_user(authorization: str | None = Header(default=None)) -> User | None:
    """Comme current_user, mais sans jeton on continue en visiteur anonyme (None).
    Un jeton présent mais invalide est refusé : l'app sait alors que la session a expiré."""
    if not authorization:
        return None
    return current_user(authorization)
