#!/bin/bash
# Lance l'API EquiPay sur le réseau local (le téléphone l'appelle via http://<IP du Mac>:8000).
# Prérequis : le serveur MLflow (ml/mlflow_server.sh) tourne, pour charger le modèle champion.
cd "$(dirname "$0")"
exec .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
