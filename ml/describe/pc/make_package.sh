#!/bin/bash
# Prépare le dossier envoyé au PC et le compresse en zip.   ml/describe/pc/make_package.sh [dossier]  (défaut : ~/Downloads)
set -euo pipefail
cd "$(dirname "$0")"
OUT_DIR="${1:-$HOME/Downloads}"
NAME="equipay_describe_pc"
STAGE="$(mktemp -d)/$NAME"
mkdir -p "$STAGE/data" "$STAGE/source"
cp README.md requirements.txt train_cuda.py evaluate_cuda.py "$STAGE/"
cp ../metrics.py ../schema.py "$STAGE/"
cp ../data/train.jsonl ../data/valid.jsonl ../data/valid_meta.jsonl ../data/test_meta.jsonl ../data/manual_meta.jsonl ../data/manifest.json "$STAGE/data/"
cp ../generate.py ../build.py "$STAGE/source/"
mkdir -p "$OUT_DIR"
rm -f "${OUT_DIR:?}/${NAME:?}.zip"
(cd "$(dirname "$STAGE")" && zip -qr -X "$OUT_DIR/$NAME.zip" "$NAME" -x "*.DS_Store" "*__pycache__*")
echo "$OUT_DIR/$NAME.zip"
