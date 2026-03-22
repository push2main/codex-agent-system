#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

ensure_runtime_dirs
ensure_project_state "codex-agent-system"

METADATA_FILE="$ROOT_DIR/projects/codex-agent-system/project.json"
PROJECT_MEMORY_FILE="$ROOT_DIR/projects/codex-agent-system/memory.md"

jq -e \
  --arg workspace "$ROOT_DIR" \
  --arg repo_url "https://github.com/push2main/codex-agent-system/" \
  --arg memory_file "$PROJECT_MEMORY_FILE" \
  '
    .project == "codex-agent-system" and
    .workspace == $workspace and
    .repo_url == $repo_url and
    .memory_file == $memory_file
  ' "$METADATA_FILE" >/dev/null

grep -q '^# Project Memory$' "$PROJECT_MEMORY_FILE"
grep -q "^workspace: $ROOT_DIR$" "$PROJECT_MEMORY_FILE"
grep -q '^repo_url: https://github.com/push2main/codex-agent-system/$' "$PROJECT_MEMORY_FILE"

resolved_workspace="$(resolve_project_workspace "codex-agent-system")"
[ "$resolved_workspace" = "$ROOT_DIR" ]

memory_context="$(read_memory_context "codex-agent-system")"
printf '%s' "$memory_context" | grep -q 'Project Memory'

echo "project state test passed"
