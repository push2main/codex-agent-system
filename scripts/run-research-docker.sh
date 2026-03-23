#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESEARCH_DOCKER_IMAGE="${RESEARCH_DOCKER_IMAGE:-python:3.12-slim}"
RESEARCH_DOCKER_CACHE="${RESEARCH_DOCKER_CACHE:-/tmp/codex-agent-system-research-cache}"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command...>" >&2
  exit 1
fi

if [ "${RESEARCH_DOCKER_DISABLE:-0}" = "1" ]; then
  exec "$@"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to run research in a container" >&2
  exit 1
fi

mkdir -p "$RESEARCH_DOCKER_CACHE"

docker run --rm \
  -e CI="${CI:-1}" \
  -e HOME=/tmp/codex-research-home \
  -e PYTHONDONTWRITEBYTECODE=1 \
  -v "$ROOT_DIR:/workspace" \
  -v "$RESEARCH_DOCKER_CACHE:/cache" \
  -w /workspace \
  "$RESEARCH_DOCKER_IMAGE" \
  bash -lc 'python -m pip install --disable-pip-version-check --quiet --cache-dir /cache yt-dlp >/tmp/research-install.log 2>&1 && exec "$@"' bash "$@"
