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
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects/codex-agent-system"

cat >"$TEST_ROOT/projects/codex-agent-system/project.json" <<EOF
{
  "project": "codex-agent-system",
  "project_id": "codex-agent-system",
  "workspace": "$TEST_ROOT",
  "repo_url": "https://github.com/push2main/codex-agent-system/",
  "automation_id": "push2main-codex-agent-system",
  "memory_file": "$TEST_ROOT/projects/codex-agent-system/memory.md",
  "spec_file": "$TEST_ROOT/projects/codex-agent-system/spec.md",
  "policy_file": "$TEST_ROOT/projects/codex-agent-system/policy.json",
  "task_registry_file": "$TEST_ROOT/codex-memory/tasks.json"
}
EOF

mkdir -p "$TEST_ROOT/projects/codex-agent-system/automation-memory"
cat >"$TEST_ROOT/projects/codex-agent-system/automation-memory/push2main-codex-agent-system.md" <<'EOF'
# Automation Memory

project: codex-agent-system
automation_id: push2main-codex-agent-system

- 2026-03-25T00:10:00Z | automation memory context fixture | external_sync_pending=false
EOF

touch "$TMP_DIR/not-a-dir"

context_output="$(
  cd "$TEST_ROOT" && \
    CODEX_HOME="$TMP_DIR/not-a-dir" \
    bash -lc 'source scripts/lib.sh && ensure_runtime_dirs && read_memory_context "codex-agent-system" "automation memory context"'
)"

printf '%s' "$context_output" | grep -q '^# Automation Memory (recent)$'
printf '%s' "$context_output" | grep -q 'automation memory context fixture'

topic_context_output="$(
  cd "$TEST_ROOT" && \
    CODEX_HOME="$TMP_DIR/not-a-dir" \
    bash -lc 'source scripts/lib.sh && ensure_runtime_dirs && read_memory_context_with_topics "codex-agent-system" "automation memory context"'
)"

printf '%s' "$topic_context_output" | grep -q '^# Automation Memory (recent)$'
printf '%s' "$topic_context_output" | grep -q 'automation memory context fixture'

echo "project automation memory context test passed"
