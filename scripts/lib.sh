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
STATUS_FILE="$ROOT_DIR/status.txt"
QUEUE_RETRY_DIR="$LOG_DIR/queue-retries"
RULES_FILE="$LEARNING_DIR/rules.md"
RULES_CANDIDATE_FILE="$LEARNING_DIR/rules-candidate.md"
TASK_LOG="$MEMORY_DIR/tasks.log"
DECISIONS_FILE="$MEMORY_DIR/decisions.md"
CONTEXT_FILE="$MEMORY_DIR/context.md"
QUEUE_LIMIT="${QUEUE_LIMIT:-20}"
TASK_TIMEOUT_SECONDS="${TASK_TIMEOUT_SECONDS:-300}"
MAX_AGENT_RETRIES="${MAX_AGENT_RETRIES:-2}"

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ensure_runtime_dirs() {
  mkdir -p "$LOG_DIR" "$RUNS_DIR" "$MEMORY_DIR" "$LEARNING_DIR" "$QUEUE_DIR" "$PROJECTS_DIR" "$DASHBOARD_DIR" "$QUEUE_RETRY_DIR"
  [ -f "$SYSTEM_LOG" ] || : >"$SYSTEM_LOG"
  [ -f "$TASK_LOG" ] || : >"$TASK_LOG"
  [ -f "$DECISIONS_FILE" ] || printf '# Decisions\n\n' >"$DECISIONS_FILE"
  [ -f "$CONTEXT_FILE" ] || printf '# Context\n\n' >"$CONTEXT_FILE"
  [ -f "$RULES_FILE" ] || printf '# Learned Rules\n\n' >"$RULES_FILE"
  [ -f "$RULES_CANDIDATE_FILE" ] || printf '# Candidate Rules\n\n' >"$RULES_CANDIDATE_FILE"
  if [ ! -f "$STATUS_FILE" ]; then
    cat >"$STATUS_FILE" <<EOF
state=IDLE
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

normalize_task() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
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
    (has("data"))
  ' "$file_path" >/dev/null 2>&1
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
  commit_message="codex: $(printf '%s' "$task" | tr '\n' ' ' | cut -c1-72)"
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

  local -a cmd
  cmd=(codex -a never)
  if [ -n "${CODEX_MODEL:-}" ]; then
    cmd+=(-m "$CODEX_MODEL")
  fi
  cmd+=(exec --skip-git-repo-check --ephemeral --color never -C "$project_dir" --add-dir "$ROOT_DIR" -s workspace-write -o "$output_file" "$prompt")

  log_msg INFO "$role" "Calling codex exec in $(relative_path "$project_dir" "$ROOT_DIR")"
  if "${cmd[@]}" >>"$SYSTEM_LOG" 2>&1 && [ -s "$output_file" ]; then
    log_msg INFO "$role" "codex exec completed successfully"
    return 0
  fi

  log_msg WARN "$role" "codex exec failed or produced no output"
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
