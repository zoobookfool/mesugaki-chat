#!/usr/bin/env bash
# SelfMatrix backup: PostgreSQL dump + Synapse signing key / config / media.
# Losing the signing key permanently breaks this server's federation identity,
# so it is always included. Keeps the most recent BACKUP_KEEP sets (default 7).
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo ".env is missing. Run from the repo root after creating .env." >&2
  exit 1
fi

# .env は値に記号を含みうるので source せず、必要な変数だけ読む。
# Windows checkout (core.autocrlf) の .env は CRLF になりうるので \r を必ず落とす。
env_get() {
  grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r'
}

POSTGRES_USER="$(env_get POSTGRES_USER)"
POSTGRES_DB="$(env_get POSTGRES_DB)"
BACKUP_KEEP="$(env_get BACKUP_KEEP)"

POSTGRES_USER="${POSTGRES_USER:-synapse}"
POSTGRES_DB="${POSTGRES_DB:-synapse}"
KEEP="${BACKUP_KEEP:-7}"

# Backups contain DB dumps, homeserver.yaml, and signing keys -- all secret
# material. Restrict from the moment files are created, not after the fact.
umask 077

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="backups/${STAMP}"
# -m only applies to the deepest component (SC2174), but umask 077 above
# already forces any newly-created parent ("backups/") to 0700 as well.
# shellcheck disable=SC2174
mkdir -p -m 700 "$OUT"

echo "[1/3] PostgreSQL dump (custom format)..."
# -Fc = custom format: compressed and restorable with pg_restore (parallel, selective).
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" \
  -Fc "$POSTGRES_DB" > "${OUT}/synapse-db.dump"

echo "[2/3] Signing key + config..."
# Synapse writes these as its container UID, so reading them needs sudo. They
# are small but critical; stored plainly so a restore never depends on being
# able to read the big media tarball.
# There can be more than one *.signing.key (key rotation, old keys kept
# around); collect them with a null-separated find so filenames with spaces
# or newlines can't merge into one word or split into several tar arguments.
SIGNING_KEYS=()
while IFS= read -r -d '' f; do
  SIGNING_KEYS+=("$(basename "$f")")
done < <(sudo find synapse/data -maxdepth 1 -name '*.signing.key' -print0)

if [[ "${#SIGNING_KEYS[@]}" -eq 0 ]]; then
  echo "No *.signing.key found under synapse/data -- refusing to back up without it." >&2
  exit 1
fi

LOG_CONFIGS=()
while IFS= read -r -d '' f; do
  LOG_CONFIGS+=("$(basename "$f")")
done < <(sudo find synapse/data -maxdepth 1 -name '*.log.config' -print0)

sudo tar -czf "${OUT}/synapse-config.tar.gz" \
  -C synapse/data \
  homeserver.yaml \
  "${SIGNING_KEYS[@]}" \
  "${LOG_CONFIGS[@]}"

echo "[3/3] Media store..."
if [[ -d synapse/data/media_store ]]; then
  sudo tar -czf "${OUT}/synapse-media.tar.gz" -C synapse/data media_store
else
  echo "  (no media_store yet, skipping)"
fi

# Make the backup set readable by the operator (tar ran as root).
sudo chown -R "$(id -u):$(id -g)" "$OUT"
chmod -R go-rwx "$OUT"

# Checksums so restore can detect corruption.
( cd "$OUT" && sha256sum ./* > SHA256SUMS )
chmod go-rwx "${OUT}/SHA256SUMS"

echo "Wrote ${OUT}/ ($(du -sh "$OUT" | cut -f1))"

# Retention: drop all but the newest $KEEP timestamped sets. Uses find instead
# of parsing `ls` output (SC2012) so filenames can't be misparsed.
mapfile -t ALL_SETS < <(find backups -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r)
OLD=("${ALL_SETS[@]:${KEEP}}")
for d in "${OLD[@]:-}"; do
  [[ -n "$d" ]] || continue
  echo "Pruning old backup backups/${d}"
  rm -rf "backups/${d}"
done
