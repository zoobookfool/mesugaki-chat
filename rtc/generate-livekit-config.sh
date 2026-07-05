#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created rtc/.env. Edit it first, then run this script again."
  exit 1
fi

# .env may contain values with symbols, so read only the variables we need
# instead of sourcing the whole file.
NODE_IP=$(grep -E '^NODE_IP=' .env | head -1 | cut -d= -f2-)
LIVEKIT_KEY=$(grep -E '^LIVEKIT_KEY=' .env | head -1 | cut -d= -f2-)
LIVEKIT_SECRET=$(grep -E '^LIVEKIT_SECRET=' .env | head -1 | cut -d= -f2-)

if [[ -z "${NODE_IP}" || "${NODE_IP}" == "203.0.113.10" ]]; then
  echo "Set NODE_IP in rtc/.env (your VPS public IPv4) before generating livekit.yaml." >&2
  exit 1
fi

if [[ -z "${LIVEKIT_KEY}" ]]; then
  echo "Set LIVEKIT_KEY in rtc/.env before generating livekit.yaml." >&2
  exit 1
fi

if [[ -z "${LIVEKIT_SECRET}" || "${LIVEKIT_SECRET}" == "replace-with-random" ]]; then
  echo "Set LIVEKIT_SECRET in rtc/.env (a long random value) before generating livekit.yaml." >&2
  exit 1
fi

sed \
  -e "s|\${NODE_IP}|${NODE_IP}|g" \
  -e "s|\${LIVEKIT_KEY}|${LIVEKIT_KEY}|g" \
  -e "s|\${LIVEKIT_SECRET}|${LIVEKIT_SECRET}|g" \
  livekit.yaml.template > livekit.yaml

echo "Generated rtc/livekit.yaml."
