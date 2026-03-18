#!/usr/bin/env bash
# Unified OpenClaw deployment script
# Supports: Docker (default), Docker-in-Docker, Podman, Apple Container
# Run from repo root: ./deploy/unified-compose.sh [OPTIONS] [COMMAND]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

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

show_help() {
  cat << EOF
OpenClaw Unified Deployment Script

Usage: $0 [OPTIONS] [COMMAND]

Container Runtime Options:
  --docker              Use Docker (default)
  --dind                Use Docker-in-Docker
  --podman              Use Podman
  --apple-container     Use Apple Container

Commands:
  setup                 Setup and start OpenClaw (default)
  build                 Build image only
  start                 Start existing container
  stop                  Stop container
  restart               Restart container
  logs                  Show container logs
  status                Check container status
  shell                 Open shell in container

Apple Container Commands:
  install               Setup with auto-start and process monitoring
  uninstall             Remove auto-start configuration

Environment Variables:
  OPENCLAW_RUNTIME      Container runtime: docker, dind, podman, apple-container
  OPENCLAW_IMAGE        Image name (default: openclaw:local or openclaw:dind)
  OPENCLAW_GATEWAY_PORT Gateway port (default: 18789)
  OPENCLAW_BRIDGE_PORT  Bridge port (default: 18790)
  OPENCLAW_GATEWAY_BIND Bind address: lan, loopback (default: lan)
  OPENCLAW_CONFIG_DIR   Config directory (default: ~/.openclaw)
  OPENCLAW_WORKSPACE_DIR Workspace directory (default: ~/.openclaw/workspace)
  OPENCLAW_DOCKER_APT_PACKAGES Additional APT packages to install
  OPENCLAW_EXTENSIONS   Space-separated extension names to pre-install

Examples:
  $0 --docker setup                    # Setup with Docker
  $0 --dind setup                      # Setup with Docker-in-Docker
  $0 --podman setup                    # Setup with Podman
  $0 --apple-container setup           # Setup with Apple Container
  $0 --apple-container install         # Install with auto-start (macOS)
  $0 --apple-container start           # Start service
  $0 --apple-container status          # Check service status
  $0 --dind build                      # Build DinD image only
  $0 --docker logs                     # Show Docker logs

EOF
}

detect_runtime() {
  local runtime="${OPENCLAW_RUNTIME:-}"

  # Check command line flags
  for arg in "$@"; do
    case "$arg" in
      --docker) runtime="docker"; shift ;;
      --dind) runtime="dind"; shift ;;
      --podman) runtime="podman"; shift ;;
      --apple-container) runtime="apple-container"; shift ;;
    esac
  done

  # Auto-detect if not specified
  if [[ -z "$runtime" ]]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      runtime="docker"
    elif command -v podman >/dev/null 2>&1; then
      runtime="podman"
    elif command -v container >/dev/null 2>&1; then
      runtime="apple-container"
    else
      log_error "No container runtime found. Please install Docker, Podman, or Apple Container."
      exit 1
    fi
  fi

  echo "$runtime"
}

run_docker() {
  local cmd="${1:-setup}"

  case "$cmd" in
    setup)
      log_info "Setting up OpenClaw with Docker..."
      exec "$REPO_ROOT/docker-setup.sh"
      ;;
    build)
      log_info "Building Docker image..."
      docker build \
        --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES:-}" \
        --build-arg "OPENCLAW_EXTENSIONS=${OPENCLAW_EXTENSIONS:-}" \
        -t "${OPENCLAW_IMAGE:-openclaw:local}" \
        -f "$REPO_ROOT/Dockerfile" \
        "$REPO_ROOT"
      ;;
    start)
      docker compose -f "$REPO_ROOT/docker-compose.yml" up -d
      ;;
    stop)
      docker compose -f "$REPO_ROOT/docker-compose.yml" down
      ;;
    logs)
      docker compose -f "$REPO_ROOT/docker-compose.yml" logs -f
      ;;
    status)
      docker compose -f "$REPO_ROOT/docker-compose.yml" ps
      ;;
    shell)
      docker compose -f "$REPO_ROOT/docker-compose.yml" exec openclaw-gateway sh
      ;;
    *)
      log_error "Unknown command: $cmd"
      show_help
      exit 1
      ;;
  esac
}

