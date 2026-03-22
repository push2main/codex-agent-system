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
TRACKED_HELPER_SCRIPTS=(
  "scripts/lib.sh"
  "scripts/multi-queue.sh"
  "scripts/queue-worker.sh"
  "scripts/strategy-loop.sh"
  "agents/strategy.sh"
)

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
restart_needed=false
helper_scripts_marker=
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

read_status_field() {
  local field_name="$1"
  awk -F= -v key="$field_name" '$1==key { print substr($0, length(key) + 2); exit }' "$STATUS_FILE" 2>/dev/null || true
}

read_status_field_default() {
  local field_name="$1"
  local default_value="${2:-}"
  local value
  value="$(read_status_field "$field_name")"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default_value"
  fi
}

helper_scripts_marker() {
  python3 - "$ROOT_DIR" "${TRACKED_HELPER_SCRIPTS[@]}" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
paths = [pathlib.Path(path) for path in sys.argv[2:]]
digest = hashlib.sha256()

for relative_path in paths:
    digest.update(relative_path.as_posix().encode("utf-8"))
    digest.update(b"\0")
    digest.update((root / relative_path).read_bytes())
    digest.update(b"\0")

print(digest.hexdigest())
PY
}

write_status_with_restart_state() {
  local state="$1"
  local project="$2"
  local task="$3"
  local last_result="$4"
  local note="$5"
  local restart_needed="${6:-$(read_status_field_default "restart_needed" "false")}"
  local helper_marker="${7:-$(read_status_field_default "helper_scripts_marker" "")}"
  cat >"$STATUS_FILE" <<EOF
state=$state
project=$project
task=$task
last_result=$last_result
note=$note
restart_needed=$restart_needed
helper_scripts_marker=$helper_marker
updated_at=$(now_utc)
EOF
}

write_status() {
  local state="$1"
  local project="$2"
  local task="$3"
  local last_result="${4:-UNKNOWN}"
  local note="${5:-}"
  ensure_runtime_dirs
  write_status_with_restart_state "$state" "$project" "$task" "$last_result" "$note"
}

clear_restart_needed_status() {
  local state project task last_result note current_marker
  ensure_runtime_dirs
  state="$(read_status_field "state")"
  project="$(read_status_field "project")"
  task="$(read_status_field "task")"
  last_result="$(read_status_field "last_result")"
  note="$(read_status_field "note")"
  current_marker="$(helper_scripts_marker)"
  write_status_with_restart_state "$state" "$project" "$task" "$last_result" "$note" "false" "$current_marker"
}

update_restart_needed_status_for_helper_scripts() {
  local persisted_marker current_marker state project task last_result note
  ensure_runtime_dirs
  persisted_marker="$(read_status_field_default "helper_scripts_marker" "")"
  current_marker="$(helper_scripts_marker)"
  if [ "$persisted_marker" = "$current_marker" ]; then
    return 0
  fi

  state="$(read_status_field "state")"
  project="$(read_status_field "project")"
  task="$(read_status_field "task")"
  last_result="$(read_status_field "last_result")"
  note="$(read_status_field "note")"
  write_status_with_restart_state "$state" "$project" "$task" "$last_result" "$note" "true" "$current_marker"
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

  if [ -f "$TASK_REGISTRY_FILE" ]; then
    if python3 - "$TASK_REGISTRY_FILE" "$project_name" "$task_norm" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any


path, project_name, task_norm = sys.argv[1:]


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def task_execution_text(task: dict[str, Any]) -> str:
    return str(task.get("execution_task") or task.get("title") or "").strip()


try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    raise SystemExit(1)

tasks = payload.get("tasks") if isinstance(payload, dict) else []
if not isinstance(tasks, list):
    raise SystemExit(1)

project_filter = normalize_project(project_name)
for task in tasks:
    if not isinstance(task, dict):
        continue
    status = str(task.get("status") or "").strip().lower()
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    execution_state = str(execution.get("state") or "").strip().lower()
    if status not in {"approved", "running"} and execution_state not in {"running", "retrying"}:
        continue
    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if project_filter and task_project != project_filter:
        continue
    if normalize_task(task_execution_text(task)) == task_norm:
        raise SystemExit(0)

raise SystemExit(1)
PY
    then
      shopt -u nullglob
      return 0
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

normalize_provider_name() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | awk '{$1=$1; print}')"
  case "$value" in
    codex|claude) printf '%s\n' "$value" ;;
    *) printf '\n' ;;
  esac
}

provider_exec_reset_state() {
  AGENT_EXEC_PROVIDER=""
  AGENT_EXEC_PROVIDER_REASON=""
  AGENT_EXEC_PROVIDER_FATAL=0
}

mark_provider_unavailable() {
  AGENT_EXEC_PROVIDER="$(normalize_provider_name "${1:-}")"
  AGENT_EXEC_PROVIDER_REASON="$(trim_text "${2:-Provider is unavailable.}")"
  AGENT_EXEC_PROVIDER_FATAL=1
}

provider_exec_requires_abort() {
  [ "${AGENT_EXEC_PROVIDER_FATAL:-0}" = "1" ]
}

current_exec_provider() {
  printf '%s\n' "${AGENT_EXEC_PROVIDER:-}"
}

provider_exec_failure_reason() {
  printf '%s\n' "${AGENT_EXEC_PROVIDER_REASON:-}"
}

agent_json_schema() {
  cat <<'EOF'
{"type":"object","properties":{"status":{"type":"string"},"message":{"type":"string"},"data":{"type":"object"}},"required":["status","message","data"]}
EOF
}

