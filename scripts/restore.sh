#!/usr/bin/env bash
# SelfMatrix restore from a backup set produced by scripts/backup.sh.
#
#   scripts/restore.sh backups/<timestamp>            # restore into production (destructive, prompts)
#   scripts/restore.sh backups/<timestamp> --drill    # verify into a throwaway DB (non-destructive)
#
# --drill restores only the database dump into a temporary DB, reports row
# counts, then drops it. Use it to prove a backup is restorable without
# touching the running server. Run it regularly.
set -euo pipefail

cd "$(dirname "$0")/.."

SET="${1:-}"
MODE="${2:-restore}"

if [[ -z "$SET" || ! -d "$SET" ]]; then
  echo "Usage: scripts/restore.sh backups/<timestamp> [--drill]" >&2
  echo "Available:" >&2
  ls -1d backups/*/ 2>/dev/null >&2 || echo "  (no backups found)" >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  echo ".env is missing." >&2
  exit 1
fi

# .env は値に記号を含みうるので source せず、必要な変数だけ読む。
# Windows checkout (core.autocrlf) の .env は CRLF になりうるので \r を必ず落とす。
env_get() {
  # 任意キーが .env に無い場合も失敗しない (grep の exit 1 を pipefail に
  # 拾わせない)。呼び出し側の ${VAR:-default} が正しく効くようにする。
  local line
  line="$(grep -E "^$1=" .env | head -1 || true)"
  printf '%s' "${line#*=}" | tr -d ''
}

POSTGRES_DB="$(env_get POSTGRES_DB)"
POSTGRES_USER="$(env_get POSTGRES_USER)"
SERVER_NAME="$(env_get SERVER_NAME)"

DB="${POSTGRES_DB:-synapse}"
USER="${POSTGRES_USER:-synapse}"

# DB 名/ユーザーは SQL に素で埋め込むため、識別子として安全な文字だけ許可
ident_pattern='^[A-Za-z0-9_]+$'
if [[ ! "$DB" =~ $ident_pattern || ! "$USER" =~ $ident_pattern ]]; then
  echo "POSTGRES_DB/POSTGRES_USER must match [A-Za-z0-9_]+ (got: ${DB} / ${USER})" >&2
  exit 1
fi
DUMP="${SET}/synapse-db.dump"

if [[ ! -f "$DUMP" ]]; then
  echo "No synapse-db.dump in ${SET}" >&2
  exit 1
fi

# Verify checksums first.
if [[ -f "${SET}/SHA256SUMS" ]]; then
  echo "Verifying checksums..."
  ( cd "$SET" && sha256sum -c SHA256SUMS )
fi

if [[ "$MODE" == "--drill" ]]; then
  DRILL_DB="synapse_restore_drill"
  echo "== Restore drill into throwaway DB '${DRILL_DB}' (production untouched) =="
  docker compose exec -T postgres psql -U "$USER" -d postgres \
    -c "DROP DATABASE IF EXISTS ${DRILL_DB};" \
    -c "CREATE DATABASE ${DRILL_DB} WITH TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C';"
  # pg_restore into the drill DB; --no-owner so it maps cleanly to $USER.
  docker compose exec -T postgres pg_restore -U "$USER" -d "$DRILL_DB" --no-owner < "$DUMP"
  echo "-- row counts in restored copy --"
  docker compose exec -T postgres psql -U "$USER" -d "$DRILL_DB" -tAc \
    "select 'users='||count(*) from users
     union all select 'rooms='||count(*) from rooms
     union all select 'events='||count(*) from events;"
  docker compose exec -T postgres psql -U "$USER" -d postgres \
    -c "DROP DATABASE ${DRILL_DB};"
  echo "Drill OK. Dump is restorable."
  exit 0
fi

echo "!! DESTRUCTIVE: this replaces the live '${DB}' database and Synapse data."
read -r -p "Type the server name (SERVER_NAME) to confirm: " CONFIRM
if [[ "$CONFIRM" != "${SERVER_NAME:-}" ]]; then
  echo "Aborted." >&2
  exit 1
fi

echo "Stopping synapse..."
docker compose stop synapse

echo "Recreating database..."
docker compose exec -T postgres psql -U "$USER" -d postgres \
  -c "DROP DATABASE IF EXISTS ${DB};" \
  -c "CREATE DATABASE ${DB} WITH TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C' OWNER ${USER};"
docker compose exec -T postgres pg_restore -U "$USER" -d "$DB" --no-owner < "$DUMP"

echo "Restoring signing key / config..."
# Extract as root so the archived Synapse container UID/ownership is preserved.
sudo tar -xzf "${SET}/synapse-config.tar.gz" -C synapse/data
if [[ -f "${SET}/synapse-media.tar.gz" ]]; then
  echo "Restoring media..."
  sudo tar -xzf "${SET}/synapse-media.tar.gz" -C synapse/data
fi

echo "Starting synapse..."
docker compose up -d synapse
echo "Restore complete. Check: curl -s http://localhost:8008/health (inside the synapse network) or your health endpoint."
