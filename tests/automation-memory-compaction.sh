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

EXTERNAL_FILE="$TMP_DIR/home/.codex/automations/push2main-codex-agent-system/memory.md"
MIRROR_FILE="$TEST_ROOT/projects/codex-agent-system/automation-memory/push2main-codex-agent-system.md"
mkdir -p "$(dirname "$EXTERNAL_FILE")" "$(dirname "$MIRROR_FILE")"

{
  printf '# Automation Memory\n\n'
  printf 'project: codex-agent-system\n'
  printf 'automation_id: push2main-codex-agent-system\n\n'
  for idx in $(seq 1 300); do
    printf -- '- 2026-03-25T00:%02d:00Z | entry=%03d | outcome=success | next=none | external_sync_pending=false\n' "$(( (idx - 1) % 60 ))" "$idx"
  done
} >"$EXTERNAL_FILE"
cp "$EXTERNAL_FILE" "$MIRROR_FILE"

(
  cd "$TEST_ROOT"
  HOME="$TMP_DIR/home" AUTOMATION_MEMORY_MAX_ENTRIES=256 bash -lc '
    source scripts/lib.sh
    append_automation_memory_entry \
      "codex-agent-system" \
      "push2main-codex-agent-system" \
      "- 2026-03-28T05:50:00Z | weakness=automation_memory_bloat | improvement=compact_recent_history | outcome=success | next=none"
  '
)

external_count="$(grep -c '^-' "$EXTERNAL_FILE")"
mirror_count="$(grep -c '^-' "$MIRROR_FILE")"

if [ "$external_count" -ne 256 ]; then
  echo "expected external automation memory to compact to 256 entries, got $external_count" >&2
  exit 1
fi

if [ "$mirror_count" -ne 256 ]; then
  echo "expected mirror automation memory to compact to 256 entries, got $mirror_count" >&2
  exit 1
fi

if grep -q 'entry=001' "$EXTERNAL_FILE"; then
  echo "expected oldest external entry to be trimmed during compaction" >&2
  exit 1
fi

if grep -q 'entry=001' "$MIRROR_FILE"; then
  echo "expected oldest mirror entry to be trimmed during compaction" >&2
  exit 1
fi

grep -Fqx -- '- 2026-03-28T05:50:00Z | weakness=automation_memory_bloat | improvement=compact_recent_history | outcome=success | next=none | external_sync_pending=false' "$EXTERNAL_FILE"
grep -Fqx -- '- 2026-03-28T05:50:00Z | weakness=automation_memory_bloat | improvement=compact_recent_history | outcome=success | next=none | external_sync_pending=false' "$MIRROR_FILE"

echo "automation memory compaction test passed"