compute_provider_stats() {
  local task_log="${TASK_LOG:-$MEMORY_DIR/tasks.log}"
  local stats_file="$LEARNING_DIR/provider-stats.json"
  local registry_file="${TASK_REGISTRY_FILE:-$MEMORY_DIR/tasks.json}"
  python3 - "$task_log" "$stats_file" "$registry_file" <<'PY'
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

task_log_path = Path(sys.argv[1])
stats_path = Path(sys.argv[2])
registry_path = Path(sys.argv[3])

if not task_log_path.exists():
    task_log_path.parent.mkdir(parents=True, exist_ok=True)
    task_log_path.write_text("", encoding="utf-8")


def infer_category(task_text: str) -> str:
    text = task_text.lower()
    categories = [
        ("ui", ("ui", "dashboard", "board", "layout", "css", "badge", "card", "navigation", "menu", "mobile", "scroll")),
        ("infra", ("queue", "runtime", "restart", "session", "tmux", "worker", "parallel", "lane")),
        ("auth", ("auth", "credential", "token", "oauth", "login")),
        ("testing", ("test", "smoke", "verify", "assert")),
        ("learning", ("learn", "metric", "rule", "prompt", "optimize", "pattern", "routing")),
        ("project", ("project", "workspace", "registry", "lifecycle")),
        ("code_quality", ("refactor", "cleanup", "lint", "format", "shape", "brief", "context")),
    ]
    for category, keywords in categories:
        if any(kw in text for kw in keywords):
            return category
    return "general"


records: list[dict] = []
for line in task_log_path.read_text(encoding="utf-8", errors="ignore").splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        records.append(json.loads(line))
    except (json.JSONDecodeError, ValueError):
        continue

registry_records_by_run: dict[str, dict] = {}
if registry_path.exists():
    try:
        registry_payload = json.loads(registry_path.read_text(encoding="utf-8"))
    except Exception:
        registry_payload = {}
    tasks = registry_payload.get("tasks") if isinstance(registry_payload, dict) else []
    if isinstance(tasks, list):
        for task in tasks:
            if not isinstance(task, dict):
                continue
            execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
            execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
            failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
            provider = str(
                execution_context.get("provider")
                or failure_context.get("provider")
                or execution.get("provider")
                or task.get("execution_provider")
                or ""
            ).strip().lower()
            if provider not in {"codex", "claude"}:
                continue
            run_id = str(
                execution_context.get("run_id")
                or failure_context.get("run_id")
                or execution.get("run_id")
                or ""
            ).strip()
            if not run_id:
                continue
            result = str(
                execution_context.get("result")
                or failure_context.get("result")
                or execution.get("result")
                or ("SUCCESS" if str(task.get("status") or "").strip().lower() == "completed" else "")
                or ("FAILURE" if str(task.get("status") or "").strip().lower() == "failed" else "")
            ).strip().upper()
            attempts = int(
                execution_context.get("attempts")
                or failure_context.get("attempts")
                or execution.get("attempt")
                or 0
            )
            registry_records_by_run[run_id] = {
                "timestamp": str(task.get("updated_at") or task.get("created_at") or ""),
                "project": str(task.get("project") or task.get("target_project") or "codex-agent-system"),
                "task": str(task.get("execution_task") or task.get("title") or ""),
                "provider": provider,
                "result": result,
                "attempts": attempts,
                "score": int(execution_context.get("score") or 0),
                "branch": "",
                "pr_url": "",
                "run_id": run_id,
                "duration_seconds": int(execution_context.get("duration_seconds") or 0),
            }

seen_run_ids: set[str] = set()
for record in records:
    run_id = str(record.get("run_id", "") or "").strip()
    provider = str(record.get("provider", "") or "").strip().lower()
    recovery = registry_records_by_run.get(run_id) if run_id else None
    if provider not in {"codex", "claude"} and isinstance(recovery, dict):
        record["provider"] = recovery["provider"]
    if run_id:
        seen_run_ids.add(run_id)

for run_id, recovery in registry_records_by_run.items():
    if run_id in seen_run_ids:
        continue
    records.append(recovery)

# provider -> category -> {success, total, attempts_sum}
stats: dict[str, dict[str, dict]] = defaultdict(lambda: defaultdict(lambda: {"success": 0, "total": 0, "attempts_sum": 0}))

for rec in records:
    provider = str(rec.get("provider", "") or "").strip().lower()
    if provider not in ("codex", "claude"):
        provider = "codex"
    task_text = str(rec.get("task", ""))
    category = infer_category(task_text)
    result = str(rec.get("result", "")).upper()
    bucket = stats[provider][category]
    bucket["total"] += 1
    bucket["attempts_sum"] += int(rec.get("attempts", 0) or 0)
    if result == "SUCCESS":
        bucket["success"] += 1

output: dict = {}
for provider, categories in sorted(stats.items()):
    provider_out: dict = {}
    for category, bucket in sorted(categories.items()):
        total = bucket["total"]
        provider_out[category] = {
            "success_rate": round(bucket["success"] / total, 4) if total > 0 else 0.0,
            "avg_attempts": round(bucket["attempts_sum"] / total, 2) if total > 0 else 0.0,
            "task_count": total,
        }
    output[provider] = provider_out

stats_path.parent.mkdir(parents=True, exist_ok=True)
stats_path.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

score_provider_for_category() {
  local task_text="${1:-}"
  local stats_file="$LEARNING_DIR/provider-stats.json"

  if [ ! -f "$stats_file" ]; then
    return 0
  fi

  python3 - "$stats_file" "$task_text" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

stats_path = Path(sys.argv[1])
task_text = sys.argv[2]

# --- infer_category (same logic as compute_provider_stats) ---
def infer_category(text: str) -> str:
    text = text.lower()
    categories = [
        ("ui", ("ui", "dashboard", "board", "layout", "css", "badge", "card", "navigation", "menu", "mobile", "scroll")),
        ("infra", ("queue", "runtime", "restart", "session", "tmux", "worker", "parallel", "lane")),
        ("auth", ("auth", "credential", "token", "oauth", "login")),
        ("testing", ("test", "smoke", "verify", "assert")),
        ("learning", ("learn", "metric", "rule", "prompt", "optimize", "pattern", "routing")),
        ("project", ("project", "workspace", "registry", "lifecycle")),
        ("code_quality", ("refactor", "cleanup", "lint", "format", "shape", "brief", "context")),
    ]
    for category, keywords in categories:
        if any(kw in text for kw in keywords):
            return category
    return "general"


try:
    stats = json.loads(stats_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

if not isinstance(stats, dict) or not stats:
    raise SystemExit(0)

category = infer_category(task_text)

# Gather per-provider scores for this category
candidates: list[tuple[str, float, int]] = []  # (provider, success_rate, task_count)
for provider, categories_map in stats.items():
    if not isinstance(categories_map, dict):
        continue
    entry = categories_map.get(category)
    if not isinstance(entry, dict):
        continue
    task_count = int(entry.get("task_count", 0))
    success_rate = float(entry.get("success_rate", 0.0))
    candidates.append((provider, success_rate, task_count))

# Require at least one provider with >= 3 historical tasks for this category
qualified = [(p, sr, tc) for p, sr, tc in candidates if tc >= 3]
if not qualified:
    raise SystemExit(0)

# Sort by success_rate descending, then task_count descending for ties
qualified.sort(key=lambda x: (-x[1], -x[2]))

best_provider, best_rate, best_count = qualified[0]

# Compute confidence: high if clear winner, medium if marginal
confidence = "high"
if len(qualified) >= 2:
    runner_up_rate = qualified[1][1]
    delta = best_rate - runner_up_rate
    if delta < 0.15:
        confidence = "low"
    elif delta < 0.30:
        confidence = "medium"

# Output: provider, confidence, reason (one per line)
reason = (
    f"{best_provider} has {best_rate:.0%} success rate over {best_count} tasks "
    f"in category '{category}' (confidence: {confidence})"
)
print(best_provider)
print(confidence)
print(reason)
PY
}

resolve_task_provider_info() {
  local project_name="${1:-}"
  local queue_task="${2:-}"

  python3 - "$TASK_REGISTRY_FILE" "$project_name" "$queue_task" "$LEARNING_DIR/provider-stats.json" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any


path, project_name, queue_task, stats_path = sys.argv[1:]


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def normalize_task(value: Any) -> str:
    return normalize_text(value).lower()


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def normalize_provider(value: Any) -> str:
    candidate = str(value or "").strip().lower()
    return candidate if candidate in {"codex", "claude"} else ""


def infer_category(text: str) -> str:
    lowered = normalize_text(text).lower()
    categories = [
        ("ui", ("ui", "dashboard", "board", "layout", "css", "badge", "card", "navigation", "menu", "mobile", "scroll", "iphone", "ipad", "tablet")),
        ("infra", ("queue", "runtime", "restart", "session", "tmux", "worker", "parallel", "lane")),
        ("auth", ("auth", "credential", "token", "oauth", "login")),
        ("testing", ("test", "smoke", "verify", "assert")),
        ("learning", ("learn", "metric", "rule", "prompt", "optimize", "pattern", "routing")),
        ("project", ("project", "workspace", "registry", "lifecycle")),
        ("code_quality", ("refactor", "cleanup", "lint", "format", "shape", "brief", "context")),
    ]
    for category, keywords in categories:
        if any(keyword in lowered for keyword in keywords):
            return category
    return "general"


def task_execution_text(task: dict[str, Any]) -> str:
    return str(task.get("execution_task") or task.get("title") or "").strip()


def infer_provider(title: Any, reason: Any, task_intent: Any) -> tuple[str, str, str]:
    intent = task_intent if isinstance(task_intent, dict) else {}
    combined = " ".join(
        normalize_text(value)
        for value in (
            title,
            reason,
            intent.get("objective"),
            intent.get("context_hint"),
            " ".join(intent.get("constraints") or []),
            " ".join(intent.get("success_signals") or []),
        )
        if normalize_text(value)
    ).lower()

    if "claude" in combined or "anthropic" in combined:
        return ("claude", "Task text explicitly references Claude or Anthropic.", "keyword")
    return ("codex", "Default provider is Codex when no explicit Claude hint is present.", "default")


def learned_provider(title: Any, reason: Any, task_intent: Any) -> tuple[str, str, str] | None:
    combined = " ".join(
        normalize_text(value)
        for value in (
            title,
            reason,
            (task_intent or {}).get("objective") if isinstance(task_intent, dict) else "",
            (task_intent or {}).get("context_hint") if isinstance(task_intent, dict) else "",
        )
        if normalize_text(value)
    ).lower()
    if "claude" in combined or "anthropic" in combined or "codex" in combined:
        return None

    try:
        with open(stats_path, "r", encoding="utf-8") as handle:
            stats = json.load(handle)
    except Exception:
        return None
    if not isinstance(stats, dict) or not stats:
        return None

    category = infer_category(combined)
    candidates: list[tuple[str, float, int]] = []
    for provider, categories_map in stats.items():
        if not isinstance(categories_map, dict):
            continue
        entry = categories_map.get(category)
        if not isinstance(entry, dict):
            continue
        task_count = int(entry.get("task_count", 0) or 0)
        success_rate = float(entry.get("success_rate", 0.0) or 0.0)
        candidates.append((normalize_provider(provider), success_rate, task_count))

    qualified = [(provider, success_rate, task_count) for provider, success_rate, task_count in candidates if provider and task_count >= 3]
    if not qualified:
        return None

    qualified.sort(key=lambda item: (-item[1], -item[2], item[0]))
    best_provider, best_rate, best_count = qualified[0]
    confidence = "high"
    if len(qualified) >= 2:
        delta = best_rate - qualified[1][1]
        if delta < 0.15:
            confidence = "low"
        elif delta < 0.30:
            confidence = "medium"

    if confidence == "low":
        return None

    return (
        best_provider,
        f"Learned routing selected {best_provider} for category '{category}' from provider history ({best_rate:.0%} success over {best_count} tasks, confidence: {confidence}).",
        "learned",
    )


def read_tasks(file_path: str) -> list[dict[str, Any]]:
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        return []
    tasks = payload.get("tasks") if isinstance(payload, dict) else []
    return tasks if isinstance(tasks, list) else []


project_key = normalize_project(project_name)
task_key = normalize_task(queue_task)
status_rank = {"running": 5, "approved": 4, "pending_approval": 3, "completed": 2, "failed": 1}
selected: dict[str, Any] | None = None
selected_rank: tuple[int, str, str, int] | None = None

for index, task in enumerate(read_tasks(path)):
    if not isinstance(task, dict):
        continue
    if normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system") != project_key:
        continue
    if normalize_task(task_execution_text(task)) != task_key:
        continue
    rank = (
        status_rank.get(str(task.get("status") or "").strip().lower(), 0),
        str(task.get("updated_at") or ""),
        str(task.get("created_at") or ""),
        index,
    )
    if selected_rank is None or rank > selected_rank:
        selected_rank = rank
        selected = task

if isinstance(selected, dict):
    provider_selection = selected.get("provider_selection") if isinstance(selected.get("provider_selection"), dict) else {}
    explicit = normalize_provider(selected.get("execution_provider") or provider_selection.get("selected"))
    if explicit:
        reason = normalize_text(provider_selection.get("reason")) or f"Provider is pinned on the task: {explicit}."
        source = normalize_text(provider_selection.get("source")) or "task_registry"
        print(explicit)
        print(reason)
        print(source)
        raise SystemExit(0)
    learned = learned_provider(selected.get("title"), selected.get("reason"), selected.get("task_intent"))
    if learned is not None:
        provider, reason, source = learned
        print(provider)
        print(reason)
        print(source)
        raise SystemExit(0)
    provider, reason, source = infer_provider(selected.get("title"), selected.get("reason"), selected.get("task_intent"))
    print(provider)
    print(reason)
    print(source)
    raise SystemExit(0)

provider, reason, source = infer_provider(queue_task, "", {})
print(provider)
print(reason)
print(source)
PY
}

extract_claude_auth_failure_reason() {
  local raw_log_file="$1"
  python3 - "$raw_log_file" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    raise SystemExit(0)

content = path.read_text(encoding="utf-8", errors="ignore")
patterns = [
    "Failed to authenticate",
    "authentication_error",
    "OAuth token has expired",
    "Please obtain a new token or refresh your existing token",
    "401",
]

for pattern in patterns:
    if pattern in content:
        for line in content.splitlines():
            candidate = line.strip()
            if candidate:
                print(candidate[:400])
                raise SystemExit(0)
        print(pattern)
        raise SystemExit(0)
PY
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
    "codex-logs/codex-home"
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

build_similar_task_context() {
  local task_text="${1:-}"
  local project_name="${2:-}"

  python3 - "$TASK_REGISTRY_FILE" "$task_text" "$project_name" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


registry_path = Path(sys.argv[1])
task_text = sys.argv[2]
project_name = sys.argv[3].strip().lower()

stopwords = {
    "a",
    "an",
    "and",
    "are",
    "auf",
    "bei",
    "das",
    "dem",
    "den",
    "der",
    "die",
    "ein",
    "eine",
    "for",
    "im",
    "in",
    "ist",
    "mit",
    "oder",
    "task",
    "the",
    "to",
    "ui",
    "und",
}


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def original_failed_root_id(task: dict[str, Any]) -> str:
    direct = str(task.get("original_failed_root_id") or "").strip()
    if direct:
        return direct

    for context_key in ("failure_context", "execution_context"):
        context = task.get(context_key)
        if not isinstance(context, dict):
            continue
        candidate = str(context.get("original_failed_root_id") or "").strip()
        if candidate:
            return candidate

    return ""


def tokenize(value: Any) -> set[str]:
    tokens: set[str] = set()
    for token in re.findall(r"[a-z0-9_/-]+", str(value or "").lower()):
        if len(token) < 3 or token in stopwords:
            continue
        tokens.add(token)
    return tokens


def read_tasks() -> list[dict[str, Any]]:
    try:
        payload = json.loads(registry_path.read_text(encoding="utf-8"))
    except Exception:
        return []
    tasks = payload.get("tasks")
    return [task for task in tasks if isinstance(task, dict)] if isinstance(tasks, list) else []


query_tokens = tokenize(task_text)
if not query_tokens:
    print("[]")
    raise SystemExit(0)

candidates: list[tuple[int, str, str, dict[str, Any]]] = []
for task in read_tasks():
    status = str(task.get("status") or "").strip().lower()
    if status not in {"completed", "failed", "approved", "rejected"}:
        continue
    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if project_name and task_project != project_name:
        continue

    corpus = "\n".join(
        [
            str(task.get("title") or ""),
            str(task.get("reason") or ""),
            str(task.get("hypothesis") or ""),
            str(task.get("experiment") or ""),
            str((task.get("task_intent") or {}).get("objective") if isinstance(task.get("task_intent"), dict) else ""),
            str((task.get("failure_context") or {}).get("failed_step") if isinstance(task.get("failure_context"), dict) else ""),
        ]
    )
    overlap = query_tokens & tokenize(corpus)
    if not overlap:
        continue

    candidates.append(
        (
            len(overlap),
            str(task.get("updated_at") or task.get("created_at") or ""),
            str(task.get("id") or ""),
            task,
        )
    )

selected: list[dict[str, Any]] = []
for _, _, _, task in sorted(candidates, reverse=True)[:3]:
    selected.append(
        {
            "id": str(task.get("id") or "").strip(),
            "title": str(task.get("title") or "").strip(),
            "status": str(task.get("status") or "").strip(),
            "original_failed_root_id": original_failed_root_id(task),
            "reason": str(task.get("reason") or "").strip(),
            "task_intent": task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {},
            "execution_context": task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {},
            "failure_context": task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {},
        }
    )

print(json.dumps(selected, indent=2))
PY
}

build_prompt_source_context() {
  local task_text="${1:-}"
  local step_text="${2:-}"

  python3 - "$ROOT_DIR" "$task_text" "$step_text" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path


root = Path(sys.argv[1])
task_text = sys.argv[2]
step_text = sys.argv[3]
combined = f"{task_text}\n{step_text}".strip()
combined_lower = combined.lower()

stopwords = {
    "a",
    "an",
    "and",
    "are",
    "bei",
    "das",
    "dem",
    "den",
    "der",
    "die",
    "ein",
    "eine",
    "exact",
    "for",
    "genau",
    "into",
    "ist",
    "mit",
    "oder",
    "return",
    "the",
    "und",
    "with",
}

domain_files = [
    (
        "agent",
        ("agent", "claude", "codex", "planner", "dispatch", "prompt", "model", "reasoning", "reviewer", "evaluator", "orchestrator"),
        ("run_codex_exec(", "cmd=(codex -a never)"),
        [
            "agents/planner.sh",
            "agents/coder.sh",
            "agents/reviewer.sh",
            "agents/evaluator.sh",
            "agents/orchestrator.sh",
            "scripts/lib.sh",
        ],
    ),
    (
        "ui",
        ("ui", "dashboard", "layout", "route", "component", "mobile", "scroll", "board", "navigation", "menu"),
        ("renderTaskList", "refreshTaskRegistry", "data-task-filter", "task-board", "scroll"),
        [
            "codex-dashboard/index.html",
            "codex-dashboard/server.js",
            "tests/dashboard-task-visibility.sh",
            "tests/system-smoke.sh",
        ],
    ),
    (
        "registry",
        ("approval", "approved", "pending", "queue", "backlog", "registry", "board"),
        ("createTaskRegistryItem(", "transitionTaskRegistryItem(", "queue_handoff", "pending_approval", "approved"),
        [
            "codex-dashboard/server.js",
            "scripts/lib.sh",
            "tests/task-registry-create.sh",
            "tests/system-smoke.sh",
        ],
    ),
]

selected_files: list[str] = []
focus_tokens: list[str] = []
for _, keywords, anchors, files in domain_files:
    if any(keyword in combined_lower for keyword in keywords):
        for anchor in anchors:
            if anchor.lower() not in focus_tokens:
                focus_tokens.append(anchor.lower())
        for file in files:
            if file not in selected_files:
                selected_files.append(file)

if not selected_files:
    selected_files = [
        "agents/orchestrator.sh",
        "scripts/lib.sh",
        "codex-dashboard/server.js",
    ]

tokens = []
for raw_token in re.findall(r"[a-zA-Z0-9_/-]+", combined_lower):
    if len(raw_token) < 3 or raw_token in stopwords:
        continue
    if raw_token not in tokens:
        tokens.append(raw_token)

if "codex" in combined_lower and "codex" not in tokens:
    tokens.insert(0, "codex")
if "claude" in combined_lower and "claude" not in tokens:
    tokens.insert(0, "claude")

tokens = (focus_tokens + tokens)[:14]


def slice_ranges(lines: list[str], keywords: list[str], primary_keywords: list[str]) -> list[tuple[int, int]]:
    if not lines:
        return []

    def collect_matches(active_keywords: list[str]) -> list[int]:
        matches: list[int] = []
        for index, line in enumerate(lines):
            lower = line.lower()
            if any(keyword in lower for keyword in active_keywords):
                matches.append(index)
            if len(matches) >= 4:
                break
        return matches

    matches = collect_matches(primary_keywords)
    if not matches:
        matches = collect_matches(keywords)

    if not matches:
        return [(0, min(len(lines), 40))]

    ranges: list[tuple[int, int]] = []
    for match in matches:
        start = max(0, match - 6)
        end = min(len(lines), match + 7)
        if ranges and start <= ranges[-1][1]:
            previous_start, previous_end = ranges[-1]
            ranges[-1] = (previous_start, max(previous_end, end))
        else:
            ranges.append((start, end))
    return ranges[:3]


candidate_files: list[tuple[int, str, list[str]]] = []
for relative_file in selected_files:
    path = root / relative_file
    if not path.is_file():
        continue

    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    haystack = "\n".join(lines).lower()
    score = sum(haystack.count(token) for token in tokens) + len(lines) // 400
    if relative_file.endswith("scripts/lib.sh") and any(token in {"codex", "queue", "approval", "agent"} for token in tokens):
        score += 5
    candidate_files.append((score, relative_file, lines))

candidate_files.sort(key=lambda item: (-item[0], item[1]))

sections: list[str] = []
for _, relative_file, lines in candidate_files[:4]:
    ranges = slice_ranges(lines, tokens, focus_tokens)
    snippet_lines: list[str] = []
    for start, end in ranges:
        if snippet_lines:
            snippet_lines.append("...")
        for line_no in range(start, end):
            snippet_lines.append(f"{line_no + 1:>4}: {lines[line_no]}")

    if not snippet_lines:
        continue

    sections.append(
        f"FILE {relative_file}\n"
        "```text\n"
        + "\n".join(snippet_lines[:80])
        + "\n```"
    )

if sections:
    print("\n\n".join(sections))
PY
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

shared_codex_home() {
  printf '%s\n' "${CODEX_SHARED_HOME:-$HOME/.codex}"
}

shared_codex_auth_file() {
  printf '%s/auth.json\n' "$(shared_codex_home)"
}

runtime_codex_auth_file() {
  printf '%s/auth.json\n' "$CODEX_RUNTIME_HOME"
}

sync_codex_runtime_auth() {
  local source_auth_file runtime_auth_file
  source_auth_file="$(shared_codex_auth_file)"
  runtime_auth_file="$(runtime_codex_auth_file)"

  [ -f "$source_auth_file" ] || return 1

  ensure_runtime_dirs
  if [ -f "$runtime_auth_file" ] && cmp -s "$source_auth_file" "$runtime_auth_file"; then
    chmod 600 "$runtime_auth_file" 2>/dev/null || true
    return 0
  fi

  cp "$source_auth_file" "$runtime_auth_file"
  chmod 600 "$runtime_auth_file"
  log_msg INFO auth "Synced Codex auth into runtime home"
}

codex_auth_failure_file() {
  printf '%s/codex-auth-failure.json\n' "$LOG_DIR"
}

read_codex_auth_failure_reason() {
  local failure_file="$1"
  [ -f "$failure_file" ] || return 1

  python3 - "$failure_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    payload = {}

reason = str(payload.get("reason") or "").strip()
if reason:
    print(reason)
PY
}

codex_auth_failure_cooldown_active() {
  local failure_file="$1"

  python3 - "$failure_file" "${CODEX_AUTH_FAILURE_COOLDOWN_SECONDS:-900}" <<'PY'
import os
import sys
import time

path = sys.argv[1]
try:
    cooldown_seconds = max(0, int(sys.argv[2] or "0"))
except ValueError:
    cooldown_seconds = 0

if cooldown_seconds <= 0 or not os.path.exists(path):
    print("0")
    raise SystemExit(0)

age_seconds = time.time() - os.path.getmtime(path)
print("1" if age_seconds < cooldown_seconds else "0")
PY
}

write_codex_auth_failure_state() {
  local failure_file="$1"
  local reason="$2"

  python3 - "$failure_file" "$reason" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, reason = sys.argv[1:]
payload = {
    "detected_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "reason": reason,
}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

extract_codex_auth_failure_reason() {
  local raw_log_file="$1"
  [ -f "$raw_log_file" ] || return 1

  python3 - "$raw_log_file" <<'PY'
import re
import sys

path = sys.argv[1]
patterns = (
    r"401 Unauthorized.*",
    r"Missing bearer or basic authentication in header.*",
    r"missing api key.*",
    r"authentication .* failed.*",
)

with open(path, "r", encoding="utf-8", errors="ignore") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        if not line:
            continue
        lower = line.lower()
        for pattern in patterns:
            if re.search(pattern, line, re.IGNORECASE):
                print(line)
                raise SystemExit(0)
        if "unauthorized" in lower and "auth" in lower:
            print(line)
            raise SystemExit(0)
raise SystemExit(1)
PY
}

codex_auth_reason_is_missing_credentials() {
  local reason="${1:-}"
  case "$reason" in
    *"Missing bearer or basic authentication in header"*|*"401 Unauthorized"*|*"Not logged in"*)
      return 0
      ;;
  esac
  return 1
}

recover_codex_runtime_auth_if_available() {
  local failure_file="$1"
  local reason="${2:-}"

  codex_auth_reason_is_missing_credentials "$reason" || return 1
  sync_codex_runtime_auth || return 1
  rm -f "$failure_file"
  return 0
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
    mark_provider_unavailable "codex" "codex CLI is not installed or not on PATH."
    log_msg WARN "$role" "codex CLI not available; using fallback logic"
    return 1
  fi

  ensure_runtime_dirs
  mkdir -p "$(dirname "$output_file")"
  local raw_log_file auth_failure_file auth_failure_reason
  raw_log_file="${output_file}.codex.log"
  auth_failure_file="$(codex_auth_failure_file)"

  if [ "$(codex_auth_failure_cooldown_active "$auth_failure_file")" = "1" ]; then
    auth_failure_reason="$(read_codex_auth_failure_reason "$auth_failure_file" || true)"
    if recover_codex_runtime_auth_if_available "$auth_failure_file" "$auth_failure_reason"; then
      log_msg INFO "$role" "Recovered Codex runtime auth from shared home; resuming live codex calls"
      auth_failure_reason=""
    fi
  fi

  if [ "$(codex_auth_failure_cooldown_active "$auth_failure_file")" = "1" ]; then
    auth_failure_reason="${auth_failure_reason:-$(read_codex_auth_failure_reason "$auth_failure_file" || true)}"
    mark_provider_unavailable "codex" "${auth_failure_reason:-Codex authentication is currently unavailable.}"
    log_msg WARN "$role" "Skipping codex exec because an authentication failure was detected recently${auth_failure_reason:+: $auth_failure_reason}"
    return 1
  fi

  sync_codex_runtime_auth >/dev/null 2>&1 || true
  rm -f "$auth_failure_file"

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

  auth_failure_reason="$(extract_codex_auth_failure_reason "$raw_log_file" || true)"
  if [ -n "$auth_failure_reason" ]; then
    write_codex_auth_failure_state "$auth_failure_file" "$auth_failure_reason"
    mark_provider_unavailable "codex" "$auth_failure_reason"
    log_msg WARN "$role" "Detected codex authentication failure; live codex calls will be skipped for ${CODEX_AUTH_FAILURE_COOLDOWN_SECONDS:-900}s"
  fi

  log_msg WARN "$role" "codex exec failed or produced no output; raw output saved to $(relative_path "$raw_log_file" "$ROOT_DIR")"
  return 1
}

run_claude_exec() {
  local role="$1"
  local project_dir="$2"
  local prompt="$3"
  local output_file="$4"

  if [ "${CLAUDE_DISABLE:-0}" = "1" ]; then
    log_msg WARN "$role" "CLAUDE_DISABLE=1 set; skipping Claude execution"
    return 1
  fi

  if ! command -v claude >/dev/null 2>&1; then
    mark_provider_unavailable "claude" "claude CLI is not installed or not on PATH."
    log_msg WARN "$role" "claude CLI not available; skipping Claude execution"
    return 1
  fi

  ensure_runtime_dirs
  mkdir -p "$(dirname "$output_file")"
  local raw_log_file schema auth_failure_reason
  raw_log_file="${output_file}.claude.log"
  schema="$(agent_json_schema)"

  log_msg INFO "$role" "Calling claude print mode in $(relative_path "$project_dir" "$ROOT_DIR")"
  : >"$raw_log_file"
  if claude -p \
    --output-format json \
    --permission-mode acceptEdits \
    --no-session-persistence \
    --add-dir "$project_dir" \
    --add-dir "$ROOT_DIR" \
    --json-schema "$schema" \
    "$prompt" >"$raw_log_file" 2>&1 && jq -e '.structured_output | type == "object"' "$raw_log_file" > /dev/null 2>&1; then
    jq -c '.structured_output' "$raw_log_file" >"$output_file"
    if [ -s "$raw_log_file" ]; then
      log_msg INFO "$role" "claude print completed successfully; raw output saved to $(relative_path "$raw_log_file" "$ROOT_DIR")"
    else
      rm -f "$raw_log_file"
      log_msg INFO "$role" "claude print completed successfully"
    fi
    return 0
  fi

  auth_failure_reason="$(extract_claude_auth_failure_reason "$raw_log_file" || true)"
  if [ -n "$auth_failure_reason" ]; then
    mark_provider_unavailable "claude" "$auth_failure_reason"
  fi

  log_msg WARN "$role" "claude print failed or produced no output; raw output saved to $(relative_path "$raw_log_file" "$ROOT_DIR")"
  return 1
}

run_agent_exec() {
  local role="$1"
  local project_dir="$2"
  local task="$3"
  local prompt="$4"
  local output_file="$5"
  local provider_info provider provider_reason provider_source project_name

  provider_exec_reset_state
  project_name="$(basename "$project_dir")"
  provider_info="$(resolve_task_provider_info "$project_name" "$task")"
  provider="$(printf '%s\n' "$provider_info" | sed -n '1p')"
  provider_reason="$(printf '%s\n' "$provider_info" | sed -n '2p')"
  provider_source="$(printf '%s\n' "$provider_info" | sed -n '3p')"
  provider="$(normalize_provider_name "$provider")"
  [ -n "$provider" ] || provider="codex"

  AGENT_EXEC_PROVIDER="$provider"
  AGENT_EXEC_PROVIDER_REASON="${provider_reason:-Selected provider for task execution.}"
  log_msg INFO "$role" "Selected provider=$provider for task dispatch (${provider_source:-default}): ${AGENT_EXEC_PROVIDER_REASON}"

  case "$provider" in
    claude) run_claude_exec "$role" "$project_dir" "$prompt" "$output_file" ;;
    *) run_codex_exec "$role" "$project_dir" "$prompt" "$output_file" ;;
  esac
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
  local provider="${8:-}"
  local lane="${9:-}"

  [ -n "$project_name" ] || return 0
  [ -n "$queue_task" ] || return 0
  [ -n "$next_status" ] || return 0

  ensure_runtime_dirs

  python3 - "$TASK_REGISTRY_FILE" "$project_name" "$queue_task" "$next_status" "$action" "$note" "$attempt" "$max_retries" "$provider" "$lane" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from typing import Any


path, project_name, queue_task, next_status, action, note, attempt, max_retries, provider, lane = sys.argv[1:]


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def task_execution_text(task: dict[str, Any]) -> str:
    return str(task.get("execution_task") or task.get("title") or "").strip()


def original_failed_root_id(task: dict[str, Any]) -> str:
    direct = str(task.get("original_failed_root_id") or "").strip()
    if direct:
        return direct

    for context_key in ("failure_context", "execution_context"):
        context = task.get(context_key)
        if not isinstance(context, dict):
            continue
        candidate = str(context.get("original_failed_root_id") or "").strip()
        if candidate:
            return candidate

    return ""


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
        "provider": str(provider or task.get("execution_provider") or execution.get("provider") or "").strip(),
        "lane": str(lane or execution.get("lane") or "").strip(),
        "result": "SUCCESS" if next_status == "completed" else ("FAILURE" if next_status in {"approved", "failed"} else "RUNNING"),
        "updated_at": transition_at,
        "will_retry": next_status == "approved",
    }
)

lease_ttl = 310
if next_status == "running":
    lane_label = str(lane or execution.get("lane") or "default").strip()
    lease_id = f"{lane_label}-{transition_at}"
    execution["lease_id"] = lease_id
    execution["lease_ttl_seconds"] = lease_ttl
    lease_dt = datetime.now(timezone.utc)
    execution["lease_expires_at"] = (lease_dt + timedelta(seconds=lease_ttl)).strftime("%Y-%m-%dT%H:%M:%SZ")
    execution["lease_state"] = "claimed"
    execution["lease_claimed_at"] = transition_at
elif next_status in {"approved", "completed", "failed"}:
    execution["lease_state"] = "released"
    execution["lease_released_at"] = transition_at

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
        "lane": str(lane or "").strip(),
    }
)
task["history"] = history[-20:]

