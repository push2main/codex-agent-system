#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/codex-logs"
RUNS_DIR="$LOG_DIR/runs"
MEMORY_DIR="$ROOT_DIR/codex-memory"
LEARNING_DIR="$ROOT_DIR/codex-learning"
QUEUE_DIR="$ROOT_DIR/queues"
PROJECTS_DIR="$ROOT_DIR/projects"
DASHBOARD_DIR="$ROOT_DIR/codex-dashboard"
SYSTEM_LOG="$LOG_DIR/system.log"
CODEX_RUNTIME_HOME="${CODEX_RUNTIME_HOME:-$LOG_DIR/codex-home}"
STATUS_FILE="$ROOT_DIR/status.txt"
QUEUE_RETRY_DIR="$LOG_DIR/queue-retries"
RULES_FILE="$LEARNING_DIR/rules.md"
RULES_CANDIDATE_FILE="$LEARNING_DIR/rules-candidate.md"
PROMPT_RULES_FILE="$LEARNING_DIR/prompt-rules.md"
TASK_LOG="${TASK_LOG:-$MEMORY_DIR/tasks.log}"
TASK_REGISTRY_FILE="${TASK_REGISTRY_FILE:-$MEMORY_DIR/tasks.json}"
METRICS_FILE="${METRICS_FILE:-$LEARNING_DIR/metrics.json}"
DECISIONS_FILE="$MEMORY_DIR/decisions.md"
CONTEXT_FILE="$MEMORY_DIR/context.md"
QUEUE_LIMIT="${QUEUE_LIMIT:-20}"
TASK_TIMEOUT_SECONDS="${TASK_TIMEOUT_SECONDS:-300}"
MAX_AGENT_RETRIES="${MAX_AGENT_RETRIES:-2}"

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ensure_runtime_dirs() {
  mkdir -p "$LOG_DIR" "$RUNS_DIR" "$MEMORY_DIR" "$LEARNING_DIR" "$QUEUE_DIR" "$PROJECTS_DIR" "$DASHBOARD_DIR" "$QUEUE_RETRY_DIR" "$CODEX_RUNTIME_HOME"
  [ -f "$SYSTEM_LOG" ] || : >"$SYSTEM_LOG"
  [ -f "$TASK_LOG" ] || : >"$TASK_LOG"
  [ -f "$TASK_REGISTRY_FILE" ] || printf '{\n  "tasks": []\n}\n' >"$TASK_REGISTRY_FILE"
  [ -f "$DECISIONS_FILE" ] || printf '# Decisions\n\n' >"$DECISIONS_FILE"
  [ -f "$CONTEXT_FILE" ] || printf '# Context\n\n' >"$CONTEXT_FILE"
  [ -f "$RULES_FILE" ] || printf '# Learned Rules\n\n' >"$RULES_FILE"
  [ -f "$RULES_CANDIDATE_FILE" ] || printf '# Candidate Rules\n\n' >"$RULES_CANDIDATE_FILE"
  [ -f "$PROMPT_RULES_FILE" ] || printf '# Prompt Rules\n\n' >"$PROMPT_RULES_FILE"
  if [ ! -f "$METRICS_FILE" ]; then
    cat >"$METRICS_FILE" <<EOF
{
  "total_tasks": 0,
  "success_rate": 0,
  "analysis_runs": 0,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "task_registry_total": 0,
  "last_task_score": 0
}
EOF
  fi
  if [ ! -f "$STATUS_FILE" ]; then
    cat >"$STATUS_FILE" <<EOF
state=idle
project=
task=
last_result=NONE
note=System initialized
updated_at=$(now_utc)
EOF
  fi
}

log_msg() {
  local level="$1"
  local component="$2"
  shift 2
  ensure_runtime_dirs
  local line
  line="[$(now_utc)] [$component] ${level}: $*"
  printf '%s\n' "$line" | tee -a "$SYSTEM_LOG" >&2
}

