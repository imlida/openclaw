#!/usr/bin/env bash
# OpenClaw Apple Container Setup Script
# Supports: auto-start, process monitoring, automatic restart
# Run from repo root: ./deploy/setup-apple-container.sh [COMMAND]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CONTAINER_NAME="${OPENCLAW_CONTAINER_NAME:-openclaw}"
IMAGE_NAME="${OPENCLAW_IMAGE:-openclaw:local}"

# Configuration paths
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-$HOME/.openclaw/workspace}"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/ai.openclaw.gateway.plist"
LOG_DIR="$OPENCLAW_CONFIG_DIR/logs"
PID_FILE="$OPENCLAW_CONFIG_DIR/openclaw.pid"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

fail() {
  log_error "$*"
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing dependency: $1"
  fi
}

# Generate gateway token
generate_token() {
  if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
    else
      OPENCLAW_GATEWAY_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    fi
  fi
  echo "$OPENCLAW_GATEWAY_TOKEN"
}

# Build Docker image
build_image() {
  log_info "Building OpenClaw image..."
  
  export OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES:-}"
  export OPENCLAW_EXTENSIONS="${OPENCLAW_EXTENSIONS:-}"
  
  if command -v docker >/dev/null 2>&1; then
    log_info "Using Docker to build image..."
    docker build \
      --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES}" \
      --build-arg "OPENCLAW_EXTENSIONS=${OPENCLAW_EXTENSIONS}" \
      -t "$IMAGE_NAME" \
      -f "$REPO_ROOT/Dockerfile" \
      "$REPO_ROOT"
  elif command -v podman >/dev/null 2>&1; then
    log_info "Using Podman to build image..."
    podman build \
      --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES}" \
      --build-arg "OPENCLAW_EXTENSIONS=${OPENCLAW_EXTENSIONS}" \
      -t "$IMAGE_NAME" \
      -f "$REPO_ROOT/Dockerfile" \
      "$REPO_ROOT"
  else
    fail "Docker or Podman required to build image"
  fi
  
  log_success "Image built: $IMAGE_NAME"
}

# Create LaunchAgent plist for auto-start
create_launch_agent() {
  log_info "Creating LaunchAgent for auto-start..."
  
  mkdir -p "$LAUNCH_AGENT_DIR"
  mkdir -p "$LOG_DIR"
  
  local gateway_port="${OPENCLAW_GATEWAY_PORT:-18789}"
  local gateway_bind="${OPENCLAW_GATEWAY_BIND:-lan}"
  local tz="${OPENCLAW_TZ:-UTC}"
  
  cat > "$LAUNCH_AGENT_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>ai.openclaw.gateway</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/apple-container-daemon.sh</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/openclaw-daemon.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/openclaw-daemon-error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>OPENCLAW_CONFIG_DIR</key>
        <string>$OPENCLAW_CONFIG_DIR</string>
        <key>OPENCLAW_WORKSPACE_DIR</key>
        <string>$OPENCLAW_WORKSPACE_DIR</string>
        <key>OPENCLAW_GATEWAY_TOKEN</key>
        <string>$(generate_token)</string>
        <key>OPENCLAW_GATEWAY_PORT</key>
        <string>$gateway_port</string>
        <key>OPENCLAW_BRIDGE_PORT</key>
        <string>${OPENCLAW_BRIDGE_PORT:-18790}</string>
        <key>OPENCLAW_GATEWAY_BIND</key>
        <string>$gateway_bind</string>
        <key>OPENCLAW_IMAGE</key>
        <string>$IMAGE_NAME</string>
        <key>OPENCLAW_CONTAINER_NAME</key>
        <string>$CONTAINER_NAME</string>
        <key>OPENCLAW_TZ</key>
        <string>$tz</string>
    </dict>
</dict>
</plist>
EOF
  
  log_success "LaunchAgent created: $LAUNCH_AGENT_PLIST"
}

# Load LaunchAgent
load_launch_agent() {
  log_info "Loading LaunchAgent..."
  if launchctl list | grep -q "ai.openclaw.gateway"; then
    launchctl unload "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
  fi
  launchctl load "$LAUNCH_AGENT_PLIST"
  log_success "LaunchAgent loaded"
}

# Unload LaunchAgent
unload_launch_agent() {
  log_info "Unloading LaunchAgent..."
  if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
    launchctl unload "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
    log_success "LaunchAgent unloaded"
  else
    log_warn "LaunchAgent plist not found"
  fi
}

