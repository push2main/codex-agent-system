#!/usr/bin/env bash
# hooks.sh — Lifecycle event hooks for the codex-agent-system
#
# Hooks are shell scripts placed in .codex/hooks/<event_name>/*.sh
# They receive event data as JSON on stdin and can:
#   - Exit 0: allow the action to proceed
#   - Exit 1: log a warning but continue
#   - Exit 2: block the action (only for pre_* events)
#
# Hook execution order is alphabetical by filename within each event directory.
# This ensures deterministic execution order (AGENTS.md compliance).

set -Eeuo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

HOOKS_DIR="${HOOKS_DIR:-$ROOT_DIR/.codex/hooks}"

# fire_hook <event_name> [json_data]
# Fires all hooks for the given event in alphabetical order.
# Returns 0 if all hooks pass, 2 if any hook blocks (exit 2).
fire_hook() {
  local event_name="${1:-}"
  local json_data="${2:-'{}'}"
  local hook_dir="$HOOKS_DIR/$event_name"

  [ -d "$hook_dir" ] || return 0

  local hook_input
  hook_input="$(jq -cn \
    --arg event "$event_name" \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson data "$json_data" \
    '{event:$event, timestamp:$timestamp, data:$data}' 2>/dev/null || printf '{"event":"%s"}' "$event_name")"

  # Process hooks in alphabetical order for determinism
  local hook_script
  for hook_script in "$hook_dir"/*.sh; do
    [ -f "$hook_script" ] || continue

    local rc=0
    printf '%s' "$hook_input" | bash "$hook_script" 2>&1 || rc=$?

    case "$rc" in
      0)
        # Hook passed, continue
        ;;
      2)
        # Hook blocked the action
        if command -v log_msg >/dev/null 2>&1; then
          log_msg WARN hooks "Hook $(basename "$hook_script") blocked event $event_name"
        fi
        return 2
        ;;
      *)
        # Hook failed but doesn't block
        if command -v log_msg >/dev/null 2>&1; then
          log_msg WARN hooks "Hook $(basename "$hook_script") failed for event $event_name (rc=$rc)"
        fi
        ;;
    esac
  done

  return 0
}

# list_hooks [event_name]
# Lists all registered hooks, optionally filtered by event.
list_hooks() {
  local event_filter="${1:-}"

  if [ -n "$event_filter" ]; then
    local hook_dir="$HOOKS_DIR/$event_filter"
    if [ -d "$hook_dir" ]; then
      for hook_script in "$hook_dir"/*.sh; do
        [ -f "$hook_script" ] || continue
        printf '%s/%s\n' "$event_filter" "$(basename "$hook_script")"
      done
    fi
  else
    for event_dir in "$HOOKS_DIR"/*/; do
      [ -d "$event_dir" ] || continue
      local event_name
      event_name="$(basename "$event_dir")"
      for hook_script in "$event_dir"/*.sh; do
        [ -f "$hook_script" ] || continue
        printf '%s/%s\n' "$event_name" "$(basename "$hook_script")"
      done
    done
  fi
}