install_error_trap() {
  local component="$1"
  trap 'rc=$?; log_msg ERROR "'"$component"'" "Command failed at line ${BASH_LINENO[0]:-0} with exit code ${rc}"; exit "$rc"' ERR
}

write_status() {
  local state="$1"
  local project="$2"
  local task="$3"
  local last_result="${4:-UNKNOWN}"
  local note="${5:-}"
  ensure_runtime_dirs
  cat >"$STATUS_FILE" <<EOF
state=$state
project=$project
task=$task
last_result=$last_result
note=$note
updated_at=$(now_utc)
EOF
}

trim_text() {
  printf '%s' "$1" | awk '{$1=$1; print}'
}

safe_read_file() {
  local file_path="$1"
  if [ -f "$file_path" ]; then
    cat "$file_path"
  fi
}

safe_tail() {
  local line_count="$1"
  local file_path="$2"
  tail -n "$line_count" "$file_path" 2>/dev/null || true
}

safe_tail_structured_logs() {
  local line_count="$1"
  local file_path="$2"
  grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$file_path" 2>/dev/null | tail -n "$line_count" || true
}

normalize_task() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

project_state_dir() {
  printf '%s/%s\n' "$PROJECTS_DIR" "$1"
}

project_metadata_file() {
  printf '%s/project.json\n' "$(project_state_dir "$1")"
}

project_memory_file() {
  printf '%s/memory.md\n' "$(project_state_dir "$1")"
}

default_project_workspace() {
  local project_name="$1"
  if [ "$project_name" = "codex-agent-system" ]; then
    printf '%s\n' "$ROOT_DIR"
    return 0
  fi
  printf '%s/%s\n' "$PROJECTS_DIR" "$project_name"
}

default_project_repo_url() {
  local project_name="$1"
  if [ "$project_name" = "codex-agent-system" ]; then
    printf '%s\n' "https://github.com/push2main/codex-agent-system/"
    return 0
  fi
  printf '\n'
}

