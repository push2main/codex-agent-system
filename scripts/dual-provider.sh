#!/usr/bin/env bash
# dual-provider.sh — Dual-operation adapter for Claude Code and Codex CLI
#
# This module provides unified execution through either Claude Code or Codex CLI,
# selecting the optimal provider based on task characteristics and historical performance.
#
# Usage: source this file, then call execute_with_provider()

set -Eeuo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Provider availability checks
CLAUDE_CODE_AVAILABLE=0
CODEX_CLI_AVAILABLE=0

check_provider_availability() {
  if command -v claude >/dev/null 2>&1; then
    CLAUDE_CODE_AVAILABLE=1
    log_msg DEBUG dual-provider "Claude Code CLI available"
  fi
  if command -v codex >/dev/null 2>&1; then
    CODEX_CLI_AVAILABLE=1
    log_msg DEBUG dual-provider "Codex CLI available"
  fi
}

# Optimal provider selection based on task characteristics + historical data
# Returns: "claude-code" or "codex-cli" or "codex" (fallback)
select_optimal_provider() {
  local task="${1:-}"
  local step_text="${2:-}"
  local category="${3:-general}"
  local base_provider="${4:-codex}"

  # If only one provider is available, use that
  if [ "$CLAUDE_CODE_AVAILABLE" -eq 1 ] && [ "$CODEX_CLI_AVAILABLE" -eq 0 ]; then
    printf 'claude-code'
    return 0
  fi
  if [ "$CODEX_CLI_AVAILABLE" -eq 1 ] && [ "$CLAUDE_CODE_AVAILABLE" -eq 0 ]; then
    printf 'codex-cli'
    return 0
  fi
  if [ "$CLAUDE_CODE_AVAILABLE" -eq 0 ] && [ "$CODEX_CLI_AVAILABLE" -eq 0 ]; then
    printf '%s' "$base_provider"
    return 0
  fi

  # Both available — select based on task characteristics
  local task_lower
  task_lower="$(printf '%s' "$task $step_text" | tr '[:upper:]' '[:lower:]')"

  # Claude Code excels at:
  # - UI/frontend work (proven by provider-stats: 14% vs 9%)
  # - Multi-file refactors (better context management)
  # - Complex reasoning (Opus 4.6 available)
  # - Architecture decisions
  # - Large context operations (1M token window)
  if printf '%s' "$task_lower" | grep -qE '(dashboard|ui|mobile|css|html|frontend|render|display|button|layout|style|responsive)'; then
    printf 'claude-code'
    return 0
  fi
  if printf '%s' "$task_lower" | grep -qE '(refactor|redesign|architect|restructure|migrate|overhaul)'; then
    printf 'claude-code'
    return 0
  fi
  if printf '%s' "$task_lower" | grep -qE '(multi.file|across.files|system.wide|cross.cutting)'; then
    printf 'claude-code'
    return 0
  fi

  # Codex CLI excels at:
  # - Sandboxed execution (kernel-level isolation)
  # - Simple file edits (apply-patch style)
  # - Testing and verification (sandboxed test runs)
  # - Infrastructure tasks (proven higher success rate)
  # - Code quality (lint, format, simple fixes)
  if printf '%s' "$task_lower" | grep -qE '(test|verify|validate|check|lint|format|fix typo|simple|quick)'; then
    printf 'codex-cli'
    return 0
  fi
  if printf '%s' "$task_lower" | grep -qE '(infra|config|deploy|docker|ci|cd|pipeline|script)'; then
    printf 'codex-cli'
    return 0
  fi

  # Fall back to category-based routing from provider-routing.json
  case "$category" in
    ui) printf 'claude-code' ;;
    *) printf 'codex-cli' ;;
  esac
}

# Execute a prompt with Claude Code CLI
# Returns: exit code (0=success)
execute_with_claude_code() {
  local project_dir="${1:-}"
  local prompt="${2:-}"
  local output_file="${3:-/dev/null}"
  local timeout="${4:-300}"

  log_msg INFO dual-provider "Executing with Claude Code: ${prompt:0:80}..."

  local claude_args=(
    --print
    --output-format json
    --max-turns 20
  )

  # Add project directory context
  if [ -n "$project_dir" ] && [ -d "$project_dir" ]; then
    claude_args+=(--directory "$project_dir")
  fi

  local result
  if result="$(timeout "$timeout" claude "${claude_args[@]}" "$prompt" 2>&1)"; then
    printf '%s' "$result" > "$output_file"
    log_msg INFO dual-provider "Claude Code execution completed successfully"
    return 0
  else
    local rc=$?
    log_msg WARN dual-provider "Claude Code execution failed with rc=$rc"
    printf '{"status":"fail","message":"Claude Code execution failed (rc=%s)","data":{}}' "$rc" > "$output_file"
    return "$rc"
  fi
}

