#!/usr/bin/env bash
# Generate synapse/data/homeserver.yaml and patch it for this deploy from .env,
# with no hand-editing required: PostgreSQL wiring, public_baseurl, upload cap,
# reverse-proxy trust, registration (closed by default, or invite-token gated
# via ENABLE_INVITE_REGISTRATION), and the MatrixRTC feature flags.
# Idempotent: re-running only regenerates + re-patches if you pass --force.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example. Edit it (SERVER_NAME, MATRIX_HOST, POSTGRES_PASSWORD, ...) then re-run." >&2
  exit 1
fi

# .env は値に記号を含みうるので source せず、必要な変数だけ読む。
# Windows checkout (core.autocrlf) の .env は CRLF になりうるので \r を必ず落とす —
# 落とさないと placeholder ガードが素通りし、homeserver.yaml に不可視の \r が混入する。
env_get() {
  grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r'
}

SERVER_NAME="$(env_get SERVER_NAME)"
MATRIX_HOST="$(env_get MATRIX_HOST)"
POSTGRES_PASSWORD="$(env_get POSTGRES_PASSWORD)"
POSTGRES_DB="$(env_get POSTGRES_DB)"
POSTGRES_USER="$(env_get POSTGRES_USER)"
MAX_UPLOAD_SIZE="$(env_get MAX_UPLOAD_SIZE)"
ENABLE_INVITE_REGISTRATION="$(env_get ENABLE_INVITE_REGISTRATION)"

: "${SERVER_NAME:?set SERVER_NAME in .env}"
: "${MATRIX_HOST:?set MATRIX_HOST in .env}"
: "${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in .env}"

# 単純なホスト名バリデーション (英数字・ドット・ハイフンのみ)。python 側で YAML/文字列
# 埋め込みに使う前に、想定外の記号 (シェル的に危険な文字含む) が混ざっていないか確認する。
host_pattern='^[A-Za-z0-9.-]+$'
if [[ ! "$SERVER_NAME" =~ $host_pattern ]]; then
  echo "SERVER_NAME contains characters outside [A-Za-z0-9.-]: ${SERVER_NAME}" >&2
  exit 1
fi
if [[ ! "$MATRIX_HOST" =~ $host_pattern ]]; then
  echo "MATRIX_HOST contains characters outside [A-Za-z0-9.-]: ${MATRIX_HOST}" >&2
  exit 1
fi

HS="synapse/data/homeserver.yaml"
FORCE="${1:-}"

if [[ -f "$HS" && "$FORCE" != "--force" ]]; then
  echo "$HS already exists. Re-run with --force to regenerate + re-patch (overwrites it)." >&2
  exit 1
fi

echo "Generating base homeserver.yaml for ${SERVER_NAME}..."
# Synapse writes the file as its container UID; remove any prior copy as root.
sudo rm -f "$HS"
docker compose --profile generate run --rm synapse-generate >/dev/null

echo "Patching for this deploy..."
# Patch as root (file is owned by the Synapse container UID). Values come from
# the environment so nothing here contains a real hostname or secret.
sudo env \
  MATRIX_HOST="$MATRIX_HOST" \
  POSTGRES_DB="${POSTGRES_DB:-synapse}" \
  POSTGRES_USER="${POSTGRES_USER:-synapse}" \
  POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  MAX_UPLOAD_SIZE="${MAX_UPLOAD_SIZE:-90M}" \
  ENABLE_INVITE_REGISTRATION="${ENABLE_INVITE_REGISTRATION:-false}" \
  HS_PATH="$HS" \
  python3 - <<'PYEOF'
import json
import os

p = os.environ["HS_PATH"]
src = open(p).read()

# 1. Swap the generated sqlite block for PostgreSQL.
# POSTGRES_PASSWORD can contain arbitrary characters (quotes, backslashes,
# YAML-significant symbols); json.dumps() produces a JSON string literal,
# which is also a valid YAML double-quoted scalar, so this is safe embedding
# rather than naive string interpolation.
password_yaml = json.dumps(os.environ["POSTGRES_PASSWORD"])
sqlite = """database:
  name: sqlite3
  args:
    database: /data/homeserver.db"""
pg = f"""database:
  name: psycopg2
  args:
    user: {os.environ["POSTGRES_USER"]}
    password: {password_yaml}
    dbname: {os.environ["POSTGRES_DB"]}
    host: postgres
    cp_min: 5
    cp_max: 10"""
assert sqlite in src, "expected generated sqlite database block not found"
src = src.replace(sqlite, pg)

# 2. Trust the reverse proxy's forwarded headers on the client/federation port.
src = src.replace(
    """  - port: 8008
    tls: false
    type: http
    x_forwarded: true""",
    """  - port: 8008
    tls: false
    type: http
    x_forwarded: true""",
)  # already set by generate; kept explicit for clarity

# 3. Append the SelfMatrix deploy settings (idempotent marker).
marker = "# --- SelfMatrix deploy settings ---"
invite_only = os.environ["ENABLE_INVITE_REGISTRATION"].strip().lower() in ("true", "1", "yes")
if invite_only:
    # Token-gated registration: enable_registration must be true for anyone to
    # register at all, but registration_requires_token means nobody can
    # actually complete registration without a token issued via
    # scripts/invite-token.sh. This is "invite-code registration", not open
    # registration. See docs/operations.md.
    registration_block = """enable_registration: true
registration_requires_token: true"""
else:
    registration_block = "enable_registration: false"

if marker not in src:
    src += f"""
{marker}
public_baseurl: "https://{os.environ["MATRIX_HOST"]}/"
{registration_block}
allow_guest_access: false
max_upload_size: {os.environ["MAX_UPLOAD_SIZE"]}

# MatrixRTC (Element Call) — see docs and rtc/ for the backend.
experimental_features:
  msc3266_enabled: true
  msc4222_enabled: true
  msc4354_enabled: true
max_event_delay_duration: 24h
rc_message:
  per_second: 0.5
  burst_count: 30
rc_delayed_event_mgmt:
  per_second: 1
  burst_count: 20
"""

open(p, "w").write(src)
print("  patched: PostgreSQL, public_baseurl, upload cap, MatrixRTC flags")
if invite_only:
    print("  registration: invite-token gated (ENABLE_INVITE_REGISTRATION=true)")
PYEOF

echo
echo "Done. homeserver.yaml is ready. Next:"
echo "  bash scripts/generate-cinny-config.sh   # client config"
echo "  docker compose up -d"
echo
echo "To create the admin user, temporarily set registration_shared_secret and run"
echo "scripts/create-admin.sh (see README)."
EIR_LOWER="$(printf '%s' "${ENABLE_INVITE_REGISTRATION:-false}" | tr '[:upper:]' '[:lower:]')"
if [[ "$EIR_LOWER" =~ ^(true|1|yes)$ ]]; then
  echo
  echo "Invite-code registration is enabled. Issue tokens with:"
  echo "  bash scripts/invite-token.sh create --uses 1"
fi