write_project_metadata() {
  local metadata_file="$1"
  local project_name="$2"
  local workspace="$3"
  local repo_url="$4"
  local memory_file="$5"

  python3 - "$metadata_file" "$project_name" "$workspace" "$repo_url" "$memory_file" <<'PY'
import json
import os
import sys

path, project, workspace, repo_url, memory_file = sys.argv[1:]
payload = {
    "project": project,
    "workspace": workspace,
    "repo_url": repo_url,
    "memory_file": memory_file,
}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

ensure_project_state() {
  local project_name="$1"
  local project_dir metadata_file memory_file workspace repo_url
  project_dir="$(project_state_dir "$project_name")"
  metadata_file="$(project_metadata_file "$project_name")"
  memory_file="$(project_memory_file "$project_name")"
  workspace="$(default_project_workspace "$project_name")"
  repo_url="$(default_project_repo_url "$project_name")"

  mkdir -p "$project_dir"

  if [ "$project_name" = "codex-agent-system" ] || [ ! -f "$metadata_file" ]; then
    write_project_metadata "$metadata_file" "$project_name" "$workspace" "$repo_url" "$memory_file"
  fi

  if [ ! -f "$memory_file" ]; then
    cat >"$memory_file" <<EOF
# Project Memory

project: $project_name
workspace: $workspace
repo_url: $repo_url

EOF
  fi
}

read_project_metadata_field() {
  local project_name="$1"
  local field_name="$2"
  local metadata_file
  metadata_file="$(project_metadata_file "$project_name")"
  [ -f "$metadata_file" ] || return 0

  python3 - "$metadata_file" "$field_name" <<'PY'
import json
import sys

path, field_name = sys.argv[1:]
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    payload = {}

value = str(payload.get(field_name) or "").strip()
if value:
    print(value)
PY
}

resolve_project_workspace() {
  local project_name="$1"
  local workspace
  ensure_project_state "$project_name"
  workspace="$(read_project_metadata_field "$project_name" "workspace")"
  if [ -n "$workspace" ]; then
    printf '%s\n' "$workspace"
    return 0
  fi
  default_project_workspace "$project_name"
}

queue_task_count() {
  local total=0
  local file
  shopt -s nullglob
  for file in "$QUEUE_DIR"/*.txt; do
    local count
    count="$(awk 'NF { count += 1 } END { print count + 0 }' "$file")"
    total=$((total + count))
  done
  shopt -u nullglob
  printf '%s\n' "$total"
}

dedupe_queue_file() {
  local queue_file="$1"
  [ -f "$queue_file" ] || return 0

  local before_count after_count temp_file
  before_count="$(awk 'NF { count += 1 } END { print count + 0 }' "$queue_file")"
  temp_file="$(mktemp)"
  awk '
    NF {
      original=$0
      cleaned=tolower($0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", original)
      gsub(/[[:space:]]+/, " ", cleaned)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", cleaned)
      if (!seen[cleaned]++) {
        print original
      }
    }
  ' "$queue_file" >"$temp_file"
  mv "$temp_file" "$queue_file"

  after_count="$(awk 'NF { count += 1 } END { print count + 0 }' "$queue_file")"
  if [ "$after_count" -lt "$before_count" ]; then
    log_msg WARN queue "Removed $((before_count - after_count)) duplicate task(s) from $(basename "$queue_file")"
  fi
}

task_exists_anywhere() {
  local project_name="${1:-}"
  local task_norm="$2"
  local file
  shopt -s nullglob
  for file in "$QUEUE_DIR"/*.txt; do
    if [ -n "$project_name" ] && [ "$(basename "$file" .txt)" != "$project_name" ]; then
      continue
    fi
    while IFS= read -r line; do
      [ -n "$(trim_text "$line")" ] || continue
      if [ "$(normalize_task "$line")" = "$task_norm" ]; then
        shopt -u nullglob
        return 0
      fi
    done <"$file"
  done
  shopt -u nullglob

  if [ -f "$STATUS_FILE" ]; then
    local current_project current_task
    current_project="$(awk -F= '$1=="project" { print $2 }' "$STATUS_FILE" 2>/dev/null || true)"
    current_task="$(awk -F= '$1=="task" { print $2 }' "$STATUS_FILE" 2>/dev/null || true)"
    if [ -n "$current_task" ] && [ "$(normalize_task "$current_task")" = "$task_norm" ]; then
      if [ -z "$project_name" ] || [ "$current_project" = "$project_name" ]; then
        return 0
      fi
    fi
  fi
  return 1
}

enforce_queue_safety() {
  local project_name="$1"
  local task="$2"
  local task_norm total
  task_norm="$(normalize_task "$task")"
  total="$(queue_task_count)"

  if [ "$total" -ge "$QUEUE_LIMIT" ]; then
    printf 'QUEUE_LIMIT_EXCEEDED\n'
    return 1
  fi
  if task_exists_anywhere "$project_name" "$task_norm"; then
    printf 'DUPLICATE_TASK\n'
    return 1
  fi
  return 0
}

next_task_from_queue() {
  local queue_file="$1"
  awk 'NF { print; exit }' "$queue_file"
}

remove_first_task_from_queue() {
  local queue_file="$1"
  local temp_file
  temp_file="$(mktemp)"
  awk '
    BEGIN { removed=0 }
    {
      if (!removed && NF) {
        removed=1
        next
      }
      print
    }
  ' "$queue_file" >"$temp_file"
  mv "$temp_file" "$queue_file"
}

relative_path() {
  python3 - "$1" "$2" <<'PY'
import os
import sys

print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))
PY
}

require_command() {
  local component="$1"
  local binary="$2"
  if command -v "$binary" >/dev/null 2>&1; then
    return 0
  fi
  log_msg ERROR "$component" "Required command is not available: $binary"
  return 1
}

write_json_file() {
  local output_file="$1"
  local status="$2"
  local message="$3"
  local data_json="${4:-null}"
  require_command json jq
  mkdir -p "$(dirname "$output_file")"
  jq -cn \
    --arg status "$status" \
    --arg message "$message" \
    --argjson data "$data_json" \
    '{status:$status,message:$message,data:$data}' >"$output_file"
}

print_json_file() {
  local file_path="$1"
  cat "$file_path"
}

json_get() {
  local file_path="$1"
  local filter="$2"
  jq -er "$filter" "$file_path"
}

validate_agent_json() {
  local file_path="$1"
  jq -e '
    type == "object" and
    (.status | type == "string") and
    (.message | type == "string") and
    (.data | type == "object")
  ' "$file_path" >/dev/null 2>&1
}

extract_bullet_rules_json() {
  local input_file="$1"
  local max_rules="${2:-5}"

  if [ ! -f "$input_file" ]; then
    printf '[]\n'
    return 0
  fi

  awk -v max_rules="$max_rules" '
    BEGIN { count=0 }
    /^- / {
      rule=$0
      sub(/^- /, "", rule)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", rule)
      if (length(rule) == 0) next
      if (!seen[rule]++) {
        print rule
        count += 1
      }
      if (count >= max_rules) exit
    }
  ' "$input_file" | jq -R . | jq -s '.'
}

write_rules_markdown_file() {
  local title="$1"
  local output_file="$2"
  local rules_json="${3:-[]}"

  require_command json jq
  mkdir -p "$(dirname "$output_file")"
  jq -r --arg title "$title" '
    [$title, ""] + (map("- " + .)) + [""]
    | .[]
  ' <<<"$rules_json" >"$output_file"
}

git_repo_root() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || true
}

generate_task_branch() {
  printf 'codex/%s-%s\n' "$(date +%Y%m%d-%H%M%S)" "$RANDOM"
}

ensure_task_branch() {
  local project_dir="$1"
  local repo_root
  repo_root="$(git_repo_root "$project_dir")"
  [ -n "$repo_root" ] || return 0

  local branch
  branch="$(generate_task_branch)"
  if git -C "$repo_root" switch -c "$branch" >/dev/null 2>&1; then
    log_msg INFO git "Switched to branch $branch"
    printf '%s\n' "$branch"
    return 0
  fi

  if git -C "$repo_root" checkout -b "$branch" >/dev/null 2>&1; then
    log_msg INFO git "Switched to branch $branch"
    printf '%s\n' "$branch"
    return 0
  fi

  log_msg WARN git "Failed to create branch $branch"
  return 1
}

unstage_runtime_artifacts() {
  local repo_root="$1"
  local -a runtime_paths=(
    "codex-logs/system.log"
    "codex-logs/runs"
    "codex-memory/context.md"
    "codex-memory/decisions.md"
    "codex-memory/tasks.log"
    "codex-memory/memory.db"
    "codex-memory/.hf-cache"
    "status.txt"
  )

  git -C "$repo_root" restore --staged -- "${runtime_paths[@]}" >/dev/null 2>&1 || \
    git -C "$repo_root" reset -q HEAD -- "${runtime_paths[@]}" >/dev/null 2>&1 || true
}

staged_secret_paths() {
  local repo_root="$1"
  git -C "$repo_root" diff --cached --name-only \
    | grep -E '(^|/)(\.env($|\.)|.*\.(pem|key|p12|crt|cer|kdbx)$|id_(rsa|ed25519)|.*secret.*|.*credential.*)' || true
}

has_staged_secret_content() {
  local repo_root="$1"
  git -C "$repo_root" diff --cached --no-ext-diff --unified=0 \
    | grep -E '^\+.*(BEGIN [A-Z ]*PRIVATE KEY|API[_-]?KEY|SECRET|TOKEN|PASSWORD|AWS_SECRET_ACCESS_KEY)' >/dev/null 2>&1
}

commit_project_changes() {
  local project_dir="$1"
  local task="$2"
  local repo_root
  repo_root="$(git_repo_root "$project_dir")"
  [ -n "$repo_root" ] || return 1

  local project_path
  project_path="$(relative_path "$project_dir" "$repo_root")"
  if [ "$project_path" = "." ]; then
    if ! git -C "$repo_root" add -A >/dev/null 2>&1; then
      log_msg WARN git "Failed to stage repository changes in $repo_root"
      return 1
    fi
  else
    if ! git -C "$repo_root" add -A -- "$project_path" >/dev/null 2>&1; then
      log_msg WARN git "Failed to stage project changes for $project_path"
      return 1
    fi
  fi

  unstage_runtime_artifacts "$repo_root"

  local secret_paths
  secret_paths="$(staged_secret_paths "$repo_root")"
  if [ -n "$secret_paths" ]; then
    log_msg ERROR git "Refusing to commit staged sensitive file(s): $(printf '%s' "$secret_paths" | tr '\n' ' ')"
    return 1
  fi

  if has_staged_secret_content "$repo_root"; then
    log_msg ERROR git "Refusing to commit staged content that looks like a secret"
    return 1
  fi

  if git -C "$repo_root" diff --cached --quiet; then
    log_msg INFO git "No staged changes detected for $project_path"
    return 1
  fi

  local commit_message
  commit_message="improve: $(printf '%s' "$task" | tr '\n' ' ' | cut -c1-63)"
  if git -C "$repo_root" commit -m "$commit_message" >/dev/null 2>&1; then
    log_msg INFO git "Created commit: $commit_message"
    return 0
  fi

  log_msg WARN git "Commit failed for $project_path"
  return 1
}

push_branch_and_create_pr() {
  local project_dir="$1"
  local branch="$2"
  local task="$3"
  local repo_root
  repo_root="$(git_repo_root "$project_dir")"
  [ -n "$repo_root" ] || return 0

  if ! git -C "$repo_root" remote get-url origin >/dev/null 2>&1; then
    log_msg INFO git "No origin remote configured; skipping push and PR"
    return 0
  fi

  if ! git -C "$repo_root" push -u origin "$branch" >/dev/null 2>&1; then
    log_msg WARN git "Push failed for $branch"
    return 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    log_msg INFO git "gh is not authenticated; skipping PR creation"
    return 0
  fi

  local existing_pr
  existing_pr="$(gh pr list --head "$branch" --json url --jq '.[0].url' 2>/dev/null || true)"
  if [ -n "$existing_pr" ] && [ "$existing_pr" != "null" ]; then
    printf '%s\n' "$existing_pr"
    return 0
  fi

  local default_branch
  default_branch="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
  if [ -z "$default_branch" ] || [ "$default_branch" = "null" ]; then
    log_msg INFO git "Default branch unavailable; skipping PR creation"
    return 0
  fi

  local title body pr_url
  title="codex: $(printf '%s' "$task" | tr '\n' ' ' | cut -c1-60)"
  body="Automated change for task:\n\n$task"
  pr_url="$(gh pr create --base "$default_branch" --head "$branch" --title "$title" --body "$body" 2>/dev/null || true)"
  if [ -n "$pr_url" ] && [ "$pr_url" != "null" ]; then
    printf '%s\n' "$pr_url"
    return 0
  fi

  log_msg INFO git "PR creation skipped or failed for $branch"
  return 0
}

notify_ntfy() {
  local title="$1"
  local message="$2"
  local priority="${3:-default}"
  local tags="${4:-robot}"
  local topic="${NTFY_TOPIC:-}"
  local base_url="${NTFY_URL:-https://ntfy.sh}"

  [ -n "$topic" ] || return 0
  if ! command -v curl >/dev/null 2>&1; then
    log_msg WARN notifications "curl is unavailable; notification skipped"
    return 0
  fi

  curl -fsS \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -H "Tags: $tags" \
    -d "$message" \
    "$base_url/$topic" >/dev/null 2>&1 || log_msg WARN notifications "Failed to send notification to $base_url/$topic"
}

read_memory_context() {
  local project_name="${1:-}"
  if [ -n "$project_name" ]; then
    local memory_file total_lines
    ensure_project_state "$project_name"
    memory_file="$(project_memory_file "$project_name")"
    total_lines="$(wc -l <"$memory_file" 2>/dev/null || printf '0')"
    if [ "$total_lines" -le 40 ]; then
      safe_read_file "$memory_file"
    else
      sed -n '1,6p' "$memory_file"
      printf '\n'
      tail -n 34 "$memory_file" 2>/dev/null || true
    fi
    printf '\n'
  fi
  safe_tail 20 "$DECISIONS_FILE"
}

run_memory_index() {
  log_msg INFO memory "Memory index skipped; using decisions tail context only"
  return 0
}

run_memory_query() {
  local _task="${1:-}"
  read_memory_context
}

sync_task_artifacts() {
  require_command memory python3
  ensure_runtime_dirs
  python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" "$TASK_REGISTRY_FILE" "$TASK_LOG" "$METRICS_FILE" >/dev/null
}

run_codex_exec() {
  local role="$1"
  local project_dir="$2"
  local prompt="$3"
  local output_file="$4"

  if [ "${CODEX_DISABLE:-0}" = "1" ]; then
    log_msg WARN "$role" "CODEX_DISABLE=1 set; using fallback logic"
    return 1
  fi

  if ! command -v codex >/dev/null 2>&1; then
    log_msg WARN "$role" "codex CLI not available; using fallback logic"
    return 1
  fi

  ensure_runtime_dirs
  mkdir -p "$(dirname "$output_file")"
  local raw_log_file
  raw_log_file="${output_file}.codex.log"

  local -a cmd
  cmd=(codex -a never)
  if [ -n "${CODEX_MODEL:-}" ]; then
    cmd+=(-m "$CODEX_MODEL")
  fi
  cmd+=(exec --skip-git-repo-check --ephemeral --color never -C "$project_dir" --add-dir "$ROOT_DIR" -s workspace-write -o "$output_file" "$prompt")

  log_msg INFO "$role" "Calling codex exec in $(relative_path "$project_dir" "$ROOT_DIR")"
  : >"$raw_log_file"
  if CODEX_HOME="$CODEX_RUNTIME_HOME" "${cmd[@]}" >"$raw_log_file" 2>&1 && [ -s "$output_file" ]; then
    if [ -s "$raw_log_file" ]; then
      log_msg INFO "$role" "codex exec completed successfully; raw output saved to $(relative_path "$raw_log_file" "$ROOT_DIR")"
    else
      rm -f "$raw_log_file"
      log_msg INFO "$role" "codex exec completed successfully"
    fi
    return 0
  fi

  log_msg WARN "$role" "codex exec failed or produced no output; raw output saved to $(relative_path "$raw_log_file" "$ROOT_DIR")"
  return 1
}

task_retry_key() {
  local project_name="$1"
  local task="$2"
  printf '%s::%s' "$project_name" "$task" | shasum -a 256 | awk '{ print $1 }'
}

task_retry_file() {
  local project_name="$1"
  local task="$2"
  printf '%s/%s.retry\n' "$QUEUE_RETRY_DIR" "$(task_retry_key "$project_name" "$task")"
}

get_task_retry_count() {
  local retry_file
  retry_file="$(task_retry_file "$1" "$2")"
  if [ -f "$retry_file" ]; then
    cat "$retry_file"
    return 0
  fi
  printf '0\n'
}

set_task_retry_count() {
  local retry_file
  retry_file="$(task_retry_file "$1" "$2")"
  printf '%s\n' "$3" >"$retry_file"
}

clear_task_retry_count() {
  local retry_file
  retry_file="$(task_retry_file "$1" "$2")"
  rm -f "$retry_file"
}

sync_task_registry_execution_state() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local next_status="${3:-}"
  local action="${4:-execution_update}"
  local note="${5:-}"
  local attempt="${6:-0}"
  local max_retries="${7:-$MAX_AGENT_RETRIES}"

  [ -n "$project_name" ] || return 0
  [ -n "$queue_task" ] || return 0
  [ -n "$next_status" ] || return 0

  ensure_runtime_dirs

  python3 - "$TASK_REGISTRY_FILE" "$project_name" "$queue_task" "$next_status" "$action" "$note" "$attempt" "$max_retries" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from typing import Any


path, project_name, queue_task, next_status, action, note, attempt, max_retries = sys.argv[1:]


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def task_execution_text(task: dict[str, Any]) -> str:
    return str(task.get("execution_task") or task.get("title") or "").strip()


def read_payload(file_path: str) -> dict[str, Any]:
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if isinstance(payload, dict):
            return payload
    except Exception:
        pass
    return {"tasks": []}


def write_payload(file_path: str, payload: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=os.path.dirname(file_path), encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
        temp_path = handle.name
    os.replace(temp_path, file_path)


payload = read_payload(path)
tasks = payload.get("tasks")
if not isinstance(tasks, list):
    tasks = []
    payload["tasks"] = tasks

project_key = normalize_project(project_name)
task_key = normalize_task(queue_task)

status_preference = {
    "running": {"running": 4, "approved": 3, "pending_approval": 2},
    "approved": {"running": 4, "approved": 3},
    "completed": {"running": 4, "approved": 3},
    "failed": {"running": 4, "approved": 3},
}.get(next_status, {})

selected_index: int | None = None
selected_rank: tuple[int, str, str, int] | None = None

for index, task in enumerate(tasks):
    if not isinstance(task, dict):
        continue

    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if task_project != project_key:
        continue

    if normalize_task(task_execution_text(task)) != task_key:
        continue

    current_status = str(task.get("status") or "pending_approval").strip().lower()
    status_rank = status_preference.get(current_status, 0)
    if status_rank <= 0:
        continue

    rank = (
        status_rank,
        str(task.get("updated_at") or ""),
        str(task.get("created_at") or ""),
        index,
    )
    if selected_rank is None or rank > selected_rank:
        selected_rank = rank
        selected_index = index

if selected_index is None:
    raise SystemExit(0)

task = dict(tasks[selected_index])
transition_at = now_utc()
from_status = str(task.get("status") or "pending_approval").strip().lower()
attempt_count = int(attempt or 0)
max_retry_count = int(max_retries or 0)

execution = task.get("execution")
if not isinstance(execution, dict):
    execution = {}

execution_state = next_status
if next_status == "approved" and action == "execute_retry":
    execution_state = "retrying"

execution.update(
    {
        "state": execution_state,
        "attempt": attempt_count,
        "max_retries": max_retry_count,
        "result": "SUCCESS" if next_status == "completed" else ("FAILURE" if next_status in {"approved", "failed"} else "RUNNING"),
        "updated_at": transition_at,
        "will_retry": next_status == "approved",
    }
)

task["project"] = project_name
task["status"] = next_status
task["updated_at"] = transition_at
task["execution"] = execution

if next_status == "running":
    task.setdefault("started_at", transition_at)
    task["last_started_at"] = transition_at
elif next_status == "approved":
    task["last_retry_at"] = transition_at
elif next_status == "completed":
    task["completed_at"] = transition_at
elif next_status == "failed":
    task["failed_at"] = transition_at

history = task.get("history")
if not isinstance(history, list):
    history = []

history.append(
    {
        "at": transition_at,
        "action": action,
        "from_status": from_status,
        "to_status": next_status,
        "project": project_name,
        "queue_task": queue_task,
        "note": note,
    }
)
task["history"] = history[-20:]

tasks[selected_index] = task
payload["tasks"] = tasks
write_payload(path, payload)
PY
}
