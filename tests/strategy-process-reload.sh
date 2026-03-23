#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/queues" "$TEST_ROOT/projects" "$TEST_ROOT/codex-dashboard"

(
  cd "$TEST_ROOT"
  source scripts/lib.sh
  current_marker="$(helper_scripts_marker)"
  persist_helper_runtime_state "false" "stale-helper-marker" "" "1" "1"

  helper_scripts_reload_required

  if process_helper_reload_required "$current_marker"; then
    echo "strategy process marker should ignore stale shared runtime marker" >&2
    exit 1
  fi
)

echo "strategy process reload test passed"
