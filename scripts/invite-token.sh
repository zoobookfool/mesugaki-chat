#!/usr/bin/env bash
# Manage Synapse registration tokens (invite codes) via the admin API.
# Requires ENABLE_INVITE_REGISTRATION=true to have been baked into
# homeserver.yaml (see scripts/generate-synapse-config.sh) -- otherwise
# tokens exist but registration will not ask for them.
set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage:
  scripts/invite-token.sh create [--uses N] [--expiry-days D] [--token STRING]
  scripts/invite-token.sh list [--valid true|false]
  scripts/invite-token.sh delete <token>
  scripts/invite-token.sh --help

Options (anywhere after the subcommand):
  --admin-token TOKEN   Admin access token (or set ADMIN_ACCESS_TOKEN env var --
                        preferred: --admin-token ends up in argv/shell history,
                        ADMIN_ACCESS_TOKEN does not)
  --url URL             Synapse base URL (default: http://localhost:8008)

create-only options:
  --uses N              Number of times the token can be used (default: unlimited)
  --expiry-days D       Token expires D days from now (default: never)
  --token STRING        Use this exact token string instead of a random one

Examples:
  ADMIN_ACCESS_TOKEN=syt_... scripts/invite-token.sh create --uses 1 --expiry-days 7
  scripts/invite-token.sh list --admin-token syt_...
  scripts/invite-token.sh delete abcd1234 --admin-token syt_...
USAGE
}

BASE_URL="http://localhost:8008"
ADMIN_TOKEN="${ADMIN_ACCESS_TOKEN:-}"
CMD="${1:-}"
[[ $# -gt 0 ]] && shift

USES=""
EXPIRY_DAYS=""
TOKEN_STR=""
VALID_FILTER=""
DELETE_TOKEN=""

case "$CMD" in
  -h|--help|"")
    usage
    [[ "$CMD" == "-h" || "$CMD" == "--help" ]] && exit 0
    exit 1
    ;;
  create|list|delete)
    ;;
  *)
    echo "Unknown subcommand: $CMD" >&2
    usage
    exit 1
    ;;
esac

# Flags may appear before or after the positional token (delete); collect
# flags first and keep whatever position the token was passed in.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-token)
      ADMIN_TOKEN="$2"; shift 2 ;;
    --url)
      BASE_URL="$2"; shift 2 ;;
    --uses)
      USES="$2"; shift 2 ;;
    --expiry-days)
      EXPIRY_DAYS="$2"; shift 2 ;;
    --token)
      TOKEN_STR="$2"; shift 2 ;;
    --valid)
      VALID_FILTER="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ "$CMD" == "delete" && -z "$DELETE_TOKEN" ]]; then
        DELETE_TOKEN="$1"; shift
      else
        echo "Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ "$CMD" == "delete" && -z "$DELETE_TOKEN" ]]; then
  echo "delete requires a token argument" >&2
  usage
  exit 1
fi

: "${ADMIN_TOKEN:?admin access token required: pass --admin-token or set ADMIN_ACCESS_TOKEN}"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required (for JSON body/parsing)" >&2; exit 1; }

case "$CMD" in
  create)
    BODY=$(python3 - "$USES" "$EXPIRY_DAYS" "$TOKEN_STR" <<'PYEOF'
import json
import sys
import time

uses, expiry_days, token = sys.argv[1], sys.argv[2], sys.argv[3]
body = {}
if uses:
    body["uses_allowed"] = int(uses)
if expiry_days:
    body["expiry_time"] = int(time.time() * 1000) + int(float(expiry_days) * 86400 * 1000)
if token:
    body["token"] = token
print(json.dumps(body))
PYEOF
    )
    curl -fSs -X POST \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$BODY" \
      "${BASE_URL}/_synapse/admin/v1/registration_tokens/new"
    echo
    ;;

  list)
    QS=""
    if [[ -n "$VALID_FILTER" ]]; then
      QS="?valid=${VALID_FILTER}"
    fi
    curl -fSs \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      "${BASE_URL}/_synapse/admin/v1/registration_tokens${QS}"
    echo
    ;;

  delete)
    curl -fSs -X DELETE \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      "${BASE_URL}/_synapse/admin/v1/registration_tokens/${DELETE_TOKEN}"
    echo
    ;;
esac
