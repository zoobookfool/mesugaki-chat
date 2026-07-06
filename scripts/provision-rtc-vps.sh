#!/usr/bin/env bash
# One-shot rebuild of a stateless MatrixRTC backend VPS (rtc/) from a bare
# Ubuntu host. Re-derives everything from scratch: docker, firewall rules,
# the rtc/ deploy (clone + rtc/.env + livekit.yaml + compose up), and
# optionally an edge nginx vhost for the RTC_HOST reverse proxy. Safe to
# re-run: existing rtc/.env, ufw rules, and the git checkout are left alone
# instead of being clobbered.
#
# Usage:
#   sudo scripts/provision-rtc-vps.sh --server-name example.com \
#     --matrix-host matrix.example.com --chat-host chat.example.com \
#     --rtc-host rtc.example.com --node-ip 203.0.113.10 \
#     [--home-backend-ip 100.64.0.1] [--with-edge] [--dry-run]
#
# Every value can also come from the environment (SERVER_NAME, MATRIX_HOST,
# CHAT_HOST, RTC_HOST, NODE_IP, HOME_BACKEND_IP) instead of flags — useful
# for non-interactive re-provisioning. HOME_BACKEND_IP is only needed for
# route A (Cloudflare + VPS + Tailscale, see docs/home-server-network.md);
# omit it for route B (VPS-only), where --with-edge is not meaningful either
# since the text backend already runs the main compose.yaml on this host.
#
# --with-edge additionally installs nginx and writes an RTC_HOST vhost that
# proxies /livekit/jwt/ and /livekit/sfu/ to the local lk-jwt/LiveKit
# services (see README.md "リバースプロキシ例"). It does NOT run certbot —
# DNS must already resolve before requesting a certificate, so the script
# only prints the certbot command to run by hand afterward.
#
# --dry-run prints every step it would take (including generated file
# contents) without touching the system: no package installs, no ufw
# changes, no git/docker/nginx/certbot invocations.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/zoobookfool/selfmatrix.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/selfmatrix}"

SERVER_NAME="${SERVER_NAME:-}"
MATRIX_HOST="${MATRIX_HOST:-}"
CHAT_HOST="${CHAT_HOST:-}"
RTC_HOST="${RTC_HOST:-}"
NODE_IP="${NODE_IP:-}"
HOME_BACKEND_IP="${HOME_BACKEND_IP:-}"
# Port the home-side docker-compose.route-a.example.yml override publishes
# Synapse on (${BACKEND_BIND_IP}:${HOME_SYNAPSE_PORT}:8008). Keep this in sync
# with that file's mapping if it ever changes.
HOME_SYNAPSE_PORT="${HOME_SYNAPSE_PORT:-8028}"
# Port the same override publishes cinny on (${BACKEND_BIND_IP}:${HOME_CHAT_PORT}:80).
HOME_CHAT_PORT="${HOME_CHAT_PORT:-8082}"
WITH_EDGE=0
DRY_RUN=0

usage() {
  cat >&2 <<'USAGE'
Usage: provision-rtc-vps.sh --server-name <domain> --matrix-host <host> \
         --chat-host <host> --rtc-host <host> --node-ip <ip> \
         [--home-backend-ip <ip>] [--with-edge] [--dry-run]

Required (flag or matching environment variable):
  --server-name       SERVER_NAME   Matrix server_name (e.g. example.com)
  --matrix-host       MATRIX_HOST   Synapse API host (e.g. matrix.example.com)
  --chat-host         CHAT_HOST     Client host (e.g. chat.example.com)
  --rtc-host          RTC_HOST      MatrixRTC backend host (e.g. rtc.example.com)
  --node-ip           NODE_IP       This VPS's public IPv4 (baked into livekit.yaml)

Optional:
  --home-backend-ip   HOME_BACKEND_IP  Home server's Tailscale IP (route A only;
                                       see docs/home-server-network.md). Used by
                                       --with-edge to proxy matrix/chat upstream.
  (env only)          HOME_SYNAPSE_PORT  Home-side published Synapse port
                                       (default 8028; must match
                                       docker-compose.route-a.example.yml).
  (env only)          HOME_CHAT_PORT     Home-side published cinny port
                                       (default 8082; must match
                                       docker-compose.route-a.example.yml).
  --with-edge          Install nginx and write an RTC_HOST vhost (this VPS also
                        terminates matrix/chat as edge, route A/B). Does not run
                        certbot; prints the command to run by hand.
  --dry-run            Print planned actions and generated file contents only.
  -h, --help           Show this help.
