#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYWRIGHT_DOCKER_IMAGE="${PLAYWRIGHT_DOCKER_IMAGE:-mcr.microsoft.com/playwright:v1.55.0-noble}"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command...>" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to run Playwright tests in a container" >&2
  exit 1
fi

docker run --rm \
  -e CI="${CI:-1}" \
  -e PLAYWRIGHT_DOCKER_IMAGE="$PLAYWRIGHT_DOCKER_IMAGE" \
  -e UPDATE_DASHBOARD_SCREENSHOT_BASELINES="${UPDATE_DASHBOARD_SCREENSHOT_BASELINES:-0}" \
  -v "$ROOT_DIR:/workspace" \
  -w /workspace \
  "$PLAYWRIGHT_DOCKER_IMAGE" \
  "$@"
