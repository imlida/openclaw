#!/usr/bin/env bash
# Setup OpenClaw using Apple Container (https://github.com/apple/container)
# Run from repo root: ./deploy/setup-apple-container.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CONTAINER_NAME="${OPENCLAW_CONTAINER_NAME:-openclaw}"
IMAGE_NAME="${OPENCLAW_IMAGE:-openclaw:local}"

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

require_cmd container

# Check Apple Container version
CONTAINER_VERSION=$(container --version 2>/dev/null || echo "unknown")
echo "Apple Container version: $CONTAINER_VERSION"

# Setup directories
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-$HOME/.openclaw/workspace}"

mkdir -p "$OPENCLAW_CONFIG_DIR"
mkdir -p "$OPENCLAW_WORKSPACE_DIR"

# Generate token
if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
  else
    OPENCLAW_GATEWAY_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  fi
fi

# Export for build
export OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES:-}"
export OPENCLAW_EXTENSIONS="${OPENCLAW_EXTENSIONS:-}"

# Build image using Docker/Podman (Apple Container uses same OCI images)
# Note: Apple Container doesn't have build capabilities yet, use Docker/Podman for build
if command -v docker >/dev/null 2>&1; then
  echo "Building image with Docker..."
  docker build \
    --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES}" \
    --build-arg "OPENCLAW_EXTENSIONS=${OPENCLAW_EXTENSIONS}" \
    -t "$IMAGE_NAME" \
    -f "$REPO_ROOT/Dockerfile" \
    "$REPO_ROOT"
elif command -v podman >/dev/null 2>&1; then
  echo "Building image with Podman..."
  podman build \
    --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES}" \
    --build-arg "OPENCLAW_EXTENSIONS=${OPENCLAW_EXTENSIONS}" \
    -t "$IMAGE_NAME" \
    -f "$REPO_ROOT/Dockerfile" \
    "$REPO_ROOT"
else
  fail "Docker or Podman required to build image for Apple Container"
fi

# Create Container configuration
CONTAINER_CONFIG_DIR="$OPENCLAW_CONFIG_DIR/.container"
mkdir -p "$CONTAINER_CONFIG_DIR"

cat > "$CONTAINER_CONFIG_DIR/openclaw.json" << EOF
{
  "name": "$CONTAINER_NAME",
  "image": "$IMAGE_NAME",
  "ports": [
    "${OPENCLAW_GATEWAY_PORT:-18789}:18789",
    "${OPENCLAW_BRIDGE_PORT:-18790}:18790"
  ],
  "volumes": [
    "$OPENCLAW_CONFIG_DIR:/home/node/.openclaw",
    "$OPENCLAW_WORKSPACE_DIR:/home/node/.openclaw/workspace"
  ],
  "environment": {
    "HOME": "/home/node",
    "OPENCLAW_GATEWAY_TOKEN": "$OPENCLAW_GATEWAY_TOKEN",
    "TZ": "${OPENCLAW_TZ:-UTC}"
  },
  "command": [
    "node", "openclaw.mjs", "gateway",
    "--bind", "${OPENCLAW_GATEWAY_BIND:-lan}",
    "--port", "18789"
  ]
}
EOF

echo ""
echo "Starting OpenClaw with Apple Container..."
# Apple Container doesn't support --config flag, use explicit args
container run \
  -e "HOME=/home/node" \
  -e "OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN" \
  -e "TZ=${OPENCLAW_TZ:-UTC}" \
  -p "${OPENCLAW_GATEWAY_PORT:-18789}:18789" \
  -p "${OPENCLAW_BRIDGE_PORT:-18790}:18790" \
  -v "$OPENCLAW_CONFIG_DIR:/home/node/.openclaw" \
  -v "$OPENCLAW_WORKSPACE_DIR:/home/node/.openclaw/workspace" \
  "$IMAGE_NAME" \
  node openclaw.mjs gateway --bind "${OPENCLAW_GATEWAY_BIND:-lan}" --port 18789 || {
  echo "Note: If 'container run' failed, Apple Container may not support this operation yet."
  echo "Consider using Docker or Podman instead."
  exit 1
}

echo ""
echo "OpenClaw is running with Apple Container!"
echo "Dashboard: http://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}"
echo "Token: $OPENCLAW_GATEWAY_TOKEN"
