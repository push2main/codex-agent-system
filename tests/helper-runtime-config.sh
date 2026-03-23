#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

RUNTIME_FILE="$TMP_DIR/agentctl-runtime.env"
RESTART_STATE_FILE="${RUNTIME_FILE%.env}.restart-state.env"
MINI_ROOT="$TMP_DIR/minimal-repo"
MINI_RUNTIME_FILE="$MINI_ROOT/codex-logs/agentctl-runtime.env"
MINI_RESTART_STATE_FILE="${MINI_RUNTIME_FILE%.env}.restart-state.env"

(
  cd "$ROOT_DIR"
  export AGENTCTL_RUNTIME_FILE="$RUNTIME_FILE"
  export QUEUE_POLL_SECONDS=1
  export QUEUE_WORKERS=3
  source "$ROOT_DIR/scripts/lib.sh"

  persist_helper_runtime_state "false" "marker-one" "" "1" "3"
  [ "$(read_helper_runtime_state_field "queue_poll_seconds")" = "1" ]
  [ "$(read_helper_runtime_state_field "queue_workers")" = "3" ]

  export QUEUE_POLL_SECONDS=9
  export QUEUE_WORKERS=1
  update_agentctl_runtime_helper_fingerprint

  [ "$(read_helper_runtime_state_field "queue_poll_seconds")" = "1" ]
  [ "$(read_helper_runtime_state_field "queue_workers")" = "3" ]
  [ "$(read_helper_runtime_state_field "restart_needed")" = "false" ]
  [ -f "$RESTART_STATE_FILE" ]

  persist_queue_runtime_config "1" "4"
  [ "$(read_helper_runtime_state_field "queue_poll_seconds")" = "1" ]
  [ "$(read_helper_runtime_state_field "queue_workers")" = "4" ]
)

mkdir -p "$MINI_ROOT"
cp -R "$ROOT_DIR/scripts" "$MINI_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$MINI_ROOT/agents"
mkdir -p "$MINI_ROOT/codex-logs"

(
  cd "$MINI_ROOT"
  export AGENTCTL_RUNTIME_FILE="$MINI_RUNTIME_FILE"
  source "$MINI_ROOT/scripts/lib.sh"

  marker="$(helper_scripts_marker)"
  [ -n "$marker" ]

  update_agentctl_runtime_helper_fingerprint
  [ -f "$MINI_RESTART_STATE_FILE" ]
  [ "$(read_helper_runtime_state_field "queue_helper_fingerprint")" = "$marker" ]
)

echo "helper runtime config test passed"
