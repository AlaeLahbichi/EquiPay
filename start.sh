#!/bin/bash
# Lance tout EquiPay en local : MLflow (:5000), API (:8000), puis l'app sur l'iPhone.
# ./start.sh          → serveurs + app sur l'iPhone
# ./start.sh serveurs → serveurs seulement
cd "$(dirname "$0")"
IPHONE=00008130-000A61880CE2001C

attendre() {  # attendre <port> <nom>
  for _ in $(seq 1 120); do
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && { echo "✓ $2 prêt (port $1)"; return 0; }
    sleep 1
  done
  echo "✗ $2 ne démarre pas, voir les logs" && exit 1
}

if lsof -nP -iTCP:5000 -sTCP:LISTEN >/dev/null 2>&1; then echo "✓ MLflow déjà lancé"; else
  nohup ml/mlflow_server.sh >ml/logs/mlflow.log 2>&1 &
  attendre 5000 MLflow
fi
if lsof -nP -iTCP:8000 -sTCP:LISTEN >/dev/null 2>&1; then echo "✓ API déjà lancée"; else
  nohup backend/run.sh >backend/logs/api.log 2>&1 &
  attendre 8000 API
fi
echo "  MLflow : http://127.0.0.1:5000   API : http://Alaes-MacBook-Pro.local:8000/docs"

[ "$1" = "serveurs" ] && exit 0
cd mobile && flutter run -d "$IPHONE" --release --dart-define-from-file=env.json
