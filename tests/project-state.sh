#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

ensure_runtime_dirs
ensure_project_state "codex-agent-system"
ensure_project_state "superheld"

METADATA_FILE="$ROOT_DIR/projects/codex-agent-system/project.json"
PROJECT_MEMORY_FILE="$ROOT_DIR/projects/codex-agent-system/memory.md"
SUPERHELD_METADATA_FILE="$ROOT_DIR/projects/superheld/project.json"
SUPERHELD_MEMORY_FILE="/Users/benediktpoller/code/push2main.io/superheld/.codex-agent/memory.md"
SUPERHELD_SPEC_FILE="/Users/benediktpoller/code/push2main.io/superheld/.codex-agent/spec.md"
SUPERHELD_POLICY_FILE="/Users/benediktpoller/code/push2main.io/superheld/.codex-agent/policy.json"
SUPERHELD_TASKS_FILE="/Users/benediktpoller/code/push2main.io/superheld/.codex-agent/tasks.json"

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
printf '%s' "$memory_context" | grep -q 'Project Spec'
printf '%s' "$memory_context" | grep -q 'Project Policy'

jq -e \
  --arg workspace "/Users/benediktpoller/code/push2main.io/superheld" \
  --arg repo_url "https://github.com/push2main/superheld" \
  --arg memory_file "$SUPERHELD_MEMORY_FILE" \
  --arg spec_file "$SUPERHELD_SPEC_FILE" \
  --arg policy_file "$SUPERHELD_POLICY_FILE" \
  --arg task_registry_file "$SUPERHELD_TASKS_FILE" \
  '
    .project == "superheld" and
    .workspace == $workspace and
    .repo_url == $repo_url and
    .memory_file == $memory_file and
    .spec_file == $spec_file and
    .policy_file == $policy_file and
    .task_registry_file == $task_registry_file
  ' "$SUPERHELD_METADATA_FILE" >/dev/null

resolved_superheld_workspace="$(resolve_project_workspace "superheld")"
[ "$resolved_superheld_workspace" = "/Users/benediktpoller/code/push2main.io/superheld" ]
[ "$(project_memory_file "superheld")" = "$SUPERHELD_MEMORY_FILE" ]
[ "$(project_spec_file "superheld")" = "$SUPERHELD_SPEC_FILE" ]
[ "$(project_policy_file "superheld")" = "$SUPERHELD_POLICY_FILE" ]
[ "$(project_task_registry_file "superheld")" = "$SUPERHELD_TASKS_FILE" ]
[ ! -e "$ROOT_DIR/projects/superheld/spec.md" ]
[ ! -e "$ROOT_DIR/projects/superheld/policy.json" ]
[ ! -e "$ROOT_DIR/projects/superheld/memory.md" ]

superheld_memory_context="$(read_memory_context "superheld")"
[ -n "$superheld_memory_context" ]

echo "project state test passed"
