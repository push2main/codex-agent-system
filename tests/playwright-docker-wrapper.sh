#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$ROOT_DIR/scripts/run-playwright-docker.sh" \
  bash -lc 'test -f tests/dashboard-auth-health.sh && test -f codex-dashboard/index.html && node --version >/dev/null'

echo "playwright docker wrapper test passed"
