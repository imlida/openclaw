#!/usr/bin/env bash
# OpenClaw Docker-in-Docker Setup Script
# Run from repo root: ./deploy/setup-dind.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.dind.yml"
IMAGE_NAME="${OPENCLAW_IMAGE:-openclaw:dind}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1" >&2
    exit 1
  fi
}

require_cmd docker
if ! docker compose version >/dev/null 2>&1; then
  fail "Docker Compose not available"
fi

# Setup directories
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-$HOME/.openclaw/workspace}"

mkdir -p "$OPENCLAW_CONFIG_DIR"
mkdir -p "$OPENCLAW_WORKSPACE_DIR"
mkdir -p "$OPENCLAW_CONFIG_DIR/identity"
mkdir -p "$OPENCLAW_CONFIG_DIR/agents/main/agent"
mkdir -p "$OPENCLAW_CONFIG_DIR/agents/main/sessions"

# Generate token if not exists
if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
  else
    OPENCLAW_GATEWAY_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  fi
  echo "Generated gateway token"
fi

export OPENCLAW_CONFIG_DIR
export OPENCLAW_WORKSPACE_DIR
export OPENCLAW_GATEWAY_TOKEN
export OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
export OPENCLAW_BRIDGE_PORT="${OPENCLAW_BRIDGE_PORT:-18790}"
export OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"
export OPENCLAW_IMAGE="$IMAGE_NAME"
export OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES:-}"
export OPENCLAW_EXTENSIONS="${OPENCLAW_EXTENSIONS:-}"
export OPENCLAW_TZ="${OPENCLAW_TZ:-UTC}"

# Create .env file
ENV_FILE="$SCRIPT_DIR/.env"
cat > "$ENV_FILE" << EOF
OPENCLAW_CONFIG_DIR=$OPENCLAW_CONFIG_DIR
OPENCLAW_WORKSPACE_DIR=$OPENCLAW_WORKSPACE_DIR
OPENCLAW_GATEWAY_PORT=$OPENCLAW_GATEWAY_PORT
OPENCLAW_BRIDGE_PORT=$OPENCLAW_BRIDGE_PORT
OPENCLAW_GATEWAY_BIND=$OPENCLAW_GATEWAY_BIND
OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN
OPENCLAW_IMAGE=$OPENCLAW_IMAGE
OPENCLAW_DOCKER_APT_PACKAGES=$OPENCLAW_DOCKER_APT_PACKAGES
OPENCLAW_EXTENSIONS=$OPENCLAW_EXTENSIONS
OPENCLAW_TZ=$OPENCLAW_TZ
EOF

echo "==> Building DinD image: $IMAGE_NAME"
docker compose -f "$COMPOSE_FILE" build

echo ""
echo "==> Starting OpenClaw DinD"
docker compose -f "$COMPOSE_FILE" up -d

echo ""
echo "Waiting for gateway to be ready..."
sleep 5
for i in {1..30}; do
  if curl -fsS http://127.0.0.1:"$OPENCLAW_GATEWAY_PORT"/healthz >/dev/null 2>&1; then
    echo "Gateway is ready!"
    break
  fi
  sleep 2
done

echo ""
echo "OpenClaw DinD is running!"
echo "Dashboard: http://127.0.0.1:$OPENCLAW_GATEWAY_PORT"
echo "Token: $OPENCLAW_GATEWAY_TOKEN"
echo ""
echo "Commands:"
echo "  docker compose -f $COMPOSE_FILE logs -f"
echo "  docker compose -f $COMPOSE_FILE down"