tasks[selected_index] = task
payload["tasks"] = tasks
write_payload(path, payload)
PY
}

claim_task_lease() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local lane="${3:-}"
  local lease_ttl="${4:-310}"

  [ -n "$project_name" ] || return 1
  [ -n "$queue_task" ] || return 1
  [ -n "$lane" ] || return 1

  ensure_runtime_dirs

  python3 - "$TASK_REGISTRY_FILE" "$project_name" "$queue_task" "$lane" "$lease_ttl" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from typing import Any

path, project_name, queue_task, lane, lease_ttl_str = sys.argv[1:]
lease_ttl = int(lease_ttl_str or 310)


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def task_execution_text(task: dict[str, Any]) -> str:
    return str(task.get("execution_task") or task.get("title") or "").strip()


def original_failed_root_id(task: dict[str, Any]) -> str:
    direct = str(task.get("original_failed_root_id") or "").strip()
    if direct:
        return direct

    for context_key in ("failure_context", "execution_context"):
        context = task.get(context_key)
        if not isinstance(context, dict):
            continue
        candidate = str(context.get("original_failed_root_id") or "").strip()
        if candidate:
            return candidate

    return ""


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
now = datetime.now(timezone.utc)
now_str = now.strftime("%Y-%m-%dT%H:%M:%SZ")