USAGE
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-name) SERVER_NAME="$2"; shift 2 ;;
    --matrix-host) MATRIX_HOST="$2"; shift 2 ;;
    --chat-host) CHAT_HOST="$2"; shift 2 ;;
    --rtc-host) RTC_HOST="$2"; shift 2 ;;
    --node-ip) NODE_IP="$2"; shift 2 ;;
    --home-backend-ip) HOME_BACKEND_IP="$2"; shift 2 ;;
    --with-edge) WITH_EDGE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if [[ -z "$SERVER_NAME" || -z "$MATRIX_HOST" || -z "$CHAT_HOST" || -z "$RTC_HOST" || -z "$NODE_IP" ]]; then
  echo "Missing required value(s)." >&2
  usage
fi

run() {
  # Print the command always; execute it unless --dry-run.
  echo "+ $*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

write_file() {
  # write_file <path> — writes stdin to <path>, or just prints it under --dry-run.
  local path="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ would write ${path}:"
    sed 's/^/    /'
  else
    echo "+ writing ${path}"
    cat > "$path"
  fi
}

echo "== SelfMatrix rtc VPS provisioning =="
echo "SERVER_NAME=${SERVER_NAME}"
echo "MATRIX_HOST=${MATRIX_HOST}"
echo "CHAT_HOST=${CHAT_HOST}"
echo "RTC_HOST=${RTC_HOST}"
echo "NODE_IP=${NODE_IP}"
echo "HOME_BACKEND_IP=${HOME_BACKEND_IP:-<unset, route B / edge not proxying matrix+chat>}"
echo "HOME_SYNAPSE_PORT=${HOME_SYNAPSE_PORT}"
echo "HOME_CHAT_PORT=${HOME_CHAT_PORT}"
echo "WITH_EDGE=${WITH_EDGE}"
echo "DRY_RUN=${DRY_RUN}"
echo

# 1. Prerequisite checks -----------------------------------------------------

if [[ "$DRY_RUN" -eq 0 && "$(id -u)" -ne 0 ]]; then
  echo "Run as root (or via sudo). Re-run with --dry-run to preview without root." >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]] || ! grep -qi '^ID=ubuntu' /etc/os-release; then
  echo "This script targets Ubuntu. /etc/os-release does not report ID=ubuntu." >&2
  if [[ "$DRY_RUN" -eq 0 ]]; then
    exit 1
  fi
  echo "(continuing anyway: --dry-run)" >&2
fi

if [[ "$WITH_EDGE" -eq 1 && -z "$HOME_BACKEND_IP" ]]; then
  echo "--with-edge needs --home-backend-ip / HOME_BACKEND_IP (route A) so matrix/chat" >&2
  echo "can be proxied to the home backend. For route B (VPS-only text backend)," >&2
  echo "use the main compose.yaml directly instead of --with-edge here." >&2
  exit 1
fi

# 2. docker -------------------------------------------------------------------

echo
echo "-- [1/6] docker --"
if command -v docker >/dev/null 2>&1; then
  echo "docker already installed ($(docker --version 2>/dev/null || echo present)), skipping."
else
  # get.docker.com is Docker's own official install script/distribution channel
  # (https://github.com/docker/docker-install) -- piping it to sh is the
  # documented install method upstream, accepted here as-is.
  run bash -c "curl -fsSL https://get.docker.com | sh"
fi

# 3. ufw ------------------------------------------------------------------

echo
echo "-- [2/6] ufw firewall rules --"
if ! command -v ufw >/dev/null 2>&1; then
  run apt-get update -y
  run apt-get install -y ufw
fi

ufw_allow() {
  local rule="$1"
  if [[ "$DRY_RUN" -eq 0 ]] && ufw status | grep -qF "$rule"; then
    echo "ufw rule already present, skipping: ${rule}"
  else
    run ufw allow "$rule"
  fi
}

ufw_allow "80/tcp"
ufw_allow "443/tcp"
ufw_allow "7881/tcp"
ufw_allow "50100:50200/udp"

echo "NOTE: not running 'ufw enable' — enable it yourself once you have confirmed"
echo "      the rules above are correct, so you don't lock yourself out over SSH"
echo "      (make sure 22/tcp is allowed first if ufw is not already active)."

# 4. clone/pull + rtc/.env + livekit.yaml + compose up ----------------------

echo
echo "-- [3/6] repository at ${INSTALL_DIR} --"
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  run git -C "$INSTALL_DIR" pull --ff-only
else
  run git clone "$REPO_URL" "$INSTALL_DIR"
fi

echo
echo "-- [4/6] rtc/.env --"
RTC_ENV="${INSTALL_DIR}/rtc/.env"
if [[ "$DRY_RUN" -eq 0 && -f "$RTC_ENV" ]]; then
  echo "${RTC_ENV} already exists, leaving it untouched."
else
  if [[ "$DRY_RUN" -eq 0 ]]; then
    LIVEKIT_SECRET="$(openssl rand -hex 32)"
  else
    LIVEKIT_SECRET="<generated by openssl rand -hex 32>"
  fi
  write_file "$RTC_ENV" <<ENVEOF