run_dind() {
  local cmd="${1:-setup}"

  case "$cmd" in
    setup)
      log_info "Setting up OpenClaw with Docker-in-Docker..."
      exec "$SCRIPT_DIR/setup-dind.sh"
      ;;
    build)
      log_info "Building DinD image..."
      docker compose -f "$SCRIPT_DIR/docker-compose.dind.yml" build
      ;;
    start)
      docker compose -f "$SCRIPT_DIR/docker-compose.dind.yml" up -d
      ;;
    stop)
      docker compose -f "$SCRIPT_DIR/docker-compose.dind.yml" down
      ;;
    logs)
      docker compose -f "$SCRIPT_DIR/docker-compose.dind.yml" logs -f
      ;;
    status)
      docker compose -f "$SCRIPT_DIR/docker-compose.dind.yml" ps
      ;;
    shell)
      docker compose -f "$SCRIPT_DIR/docker-compose.dind.yml" exec openclaw-dind sh
      ;;
    *)
      log_error "Unknown command: $cmd"
      show_help
      exit 1
      ;;
  esac
}

run_podman() {
  local cmd="${1:-setup}"

  case "$cmd" in
    setup)
      log_info "Setting up OpenClaw with Podman..."
      exec "$REPO_ROOT/setup-podman.sh"
      ;;
    build)
      log_info "Building Podman image..."
      podman build \
        --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES:-}" \
        --build-arg "OPENCLAW_EXTENSIONS=${OPENCLAW_EXTENSIONS:-}" \
        -t "${OPENCLAW_IMAGE:-openclaw:local}" \
        -f "$REPO_ROOT/Dockerfile" \
        "$REPO_ROOT"
      ;;
    start)
      "$REPO_ROOT/scripts/run-openclaw-podman.sh" launch
      ;;
    stop)
      podman stop openclaw 2>/dev/null || true
      ;;
    logs)
      podman logs -f openclaw
      ;;
    status)
      podman ps --filter name=openclaw
      ;;
    shell)
      podman exec -it openclaw sh
      ;;
    *)
      log_error "Unknown command: $cmd"
      show_help
      exit 1
      ;;
  esac
}

run_apple_container() {
  local cmd="${1:-setup}"

  case "$cmd" in
    setup)
      log_info "Setting up OpenClaw with Apple Container..."
      "$SCRIPT_DIR/setup-apple-container.sh" setup
      ;;
    install)
      log_info "Installing OpenClaw with Apple Container (with auto-start)..."
      "$SCRIPT_DIR/setup-apple-container.sh" install
      ;;
    uninstall)
      log_info "Uninstalling OpenClaw Apple Container..."
      "$SCRIPT_DIR/setup-apple-container.sh" uninstall
      ;;
    build)
      log_info "Building Apple Container image..."
      "$SCRIPT_DIR/setup-apple-container.sh" build
      ;;
    start)
      log_info "Starting OpenClaw Apple Container..."
      "$SCRIPT_DIR/setup-apple-container.sh" start
      ;;
    stop)
      log_info "Stopping OpenClaw Apple Container..."
      "$SCRIPT_DIR/setup-apple-container.sh" stop
      ;;
    restart)
      log_info "Restarting OpenClaw Apple Container..."
      "$SCRIPT_DIR/setup-apple-container.sh" restart
      ;;
    logs)
      log_info "Showing Apple Container logs..."
      "$SCRIPT_DIR/setup-apple-container.sh" logs
      ;;
    status)
      log_info "Checking Apple Container status..."
      "$SCRIPT_DIR/setup-apple-container.sh" status
      ;;
    shell)
      log_warn "Apple Container does not support shell command directly."
      log_info "Use: container exec -it openclaw sh"
      ;;
    *)
      log_error "Unknown command: $cmd"
      show_help
      exit 1
      ;;
  esac
}

# Main
main() {
  local runtime
  runtime=$(detect_runtime "$@")
  log_info "Using container runtime: $runtime"

  # Remove runtime flags from args
  local args=()
  for arg in "$@"; do
    case "$arg" in
      --docker|--dind|--podman|--apple-container) ;;
      -h|--help) show_help; exit 0 ;;
      *) args+=("$arg") ;;
    esac
  done

  local cmd="${args[0]:-setup}"

  case "$runtime" in
    docker) run_docker "$cmd" ;;
    dind) run_dind "$cmd" ;;
    podman) run_podman "$cmd" ;;
    apple-container) run_apple_container "$cmd" ;;
    *)
      log_error "Unknown runtime: $runtime"
      exit 1
      ;;
  esac
}

main "$@"
