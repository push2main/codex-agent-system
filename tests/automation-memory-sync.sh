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
  mkdir -p "$TMP_DIR/home"
  bash -lc '
    unset CODEX_HOME
    export HOME="'"$TMP_DIR"'/home"
    source scripts/lib.sh
    append_automation_memory_entry \
      "codex-agent-system" \
      "push2main-codex-agent-system" \
      "- 2026-03-23T16:04:30Z | default home summary | external_sync_pending=false"
    [ "$AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING" = "false" ]
  '
)

DEFAULT_EXTERNAL_FILE="$TMP_DIR/home/.codex/automations/push2main-codex-agent-system/memory.md"
[ -f "$DEFAULT_EXTERNAL_FILE" ]
grep -qx 'project: codex-agent-system' "$DEFAULT_EXTERNAL_FILE"
grep -qx 'automation_id: push2main-codex-agent-system' "$DEFAULT_EXTERNAL_FILE"
grep -qx -- '- 2026-03-23T16:04:30Z | default home summary | external_sync_pending=false' "$DEFAULT_EXTERNAL_FILE"

(
  cd "$TEST_ROOT"
  export CODEX_HOME="$TMP_DIR/codex-home"
  bash -lc '
    export CODEX_HOME="'"$TMP_DIR"'/codex-home"
    source scripts/lib.sh
    append_automation_memory_entry \
      "codex-agent-system" \
      "push2main-codex-agent-system" \
      "- 2026-03-23T16:05:00Z | synced summary | external_sync_pending=false"
    [ "$AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING" = "false" ]
  '
)

EXTERNAL_FILE="$TMP_DIR/codex-home/automations/push2main-codex-agent-system/memory.md"
[ -f "$EXTERNAL_FILE" ]
grep -qx 'project: codex-agent-system' "$EXTERNAL_FILE"
grep -qx 'automation_id: push2main-codex-agent-system' "$EXTERNAL_FILE"
grep -qx -- '- 2026-03-23T16:05:00Z | synced summary | external_sync_pending=false' "$EXTERNAL_FILE"
[ ! -e "$TEST_ROOT/projects/codex-agent-system/automation-memory/push2main-codex-agent-system.md" ]

rm -f "$EXTERNAL_FILE"
mkdir -p "$TEST_ROOT/projects/codex-agent-system/automation-memory"
cat >"$TEST_ROOT/projects/codex-agent-system/automation-memory/push2main-codex-agent-system.md" <<'EOF'
# Automation Memory

project: codex-agent-system
automation_id: push2main-codex-agent-system

- 2026-03-23T16:05:30Z | mirrored history | external_sync_pending=true
EOF

(
  cd "$TEST_ROOT"
  export CODEX_HOME="$TMP_DIR/codex-home"
  bash -lc '
    export CODEX_HOME="'"$TMP_DIR"'/codex-home"
    source scripts/lib.sh
    sync_automation_memory_to_external_if_available \
      "codex-agent-system" \
      "push2main-codex-agent-system"
    [ "$AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING" = "false" ]
  '
)

[ -f "$EXTERNAL_FILE" ]
grep -qx 'project: codex-agent-system' "$EXTERNAL_FILE"
grep -qx 'automation_id: push2main-codex-agent-system' "$EXTERNAL_FILE"
grep -qx -- '- 2026-03-23T16:05:30Z | mirrored history | external_sync_pending=true' "$EXTERNAL_FILE"

touch "$TMP_DIR/not-a-dir"
(
  cd "$TEST_ROOT"
  bash -lc '
    export CODEX_HOME="'"$TMP_DIR"'/not-a-dir"
    source scripts/lib.sh
    append_automation_memory_entry \
      "codex-agent-system" \
      "push2main-codex-agent-system" \
      "- 2026-03-23T16:06:00Z | mirrored summary | external_sync_pending=true"
    [ "$AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING" = "true" ]
  '
)

MIRROR_FILE="$TEST_ROOT/projects/codex-agent-system/automation-memory/push2main-codex-agent-system.md"
[ -f "$MIRROR_FILE" ]
grep -qx 'project: codex-agent-system' "$MIRROR_FILE"
grep -qx 'automation_id: push2main-codex-agent-system' "$MIRROR_FILE"
grep -qx -- '- 2026-03-23T16:06:00Z | mirrored summary | external_sync_pending=true' "$MIRROR_FILE"

(
  cd "$TEST_ROOT"
  bash -lc '
    export CODEX_HOME="'"$TMP_DIR"'/codex-home"
    source scripts/lib.sh
    append_automation_memory_entry \
      "codex-agent-system" \
      "push2main-codex-agent-system" \
      "- 2026-03-23T16:07:00Z | recovered external sync | external_sync_pending=false"
    [ "$AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING" = "false" ]
  '
)

grep -qx -- '- 2026-03-23T16:06:00Z | mirrored summary | external_sync_pending=true' "$EXTERNAL_FILE"
grep -qx -- '- 2026-03-23T16:07:00Z | recovered external sync | external_sync_pending=false' "$EXTERNAL_FILE"
[ "$(grep -c '^-' "$EXTERNAL_FILE")" -eq 3 ]

echo "automation memory sync test passed"
