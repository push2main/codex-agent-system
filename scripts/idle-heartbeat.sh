#!/usr/bin/env bash
# idle-heartbeat.sh — Periodic health check during idle periods
#
# Designed to be invoked by launchd/cron every 6 hours (or by scheduled tasks).
# When the pipeline is idle and healthy, triggers memory-sync.sh (which now
# contains the growth-mode trigger for self-improve.sh).
#
# This closes the structural gap where:
# - strategy-loop.sh only runs when the pipeline is active
# - memory-sync.sh only runs when invoked by strategy-loop.sh or queue-worker.sh
# - During idle periods, no process invokes either script
#
# Usage:
#   bash scripts/idle-heartbeat.sh
#
# Safe to run frequently — no-ops if pipeline is active.

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METRICS_FILE="$ROOT_DIR/codex-learning/metrics.json"
LOG_FILE="$ROOT_DIR/codex-logs/idle-heartbeat.log"

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

if [ ! -f "$METRICS_FILE" ]; then
  log "SKIP: metrics.json not found"
  exit 0
fi

pipeline_stale="$(jq -r '.pipeline_stale // false' "$METRICS_FILE" 2>/dev/null || printf 'false')"
running="$(jq -r '.running_tasks // 0' "$METRICS_FILE" 2>/dev/null || printf '0')"
queued="$(jq -r '.queued_tasks // 0' "$METRICS_FILE" 2>/dev/null || printf '0')"

if [ "$pipeline_stale" != "true" ] || [ "$running" != "0" ] || [ "$queued" != "0" ]; then
  log "SKIP: pipeline active (stale=$pipeline_stale running=$running queued=$queued)"
  exit 0
fi

log "Pipeline idle — running memory-sync.sh and validate-metrics.sh"

# 1. Validate metrics (prevent drift during idle)
if [ -x "$ROOT_DIR/scripts/validate-metrics.sh" ]; then
  bash "$ROOT_DIR/scripts/validate-metrics.sh" >> "$LOG_FILE" 2>&1 || true
fi

# 2. Run memory-sync (includes growth-mode trigger since v22)
if [ -x "$ROOT_DIR/scripts/memory-sync.sh" ]; then
  bash "$ROOT_DIR/scripts/memory-sync.sh" sync >> "$LOG_FILE" 2>&1 || true
fi

log "Heartbeat complete"
