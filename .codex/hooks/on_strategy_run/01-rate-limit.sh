#!/usr/bin/env bash
# Strategy rate limiter: prevents strategy from running more than once per 5 minutes
# Exit 2 = block the strategy run

set -Eeuo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
LAST_RUN_FILE="$ROOT_DIR/codex-logs/strategy-last-hook-run"

if [ -f "$LAST_RUN_FILE" ]; then
  last_ts="$(cat "$LAST_RUN_FILE" 2>/dev/null || printf '0')"
  now_ts="$(date +%s)"
  elapsed=$((now_ts - last_ts))
  if [ "$elapsed" -lt 300 ]; then
    printf '[hook:on_strategy_run] Rate limited — %ss since last run (min 300s)\n' "$elapsed"
    exit 2
  fi
fi

date +%s > "$LAST_RUN_FILE"
exit 0
