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

set -a
# shellcheck disable=SC1091
source .env
set +a

KEEP="${BACKUP_KEEP:-7}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="backups/${STAMP}"
mkdir -p "$OUT"

echo "[1/3] PostgreSQL dump (custom format)..."
# -Fc = custom format: compressed and restorable with pg_restore (parallel, selective).
docker compose exec -T postgres pg_dump -U "${POSTGRES_USER:-synapse}" \
  -Fc "${POSTGRES_DB:-synapse}" > "${OUT}/synapse-db.dump"

echo "[2/3] Signing key + config..."
# Synapse writes these as its container UID, so reading them needs sudo. They
# are small but critical; stored plainly so a restore never depends on being
# able to read the big media tarball.
sudo tar -czf "${OUT}/synapse-config.tar.gz" \
  -C synapse/data \
  homeserver.yaml \
  "$(cd synapse/data && sudo ls ./*.signing.key)" \
  "$(cd synapse/data && sudo ls ./*.log.config 2>/dev/null || true)"

echo "[3/3] Media store..."
if [[ -d synapse/data/media_store ]]; then
  sudo tar -czf "${OUT}/synapse-media.tar.gz" -C synapse/data media_store
else
  echo "  (no media_store yet, skipping)"
fi

# Make the backup set readable by the operator (tar ran as root).
sudo chown -R "$(id -u):$(id -g)" "$OUT"

# Checksums so restore can detect corruption.
( cd "$OUT" && sha256sum ./* > SHA256SUMS )

echo "Wrote ${OUT}/ ($(du -sh "$OUT" | cut -f1))"

# Retention: drop all but the newest $KEEP timestamped sets.
mapfile -t OLD < <(ls -1d backups/*/ 2>/dev/null | sort -r | tail -n +"$((KEEP + 1))")
for d in "${OLD[@]:-}"; do
  [[ -n "$d" ]] || continue
  echo "Pruning old backup ${d}"
  rm -rf "$d"
done
