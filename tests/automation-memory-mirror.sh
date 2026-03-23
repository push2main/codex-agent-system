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
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects"

(
  cd "$TEST_ROOT"
  bash -lc '
    source scripts/lib.sh
    append_automation_memory_mirror \
      "codex-agent-system" \
      "push2main-codex-agent-system" \
      "- 2026-03-23T11:05:00Z | mirrored summary | external_sync_pending=true"
  '
)

MIRROR_FILE="$TEST_ROOT/projects/codex-agent-system/automation-memory/push2main-codex-agent-system.md"

[ -f "$MIRROR_FILE" ]
grep -qx 'project: codex-agent-system' "$MIRROR_FILE"
grep -qx 'automation_id: push2main-codex-agent-system' "$MIRROR_FILE"
grep -qx -- '- 2026-03-23T11:05:00Z | mirrored summary | external_sync_pending=true' "$MIRROR_FILE"

echo "automation memory mirror test passed"
