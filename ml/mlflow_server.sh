#!/bin/bash
# Serveur MLflow « Equipay » accessible depuis le réseau local (ex. le PC d'entraînement).
# Interface : http://127.0.0.1:5000 sur le Mac, http://<IP du Mac>:5000 depuis le PC.
# Les fichiers (adaptateurs, prédictions…) envoyés par le PC sont rangés dans ml/mlartifacts.
cd "$(dirname "$0")"
export MLFLOW_DISABLE_AGENT_HINT=1
# Léger : 1 worker web, pas de tâches de fond (huey) — on n'utilise que le suivi des runs et le registre
export MLFLOW_SERVER_ENABLE_JOB_EXECUTION=false
exec .venv/bin/mlflow server \
  --backend-store-uri "sqlite:///$PWD/mlflow.db" \
  --artifacts-destination "$PWD/mlartifacts" \
  --host 0.0.0.0 --port 5000 --workers 1 \
  --allowed-hosts "*" --cors-allowed-origins "*"
