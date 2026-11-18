#!/bin/bash
# Pipeline complet de l'assistant EquiPay, tracé dans l'expérimentation MLflow « Equipay » :
#   1. jeu de données   2. mesure de chaque modèle importé (baseline)
#   3. entraînement LoRA de chaque modèle   4. élection du champion
set -uo pipefail
cd "$(dirname "$0")"
PY=.venv/bin/python

# Ministral-3-3B retiré : score de départ le plus faible (0,239)
MODELS=(
  mlx-community/Qwen2.5-1.5B-Instruct-4bit
  mlx-community/Llama-3.2-3B-Instruct-4bit
  mlx-community/Qwen3-4B-Instruct-2507-4bit
)

$PY scripts/build_dataset.py

for m in "${MODELS[@]}"; do
  echo "=== baseline $m"
  $PY scripts/run.py baseline --model "$m" || echo "!!! baseline échouée : $m"
done

for m in "${MODELS[@]}"; do
  echo "=== entraînement $m"
  $PY scripts/run.py train --model "$m" --epochs 2 || echo "!!! entraînement échoué : $m"
done

echo "=== champion"
$PY scripts/run.py champion