selected_index: int | None = None
for index, task in enumerate(tasks):
    if not isinstance(task, dict):
        continue
    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if task_project != project_key:
        continue
    if normalize_task(task_execution_text(task)) != task_key:
        continue
    current_status = str(task.get("status") or "").strip().lower()
    if current_status not in {"approved", "running"}:
        continue
    selected_index = index
    break

if selected_index is None:
    print("claim_task_lease: task not found", file=sys.stderr)
    raise SystemExit(1)

task = dict(tasks[selected_index])
execution = task.get("execution")
if not isinstance(execution, dict):
    execution = {}

# Check for an existing active lease held by a different lane
existing_state = str(execution.get("lease_state") or "").strip().lower()
existing_lane = str(execution.get("lane") or "").strip()
existing_expires = str(execution.get("lease_expires_at") or "").strip()

if existing_state == "claimed" and existing_lane and existing_lane != lane:
    # Check if the existing lease has expired
    if existing_expires:
        try:
            expires_dt = datetime.strptime(existing_expires, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            if expires_dt > now:
                print(f"claim_task_lease: active lease held by lane {existing_lane} until {existing_expires}", file=sys.stderr)
                raise SystemExit(1)
        except ValueError:
            pass

# Write the lease
lease_id = f"{lane}-{now_str}"
expires_at = (now + timedelta(seconds=lease_ttl)).strftime("%Y-%m-%dT%H:%M:%SZ")

execution["lease_id"] = lease_id
execution["lease_state"] = "claimed"
execution["lease_ttl_seconds"] = lease_ttl
execution["lease_expires_at"] = expires_at
execution["lease_claimed_at"] = now_str
execution["lane"] = lane
execution["updated_at"] = now_str

task["execution"] = execution
task["updated_at"] = now_str
tasks[selected_index] = task
payload["tasks"] = tasks
write_payload(path, payload)
print(json.dumps({"lease_id": lease_id, "lane": lane, "expires_at": expires_at}))
PY
}

