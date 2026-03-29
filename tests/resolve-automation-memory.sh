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

MIRROR_FILE="$TEST_ROOT/projects/codex-agent-system/automation-memory/push2main-codex-agent-system.md"
mkdir -p "$(dirname "$MIRROR_FILE")"
cat >"$MIRROR_FILE" <<'EOF'
# Automation Memory

project: codex-agent-system
automation_id: push2main-codex-agent-system

- 2026-03-24T22:45:44Z | hydrated from mirror regression fixture | external_sync_pending=false
EOF

mkdir -p "$TMP_DIR/home"
HYDRATE_OUTPUT="$TMP_DIR/hydrate.json"
(
  cd "$TEST_ROOT"
  HOME="$TMP_DIR/home" bash scripts/resolve-automation-memory.sh \
    codex-agent-system \
    push2main-codex-agent-system >"$HYDRATE_OUTPUT"
)

DEFAULT_EXTERNAL_FILE="$TMP_DIR/home/.codex/automations/push2main-codex-agent-system/memory.md"
[ -f "$DEFAULT_EXTERNAL_FILE" ]
grep -qx -- '- 2026-03-24T22:45:44Z | hydrated from mirror regression fixture | external_sync_pending=false' "$DEFAULT_EXTERNAL_FILE"
jq -e \
  --arg memory_file "$DEFAULT_EXTERNAL_FILE" \
  '
    .status == "success" and
    .data.exists == true and
    .data.memory_file == $memory_file and
    .data.source == "external" and
    .data.external_hydrated == true and
    .data.external_sync_pending == false and
    .data.readable == true
  ' "$HYDRATE_OUTPUT" >/dev/null

FALLBACK_OUTPUT="$TMP_DIR/fallback.json"
touch "$TMP_DIR/not-a-dir"
(
  cd "$TEST_ROOT"
  CODEX_HOME="$TMP_DIR/not-a-dir" bash scripts/resolve-automation-memory.sh \
    codex-agent-system \
    push2main-codex-agent-system >"$FALLBACK_OUTPUT"
)

jq -e \
  --arg memory_file "$MIRROR_FILE" \
  '
    .status == "success" and
    .data.exists == true and
    .data.memory_file == $memory_file and
    .data.source == "mirror" and
    .data.external_hydrated == false and
    .data.external_sync_pending == true and
    .data.readable == true
  ' "$FALLBACK_OUTPUT" >/dev/null

EMPTY_OUTPUT="$TMP_DIR/empty.json"
rm -f "$MIRROR_FILE"
(
  cd "$TEST_ROOT"
  CODEX_HOME="$TMP_DIR/not-a-dir" bash scripts/resolve-automation-memory.sh \
    codex-agent-system \
    push2main-codex-agent-system >"$EMPTY_OUTPUT"
)

jq -e '
  .status == "success" and
  .data.exists == false and
  .data.memory_file == "" and
  .data.source == "none" and
  .data.external_hydrated == false and
  .data.external_sync_pending == true
' "$EMPTY_OUTPUT" >/dev/null

echo "resolve automation memory test passed"
