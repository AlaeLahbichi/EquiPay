#!/bin/bash
# Arrête tout EquiPay : API (:8000), MLflow (:5000) et l'app lancée par flutter run.
for port in 8000 5000; do
  pids=$(lsof -ti tcp:$port -sTCP:LISTEN)
  [ -n "$pids" ] && kill $pids && echo "✓ port $port fermé" || echo "· port $port déjà libre"
done
pkill -f "mlflow server" 2>/dev/null
pkill -f "uvicorn app.main:app" 2>/dev/null
pkill -f "flutter_tools.snapshot run" 2>/dev/null && echo "✓ flutter run arrêté"
exit 0