persist_task_run_context() {
  local project_name="${1:-}"
  local queue_task="${2:-}"
  local result="${3:-UNKNOWN}"
  local run_id="${4:-}"
  local attempts="${5:-0}"
  local score="${6:-0}"
  local duration="${7:-0}"
  local step_count="${8:-0}"
  local completed_steps="${9:-0}"
  local failed_step_index="${10:-0}"
  local failed_step_text="${11:-}"
  local plan_file="${12:-}"
  local provider="${13:-}"
  local failure_timestamp="${14:-}"

  [ -n "$project_name" ] || return 0
  [ -n "$queue_task" ] || return 0

  ensure_runtime_dirs

  python3 - "$TASK_REGISTRY_FILE" "$project_name" "$queue_task" "$result" "$run_id" "$attempts" "$score" "$duration" "$step_count" "$completed_steps" "$failed_step_index" "$failed_step_text" "$plan_file" "$provider" "$failure_timestamp" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from typing import Any


(
    path,
    project_name,
    queue_task,
    result,
    run_id,
    attempts,
    score,
    duration,
    step_count,
    completed_steps,
    failed_step_index,
    failed_step_text,
    plan_file,
    provider,
    failure_timestamp,
) = sys.argv[1:]


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_task(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9_-]+", "-", str(value or "").strip().lower()))


def task_execution_text(task: dict[str, Any]) -> str:
    return str(task.get("execution_task") or task.get("title") or "").strip()


def original_failed_root_id(task: dict[str, Any]) -> str:
    direct = str(task.get("original_failed_root_id") or "").strip()
    if direct:
        return direct

    for context_key in ("failure_context", "execution_context"):
        context = task.get(context_key)
        if not isinstance(context, dict):
            continue
        candidate = str(context.get("original_failed_root_id") or "").strip()
        if candidate:
            return candidate

    return ""


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


def read_plan_steps(file_path: str) -> list[str]:
    if not file_path or not os.path.exists(file_path):
        return []
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        return []
    steps = (((payload or {}).get("data") or {}).get("steps") or [])
    if not isinstance(steps, list):
        return []
    return [str(step).strip() for step in steps if str(step).strip()]


payload = read_payload(path)
tasks = payload.get("tasks")
if not isinstance(tasks, list):
    tasks = []
    payload["tasks"] = tasks

project_key = normalize_project(project_name)
task_key = normalize_task(queue_task)

selected_index: int | None = None
selected_rank: tuple[str, str, int] | None = None
for index, task in enumerate(tasks):
    if not isinstance(task, dict):
        continue
    task_project = normalize_project(task.get("project") or task.get("target_project") or "codex-agent-system")
    if task_project != project_key:
        continue
    if normalize_task(task_execution_text(task)) != task_key:
        continue
    rank = (
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
plan_steps = read_plan_steps(plan_file)
failed_root_id = original_failed_root_id(task)

execution_context = {
    "run_id": str(run_id or "").strip(),
    "provider": str(provider or task.get("execution_provider") or "").strip(),
    "result": str(result or "").strip(),
    "attempts": int(attempts or 0),
    "score": int(score or 0),
    "duration_seconds": int(duration or 0),
    "step_count": int(step_count or 0),
    "completed_steps": int(completed_steps or 0),
    "failed_step_index": int(failed_step_index or 0),
    "failed_step": str(failed_step_text or "").strip(),
    "plan_steps": plan_steps,
    "updated_at": transition_at,
    "original_failed_root_id": failed_root_id,
}
task["execution_context"] = execution_context
if failed_root_id:
    task["original_failed_root_id"] = failed_root_id

if str(result or "").strip().upper() == "SUCCESS":
    task.pop("failure_context", None)
else:
    failure_at = str(failure_timestamp or "").strip() or transition_at
    task["failure_context"] = {
        "run_id": str(run_id or "").strip(),
        "provider": str(provider or task.get("execution_provider") or "").strip(),
        "result": str(result or "").strip(),
        "attempts": int(attempts or 0),
        "failed_step_index": int(failed_step_index or 0),
        "failed_step": str(failed_step_text or "").strip(),
        "timestamp": failure_at,
        "updated_at": transition_at,
        "original_failed_root_id": failed_root_id,
    }

task["updated_at"] = transition_at
tasks[selected_index] = task
payload["tasks"] = tasks
write_payload(path, payload)
PY
}
