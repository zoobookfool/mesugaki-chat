#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "No .env found. Copy .env.example to .env and edit it first." >&2
  exit 1
fi

# .env は値に記号を含みうるので source せず、必要な変数だけ読む
# (CRLF な .env でも動くよう \r を落とす)
MATRIX_HOST=$(grep -E '^MATRIX_HOST=' .env | head -1 | cut -d= -f2- | tr -d '\r')

if [[ -z "${MATRIX_HOST}" || "${MATRIX_HOST}" == "matrix.example.com" ]]; then
  echo "Set MATRIX_HOST in .env before generating synapse-admin/config.json." >&2
  exit 1
fi

mkdir -p synapse-admin

cat > synapse-admin/config.json <<CFG
{
  "restrictBaseUrl": "https://${MATRIX_HOST}"
}
CFG

echo "Generated synapse-admin/config.json for https://${MATRIX_HOST}."
echo "Start the dashboard with: docker compose --profile admin up -d synapse-admin"
echo "(binds to 127.0.0.1:8083 by default; see docs/operations.md before exposing it further)"
