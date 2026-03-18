#!/usr/bin/env bash
# OpenClaw Apple Container Daemon
# Process monitor and auto-restart for Apple Container
# This script is called by LaunchAgent ai.openclaw.gateway
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="${OPENCLAW_CONTAINER_NAME:-openclaw}"
IMAGE_NAME="${OPENCLAW_IMAGE:-openclaw:local}"

# Configuration
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"
TZ="${OPENCLAW_TZ:-UTC}"
HEALTH_CHECK_INTERVAL="${OPENCLAW_HEALTH_INTERVAL:-30}"
MAX_RESTART_ATTEMPTS="${OPENCLAW_MAX_RESTART:-5}"
RESTART_COOLDOWN="${OPENCLAW_RESTART_COOLDOWN:-60}"

# Paths
LOG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}/logs"
PID_FILE="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}/openclaw.pid"
RESTART_COUNT_FILE="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}/.restart_count"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Logging functions
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $*" | tee -a "$LOG_DIR/openclaw-daemon.log"
}

log_error() {
  log "[ERROR] $*"
}

log_warn() {
  log "[WARN] $*"
}

log_info() {
  log "[INFO] $*"
}

# Check if container command is available
check_container_cmd() {
  if ! command -v container >/dev/null 2>&1; then
    log_error "Apple Container command not found. Please install container tool."
    exit 1
  fi
}

# Check container health
health_check() {
  local port="${1:-$GATEWAY_PORT}"
  
  # First check if container is running
  if ! container list 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    return 1
  fi
  
  # Then check HTTP health endpoint
  if ! curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
    return 1
  fi
  
  return 0
}

# Get container status
get_container_status() {
  container list 2>/dev/null | grep "$CONTAINER_NAME" | awk '{print $2}' || echo "unknown"
}

# Clean up old container if exists
cleanup_container() {
  log_info "Cleaning up existing container..."
  container stop "$CONTAINER_NAME" 2>/dev/null || true
  container rm "$CONTAINER_NAME" 2>/dev/null || true
  sleep 1
}

# Start container
start_container() {
  log_info "Starting OpenClaw container..."
  
  # Generate token if not set
  local token="${OPENCLAW_GATEWAY_TOKEN:-}"
  if [[ -z "$token" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      token="$(openssl rand -hex 32)"
    else
      token="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    fi
    export OPENCLAW_GATEWAY_TOKEN="$token"
  fi
  
  # Ensure directories exist
  local config_dir="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
  local workspace_dir="${OPENCLAW_WORKSPACE_DIR:-$HOME/.openclaw/workspace}"
  mkdir -p "$config_dir" "$workspace_dir"
  
  # Start container
  if ! container run \
    -d \
    --name "$CONTAINER_NAME" \
    -e "HOME=/home/node" \
    -e "OPENCLAW_GATEWAY_TOKEN=$token" \
    -e "TZ=$TZ" \
    -p "${GATEWAY_PORT}:18789" \
    -p "${OPENCLAW_BRIDGE_PORT:-18790}:18790" \
    -v "$config_dir:/home/node/.openclaw" \
    -v "$workspace_dir:/home/node/.openclaw/workspace" \
    "$IMAGE_NAME" \
    node openclaw.mjs gateway --bind "$GATEWAY_BIND" --port 18789 2>>"$LOG_DIR/container-error.log"; then
    log_error "Failed to start container"
    return 1
  fi
  
  # Save PID
  echo $$ > "$PID_FILE"
  
  log_info "Container started with token: ${token:0:8}..."
  return 0
}

# Restart container with rate limiting
restart_container() {
  local current_count=0
  local last_restart=0
  
  # Read restart count and timestamp
  if [[ -f "$RESTART_COUNT_FILE" ]]; then
    read -r current_count last_restart < "$RESTART_COUNT_FILE" 2>/dev/null || true
  fi
  
  local now
  now=$(date +%s)
  
  # Reset count if enough time has passed
  if [[ $((now - last_restart)) -gt $RESTART_COOLDOWN ]]; then
    current_count=0
  fi
  
  # Check max restarts
  if [[ $current_count -ge $MAX_RESTART_ATTEMPTS ]]; then
    log_error "Max restart attempts ($MAX_RESTART_ATTEMPTS) reached. Waiting for cooldown..."
    sleep "$RESTART_COOLDOWN"
    current_count=0
  fi
  
  # Increment and save
  current_count=$((current_count + 1))
  echo "$current_count $now" > "$RESTART_COUNT_FILE"
  
  log_warn "Restarting container (attempt $current_count/$MAX_RESTART_ATTEMPTS)..."
  cleanup_container
  sleep 2
  start_container
}

# Wait for container to be ready
wait_for_ready() {
  local timeout="${1:-60}"
  log_info "Waiting for container to be ready (timeout: ${timeout}s)..."
  
  for ((i=0; i<timeout; i+=2)); do
    if health_check; then
      log_info "Container is healthy and ready"
      return 0
    fi
    sleep 2
  done
  
  log_warn "Container health check timeout"
  return 1
}

# Signal handlers
cleanup_and_exit() {
  log_info "Received signal, shutting down..."
  container stop "$CONTAINER_NAME" 2>/dev/null || true
  rm -f "$PID_FILE"
  exit 0
}

trap cleanup_and_exit SIGTERM SIGINT

# Main daemon loop
run_daemon() {
  log_info "=== OpenClaw Apple Container Daemon Started ==="
  log_info "Container: $CONTAINER_NAME"
  log_info "Image: $IMAGE_NAME"
  log_info "Port: $GATEWAY_PORT"
  log_info "Health check interval: ${HEALTH_CHECK_INTERVAL}s"
  
  check_container_cmd
  
  # Initial start
  if ! container list 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    cleanup_container
    if ! start_container; then
      log_error "Initial container start failed"
      exit 1
    fi
    wait_for_ready
  else
    log_info "Container already running"
  fi
  
  # Monitor loop
  local consecutive_failures=0
  local max_consecutive_failures=3
  
  while true; do
    sleep "$HEALTH_CHECK_INTERVAL"
    
    if ! health_check; then
      consecutive_failures=$((consecutive_failures + 1))
      log_warn "Health check failed ($consecutive_failures/$max_consecutive_failures)"
      
      if [[ $consecutive_failures -ge $max_consecutive_failures ]]; then
        log_error "Container unhealthy, triggering restart..."
        restart_container
        if wait_for_ready; then
          consecutive_failures=0
        fi
      fi
    else
      if [[ $consecutive_failures -gt 0 ]]; then
        log_info "Container recovered"
        consecutive_failures=0
      fi
    fi
  done
}

# One-shot start (used by LaunchAgent)
run_start() {
  check_container_cmd
  
  # Check if already running
  if container list 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    log_info "Container already running"
    exit 0
  fi
  
  cleanup_container
  start_container
  
  # Don't exit - keep running for LaunchAgent keepalive
  # The container runs in detached mode, so we monitor it
  log_info "Monitoring container..."
  
  while true; do
    if ! container list 2>/dev/null | grep -q "$CONTAINER_NAME"; then
      log_error "Container stopped unexpectedly"
      exit 1
    fi
    
    if ! health_check; then
      log_error "Container health check failed"
      exit 1
    fi
    
    sleep "$HEALTH_CHECK_INTERVAL"
  done
}

# Main
main() {
  local cmd="${1:-daemon}"
  
  case "$cmd" in
    daemon)
      run_daemon
      ;;
    start)
      run_start
      ;;
    *)
      echo "Usage: $0 [daemon|start]"
      exit 1
      ;;
  esac
}

main "$@"
