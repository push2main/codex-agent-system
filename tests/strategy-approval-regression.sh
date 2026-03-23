#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$ROOT_DIR/tests/strategy-enterprise-seeding.sh"
bash "$ROOT_DIR/tests/strategy-approved-handoff.sh"
bash "$ROOT_DIR/tests/task-registry-approved-handoff.sh"

echo "strategy approval regression test passed"
