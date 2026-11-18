#!/bin/bash
# Prépare le dossier envoyé au PC d'entraînement et le compresse en zip.
#   ml/pc/make_package.sh [dossier_de_sortie]   (par défaut : ~/Downloads)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${1:-$HOME/Downloads}"
NAME="equipay_pc_v2"
STAGE="$(mktemp -d)/$NAME"
mkdir -p "$STAGE/data" "$STAGE/knowledge"

cp pc/README.md pc/requirements.txt pc/train_cuda.py pc/evaluate_cuda.py scripts/metrics.py "$STAGE/"
cp -R data/processed "$STAGE/data/processed"
mkdir -p "$STAGE/data/source"
cp data/source/qa.yaml data/source/support.yaml data/source/off_topic.yaml "$STAGE/data/source/"
cp -R data/source/topics "$STAGE/data/source/topics"
cp knowledge/equipay.md "$STAGE/knowledge/"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$NAME.zip"
(cd "$(dirname "$STAGE")" && zip -qr -X "$OUT_DIR/$NAME.zip" "$NAME" -x "*.DS_Store")
echo "$OUT_DIR/$NAME.zip"
