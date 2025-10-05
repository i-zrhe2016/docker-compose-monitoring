#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need docker
need bash

COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.mysql.yml}

echo "Building MySQL images (master + replica)..."
DOCKER_BUILDKIT=1 docker compose -f "$COMPOSE_FILE" build
echo "Build completed."

