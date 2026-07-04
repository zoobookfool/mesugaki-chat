#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f .env ]]; then
  echo "No .env found. Copy .env.example to .env and edit it first." >&2
  exit 1
fi

# .env は値に記号を含みうるので source せず、必要な変数だけ読む
SERVER_NAME=$(grep -E '^SERVER_NAME=' .env | head -1 | cut -d= -f2-)

if [[ -z "${SERVER_NAME}" || "${SERVER_NAME}" == "example.com" ]]; then
  echo "Set SERVER_NAME in .env before generating cinny/config.json." >&2
  exit 1
fi

cat > cinny/config.json <<CFG
{
  "defaultHomeserver": 0,
  "homeserverList": ["${SERVER_NAME}"],
  "allowCustomHomeservers": false,
  "hideExplore": true,
  "featuredCommunities": {
    "openAsDefault": false,
    "spaces": [],
    "rooms": [],
    "servers": []
  },
  "hashRouter": {
    "enabled": false,
    "basename": "/"
  }
}
CFG

echo "Generated cinny/config.json for ${SERVER_NAME}."
