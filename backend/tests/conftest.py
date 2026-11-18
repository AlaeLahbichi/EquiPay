import pytest

from app import quota


@pytest.fixture(autouse=True)
def no_quota(monkeypatch, request):
    """Les tests des routes n'interrogent pas Supabase : quotas toujours disponibles (sauf test_quota.py)."""
    if request.module.__name__.endswith("test_quota"):
        return
    monkeypatch.setattr(quota, "check", lambda user, feature: None)
    monkeypatch.setattr(quota, "record", lambda user, feature: None)
