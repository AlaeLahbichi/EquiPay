#!/bin/bash
# Prépare le dossier v2 envoyé au PC d'entraînement et le compresse en zip.
#   ml/receipts/pc/make_package.sh [dossier_de_sortie]   (par défaut : ~/Downloads)
set -euo pipefail
cd "$(dirname "$0")"

OUT_DIR="${1:-$HOME/Downloads}"
NAME="equipay_receipt_pc_v2"
STAGE="$(mktemp -d)/$NAME"
mkdir -p "$STAGE/data"

cp README.md requirements.txt train_cuda.py evaluate_cuda.py receipt_data.py receipt_metrics.py api.py "$STAGE/"
cp -R data/prepared "$STAGE/data/prepared"

mkdir -p "$OUT_DIR"
rm -f "${OUT_DIR:?}/${NAME:?}.zip"
(cd "$(dirname "$STAGE")" && zip -qr -X "$OUT_DIR/$NAME.zip" "$NAME" -x "*.DS_Store" "*__pycache__*")
echo "$OUT_DIR/$NAME.zip"
