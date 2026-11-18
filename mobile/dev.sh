#!/bin/bash
# Lance l'app et fait un hot reload automatique à chaque sauvegarde d'un fichier .dart dans lib/
cd "$(dirname "$0")"
PID_FILE=/tmp/flutter_mobile_app.pid
rm -f "$PID_FILE"

fswatch -o -e ".*" -i "\\.dart$" lib | while read -r _; do
  [ -f "$PID_FILE" ] && kill -USR1 "$(cat "$PID_FILE")" 2>/dev/null
done &
WATCHER=$!
trap 'kill $WATCHER 2>/dev/null; pkill -P $WATCHER 2>/dev/null' EXIT

flutter run --dart-define-from-file=env.json --pid-file "$PID_FILE" "$@"
