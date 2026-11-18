#!/bin/bash
# Applique sur Supabase les migrations de supabase/migrations/ qui ne l'ont pas encore été.
# Nécessite SUPABASE_DB_URL dans backend/.env
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"

DB_URL=$(grep -E '^SUPABASE_DB_URL=' ../backend/.env | cut -d= -f2- || true)
if [ -z "$DB_URL" ]; then
  echo "SUPABASE_DB_URL manquant dans backend/.env"
  exit 1
fi

psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -c "
  create table if not exists public._migrations (
    name text primary key,
    applied_at timestamptz not null default now()
  );
  alter table public._migrations enable row level security;"

for f in migrations/*.sql; do
  name=$(basename "$f")
  if [ -n "$(psql "$DB_URL" -X -tA -c "select 1 from public._migrations where name = '$name'")" ]; then
    echo "= $name (déjà appliquée)"
    continue
  fi
  echo "→ $name"
  psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -1 -f "$f" -c "insert into public._migrations (name) values ('$name')"
done
echo "✓ Base à jour"