# Execute a prompt with Codex CLI
# Returns: exit code (0=success)
execute_with_codex_cli() {
  local project_dir="${1:-}"
  local prompt="${2:-}"
  local output_file="${3:-/dev/null}"
  local timeout="${4:-300}"

  log_msg INFO dual-provider "Executing with Codex CLI: ${prompt:0:80}..."

  local codex_args=(
    exec
    --full-auto
    --quiet
  )

  # Add project directory
  if [ -n "$project_dir" ] && [ -d "$project_dir" ]; then
    codex_args+=(--cd "$project_dir")
  fi

  local result
  if result="$(timeout "$timeout" codex "${codex_args[@]}" "$prompt" 2>&1)"; then
    printf '%s' "$result" > "$output_file"
    log_msg INFO dual-provider "Codex CLI execution completed successfully"
    return 0
  else
    local rc=$?
    log_msg WARN dual-provider "Codex CLI execution failed with rc=$rc"
    printf '{"status":"fail","message":"Codex CLI execution failed (rc=%s)","data":{}}' "$rc" > "$output_file"
    return "$rc"
  fi
}

# Unified execution entry point
# Selects the best provider and executes
execute_with_provider() {
  local project_dir="${1:-}"
  local prompt="${2:-}"
  local output_file="${3:-/dev/null}"
  local timeout="${4:-300}"
  local category="${5:-general}"
  local forced_provider="${6:-}"

  check_provider_availability

  local provider
  if [ -n "$forced_provider" ]; then
    provider="$forced_provider"
  else
    provider="$(select_optimal_provider "$prompt" "" "$category")"
  fi

  log_msg INFO dual-provider "Selected provider: $provider for category=$category"

  case "$provider" in
    "claude-code"|"claude")
      if [ "$CLAUDE_CODE_AVAILABLE" -eq 1 ]; then
        execute_with_claude_code "$project_dir" "$prompt" "$output_file" "$timeout"
        return $?
      fi
      log_msg WARN dual-provider "Claude Code not available, falling back to codex"
      if [ "$CODEX_CLI_AVAILABLE" -eq 1 ]; then
        execute_with_codex_cli "$project_dir" "$prompt" "$output_file" "$timeout"
        return $?
      fi
      log_msg ERROR dual-provider "No provider available for execution"
      return 1
      ;;
    "codex-cli"|"codex")
      if [ "$CODEX_CLI_AVAILABLE" -eq 1 ]; then
        execute_with_codex_cli "$project_dir" "$prompt" "$output_file" "$timeout"
        return $?
      fi
      log_msg ERROR dual-provider "No provider available for execution"
      return 1
      ;;
    *)
      log_msg WARN dual-provider "Unknown provider '$provider', using codex"
      execute_with_codex_cli "$project_dir" "$prompt" "$output_file" "$timeout"
      return $?
      ;;
  esac
}

# Failover execution: try primary, fall back to secondary
execute_with_failover() {
  local project_dir="${1:-}"
  local prompt="${2:-}"
  local output_file="${3:-/dev/null}"
  local timeout="${4:-300}"
  local category="${5:-general}"

  check_provider_availability

  local primary
  primary="$(select_optimal_provider "$prompt" "" "$category")"

  log_msg INFO dual-provider "Failover execution: primary=$primary"

  if execute_with_provider "$project_dir" "$prompt" "$output_file" "$timeout" "$category" "$primary"; then
    return 0
  fi

  # Primary failed — try the other provider
  local secondary
  case "$primary" in
    "claude-code"|"claude") secondary="codex-cli" ;;
    *) secondary="claude-code" ;;
  esac

  log_msg WARN dual-provider "Primary provider $primary failed, trying $secondary"

  if execute_with_provider "$project_dir" "$prompt" "$output_file" "$timeout" "$category" "$secondary"; then
    log_msg INFO dual-provider "Failover to $secondary succeeded"
    return 0
  fi

  log_msg ERROR dual-provider "Both providers failed for task"
  return 1
}

# Provider performance feedback — updates routing stats
record_provider_result() {
  local provider="${1:-codex}"
  local category="${2:-general}"
  local success="${3:-0}"
  local duration="${4:-0}"
  local step_attempts="${5:-1}"

  log_msg DEBUG dual-provider "Recording result: provider=$provider category=$category success=$success duration=${duration}s attempts=$step_attempts"

  # The actual stats update is handled by compute_provider_stats() in lib.sh
  # This function provides the hook point for additional dual-provider analytics

  local analytics_file="$ROOT_DIR/codex-learning/dual-provider-analytics.jsonl"
  printf '{"timestamp":"%s","provider":"%s","category":"%s","success":%s,"duration":%s,"step_attempts":%s}\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$provider" "$category" "$success" "$duration" "$step_attempts" \
    >> "$analytics_file" 2>/dev/null || true
}