# Setup directories and configuration
setup_environment() {
  log_info "Setting up directories..."
  
  mkdir -p "$OPENCLAW_CONFIG_DIR"
  mkdir -p "$OPENCLAW_WORKSPACE_DIR"
  mkdir -p "$OPENCLAW_CONFIG_DIR/identity"
  mkdir -p "$OPENCLAW_CONFIG_DIR/agents/main/agent"
  mkdir -p "$OPENCLAW_CONFIG_DIR/agents/main/sessions"
  mkdir -p "$LOG_DIR"
  
  # Save configuration
  local env_file="$OPENCLAW_CONFIG_DIR/apple-container.env"
  cat > "$env_file" << EOF
# OpenClaw Apple Container Configuration
# Generated on $(date)
OPENCLAW_CONFIG_DIR=$OPENCLAW_CONFIG_DIR
OPENCLAW_WORKSPACE_DIR=$OPENCLAW_WORKSPACE_DIR
OPENCLAW_GATEWAY_PORT=${OPENCLAW_GATEWAY_PORT:-18789}
OPENCLAW_BRIDGE_PORT=${OPENCLAW_BRIDGE_PORT:-18790}
OPENCLAW_GATEWAY_BIND=${OPENCLAW_GATEWAY_BIND:-lan}
OPENCLAW_GATEWAY_TOKEN=$(generate_token)
OPENCLAW_IMAGE=$IMAGE_NAME
OPENCLAW_CONTAINER_NAME=$CONTAINER_NAME
OPENCLAW_TZ=${OPENCLAW_TZ:-UTC}
EOF
  
  log_success "Environment configured"
}

# Check if container is running using Apple Container
check_container_status() {
  if ! command -v container >/dev/null 2>&1; then
    echo "not_installed"
    return
  fi
  
  # Try to get container status
  if container list 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    local status
    status=$(container list 2>/dev/null | grep "$CONTAINER_NAME" | awk '{print $2}' || echo "unknown")
    echo "$status"
  else
    echo "not_running"
  fi
}

# Start the container
start_container() {
  local gateway_port="${OPENCLAW_GATEWAY_PORT:-18789}"
  local gateway_bind="${OPENCLAW_GATEWAY_BIND:-lan}"
  local tz="${OPENCLAW_TZ:-UTC}"
  local token
  token="${OPENCLAW_GATEWAY_TOKEN:-$(generate_token)}"
  
  log_info "Starting OpenClaw container..."
  
  # Check if already running
  local status
  status=$(check_container_status)
  if [[ "$status" == "running" ]]; then
    log_warn "Container is already running"
    return 0
  fi
  
  # Stop any existing container with same name
  container stop "$CONTAINER_NAME" 2>/dev/null || true
  container rm "$CONTAINER_NAME" 2>/dev/null || true
  
  # Start container
  container run \
    -d \
    --name "$CONTAINER_NAME" \
    -e "HOME=/home/node" \
    -e "OPENCLAW_GATEWAY_TOKEN=$token" \
    -e "TZ=$tz" \
    -p "${gateway_port}:18789" \
    -p "${OPENCLAW_BRIDGE_PORT:-18790}:18790" \
    -v "$OPENCLAW_CONFIG_DIR:/home/node/.openclaw" \
    -v "$OPENCLAW_WORKSPACE_DIR:/home/node/.openclaw/workspace" \
    "$IMAGE_NAME" \
    node openclaw.mjs gateway --bind "$gateway_bind" --port 18789
  
  log_success "Container started"
  
  # Wait for health check
  log_info "Waiting for gateway to be ready..."
  for i in {1..30}; do
    if curl -fsS "http://127.0.0.1:$gateway_port/healthz" >/dev/null 2>&1; then
      log_success "Gateway is ready!"
      return 0
    fi
    sleep 2
  done
  
  log_warn "Gateway health check timeout, but container is running"
}

# Stop the container
stop_container() {
  log_info "Stopping OpenClaw container..."
  
  if container stop "$CONTAINER_NAME" 2>/dev/null; then
    log_success "Container stopped"
  else
    log_warn "Container was not running"
  fi
  
  # Clean up
  container rm "$CONTAINER_NAME" 2>/dev/null || true
}

# Show container status
show_status() {
  log_info "Checking OpenClaw status..."
  
  # Check LaunchAgent status
  echo ""
  echo "=== LaunchAgent Status ==="
  if launchctl list | grep -q "ai.openclaw.gateway"; then
    echo "LaunchAgent: Loaded"
    launchctl list | grep "ai.openclaw.gateway"
  else
    echo "LaunchAgent: Not loaded"
  fi
  
  # Check container status
  echo ""
  echo "=== Container Status ==="
  local status
  status=$(check_container_status)
  echo "Container status: $status"
  
  if [[ "$status" == "running" ]]; then
    container list | grep "$CONTAINER_NAME" || true
  fi
  
  # Check gateway health
  echo ""
  echo "=== Gateway Health ==="
  local gateway_port="${OPENCLAW_GATEWAY_PORT:-18789}"
  if curl -fsS "http://127.0.0.1:$gateway_port/healthz" 2>/dev/null; then
    echo "Gateway: Healthy"
  else
    echo "Gateway: Not responding"
  fi
  
  # Show recent logs
  echo ""
  echo "=== Recent Logs ==="
  if [[ -f "$LOG_DIR/openclaw-daemon.log" ]]; then
    tail -n 10 "$LOG_DIR/openclaw-daemon.log"
  else
    echo "No daemon logs found"
  fi
}