# Generated by scripts/provision-rtc-vps.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
RTC_HOST=${RTC_HOST}
SERVER_NAME=${SERVER_NAME}
NODE_IP=${NODE_IP}
LIVEKIT_KEY=selfmatrix
LIVEKIT_SECRET=${LIVEKIT_SECRET}
ENVEOF
fi

echo
echo "-- [5/6] livekit.yaml + rtc stack --"
run bash -c "cd '${INSTALL_DIR}/rtc' && bash generate-livekit-config.sh"
run bash -c "cd '${INSTALL_DIR}' && docker compose -f rtc/compose.yaml up -d"

# 5. optional edge nginx ----------------------------------------------------

if [[ "$WITH_EDGE" -eq 1 ]]; then
  echo
  echo "-- [6/6] edge nginx (--with-edge) --"
  if ! command -v nginx >/dev/null 2>&1; then
    run apt-get update -y
    run apt-get install -y nginx
  else
    echo "nginx already installed, skipping install."
  fi

  NGINX_CONF="/etc/nginx/conf.d/selfmatrix.conf"
  write_file "$NGINX_CONF" <<NGINXEOF
# Generated by scripts/provision-rtc-vps.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# well-known for SERVER_NAME, matrix/chat proxied to the home backend
# (route A, see docs/home-server-network.md), and the local LiveKit/lk-jwt
# services for RTC_HOST. Run certbot afterward (see the final instructions)
# to add TLS server blocks for each host.

server {
    listen 80;
    server_name ${SERVER_NAME};

    location = /.well-known/matrix/server {
        default_type application/json;
        add_header Access-Control-Allow-Origin * always;
        return 200 '{"m.server":"${MATRIX_HOST}:443"}';
    }

    location = /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin * always;
        return 200 '{"m.homeserver":{"base_url":"https://${MATRIX_HOST}"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://${RTC_HOST}/livekit/jwt"}]}';
    }
}

server {
    listen 80;
    server_name ${MATRIX_HOST};

    location ^~ /_synapse/admin {
        return 403;
    }

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://${HOME_BACKEND_IP}:${HOME_SYNAPSE_PORT};
    }
}

server {
    listen 80;
    server_name ${CHAT_HOST};

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://${HOME_BACKEND_IP}:${HOME_CHAT_PORT};
    }
}

server {
    listen 80;
    server_name ${RTC_HOST};

    location ^~ /livekit/jwt/ {
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://127.0.0.1:6080/;
    }

    location ^~ /livekit/sfu/ {
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 120;
        proxy_send_timeout 120;

        proxy_pass http://127.0.0.1:7880/;
    }
}
NGINXEOF

  run bash -c "nginx -t && systemctl reload nginx || systemctl restart nginx"
else
  echo
  echo "-- [6/6] edge nginx skipped (pass --with-edge to enable) --"
fi

# 6. health check + next steps ----------------------------------------------

echo
echo "-- health check --"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "+ would run: curl -sf http://localhost:6080/healthz"
else
  if curl -sf http://localhost:6080/healthz >/dev/null; then
    echo "lk-jwt healthz OK (http://localhost:6080/healthz)"
  else
    echo "lk-jwt healthz check failed — inspect with:" >&2
    echo "  docker compose -f ${INSTALL_DIR}/rtc/compose.yaml logs" >&2
  fi
fi

cat <<NEXT

== Next steps ==

1. Confirm DNS: ${RTC_HOST} must be a DNS-only (no CDN proxy) A/AAAA record
   pointing at ${NODE_IP} (see docs/home-server-network.md).
NEXT

if [[ "$WITH_EDGE" -eq 1 ]]; then
  echo "2. --with-edge already wrote org.matrix.msc4143.rtc_foci into the"
  echo "   generated /.well-known/matrix/client for ${SERVER_NAME}; no manual edit needed."
else
  echo "2. Add org.matrix.msc4143.rtc_foci to ${MATRIX_HOST}'s"
  echo "   /.well-known/matrix/client (see README.md \"well-known 追記例\")."
fi

if [[ "$WITH_EDGE" -eq 1 ]]; then
  cat <<NEXT
3. Once DNS resolves, issue certificates by hand (not run automatically):
     certbot --nginx -d ${SERVER_NAME} -d ${MATRIX_HOST} -d ${CHAT_HOST} -d ${RTC_HOST}
4. Review firewall rules with 'ufw status' and run 'ufw enable' yourself once
   you have confirmed 22/tcp (SSH) is allowed.
NEXT
else
  cat <<NEXT
3. Review firewall rules with 'ufw status' and run 'ufw enable' yourself once
   you have confirmed 22/tcp (SSH) is allowed.
NEXT
fi
