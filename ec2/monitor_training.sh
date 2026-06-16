#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER_NAME="${1:-tch-training-active}"

if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "Container not found: $CONTAINER_NAME" >&2
    exit 1
fi

echo "Container state:"
docker inspect --format 'status={{.State.Status}} exit={{.State.ExitCode}} started={{.State.StartedAt}}' \
    "$CONTAINER_NAME"

echo
echo "Live resources (Ctrl+C stops monitoring, not training):"
docker stats "$CONTAINER_NAME"
