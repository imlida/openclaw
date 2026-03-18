#!/bin/bash
set -e

# Start Docker daemon in background if not already running
if ! docker info >/dev/null 2>&1; then
    echo "Starting Docker daemon..."
    dockerd-entrypoint.sh dockerd &

    # Wait for Docker to be ready
    for i in {1..30}; do
        if docker info >/dev/null 2>&1; then
            echo "Docker daemon is ready"
            break
        fi
        sleep 1
    done
fi

# Ensure node user can access Docker
if [ -S /var/run/docker.sock ]; then
    chown node:node /var/run/docker.sock 2>/dev/null || true
fi

# Run sandbox setup if image exists
if docker images openclaw-sandbox:bookworm-slim --format "{{.Repository}}" | grep -q openclaw-sandbox; then
    echo "Sandbox image found"
else
    echo "Note: openclaw-sandbox image not found. Sandbox features will build it on first use."
fi

# Execute the main command
exec "$@"