# Show logs
show_logs() {
  local lines="${1:-50}"
  
  echo "=== Daemon Logs ==="
  if [[ -f "$LOG_DIR/openclaw-daemon.log" ]]; then
    tail -n "$lines" "$LOG_DIR/openclaw-daemon.log"
  else
    echo "No daemon logs found"
  fi
  
  echo ""
  echo "=== Container Logs ==="
  container logs "$CONTAINER_NAME" 2>/dev/null | tail -n "$lines" || echo "Container not running"
}

# Install auto-start (setup + enable)
install_auto_start() {
  log_info "Installing OpenClaw with auto-start..."
  
  require_cmd container
  
  # Build image if needed
  build_image
  
  # Setup environment
  setup_environment
  
  # Create and load LaunchAgent
  create_launch_agent
  load_launch_agent
  
  echo ""
  log_success "OpenClaw installed with auto-start!"
  echo ""
  echo "Dashboard: http://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}"
  echo "Logs: $LOG_DIR/"
  echo ""
  echo "Management commands:"
  echo "  ./deploy/setup-apple-container.sh start     # Start service"
  echo "  ./deploy/setup-apple-container.sh stop      # Stop service"
  echo "  ./deploy/setup-apple-container.sh restart   # Restart service"
  echo "  ./deploy/setup-apple-container.sh status    # Check status"
  echo "  ./deploy/setup-apple-container.sh logs      # View logs"
  echo "  ./deploy/setup-apple-container.sh uninstall # Remove auto-start"
}

# Uninstall auto-start
uninstall_auto_start() {
  log_info "Uninstalling OpenClaw auto-start..."
  
  # Stop and unload
  unload_launch_agent
  stop_container
  
  # Remove plist
  if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
    rm "$LAUNCH_AGENT_PLIST"
    log_success "LaunchAgent removed"
  fi
  
  log_success "OpenClaw auto-start uninstalled"
  log_info "Your data in $OPENCLAW_CONFIG_DIR is preserved"
}

# Restart service
restart_service() {
  log_info "Restarting OpenClaw..."
  stop_container
  sleep 2
  
  if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
    launchctl unload "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
    sleep 1
    launchctl load "$LAUNCH_AGENT_PLIST"
  else
    start_container
  fi
  
  log_success "OpenClaw restarted"
}

# Show help
show_help() {
  cat << EOF
OpenClaw Apple Container Setup Script

Usage: $0 [COMMAND]

Commands:
  setup         Setup and start OpenClaw (default, without auto-start)
  install       Setup with auto-start and process monitoring
  uninstall     Remove auto-start configuration
  start         Start the container
  stop          Stop the container
  restart       Restart the container
  status        Show container and service status
  logs          Show container logs
  build         Build the Docker image

Environment Variables:
  OPENCLAW_CONTAINER_NAME   Container name (default: openclaw)
  OPENCLAW_IMAGE            Image name (default: openclaw:local)
  OPENCLAW_CONFIG_DIR       Config directory (default: ~/.openclaw)
  OPENCLAW_WORKSPACE_DIR    Workspace directory (default: ~/.openclaw/workspace)
  OPENCLAW_GATEWAY_PORT     Gateway port (default: 18789)
  OPENCLAW_BRIDGE_PORT      Bridge port (default: 18790)
  OPENCLAW_GATEWAY_BIND     Bind address: lan, loopback (default: lan)
  OPENCLAW_GATEWAY_TOKEN    Gateway token (auto-generated if not set)
  OPENCLAW_TZ               Timezone (default: UTC)
  OPENCLAW_DOCKER_APT_PACKAGES  Additional APT packages to install
  OPENCLAW_EXTENSIONS       Space-separated extension names to pre-install

Examples:
  $0 install                          # Install with auto-start
  $0 start                            # Start the service
  $0 status                           # Check status
  $0 logs                             # View logs
  OPENCLAW_GATEWAY_PORT=8080 $0 install  # Use custom port

EOF
}

# Main
main() {
  local cmd="${1:-setup}"
  
  case "$cmd" in
    setup)
      require_cmd container
      build_image
      setup_environment
      start_container
      show_status
      ;;
    install)
      install_auto_start
      ;;
    uninstall)
      uninstall_auto_start
      ;;
    start)
      if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
        launchctl start ai.openclaw.gateway
      else
        start_container
      fi
      ;;
    stop)
      if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
        launchctl stop ai.openclaw.gateway
      else
        stop_container
      fi
      ;;
    restart)
      restart_service
      ;;
    status)
      show_status
      ;;
    logs)
      show_logs "${2:-50}"
      ;;
    build)
      build_image
      ;;
    -h|--help|help)
      show_help
      ;;
    *)
      log_error "Unknown command: $cmd"
      show_help
      exit 1
      ;;
  esac
}

main "$@"
