#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

agent_context="$(build_prompt_source_context \
  "Neben codex soll auch claude Tasks übernehmen" \
  "Inspect the existing planner, task-dispatch, and agent-selection entrypoints and identify the single deterministic place where codex is hardcoded today.")"

printf '%s' "$agent_context" | grep -q 'FILE scripts/lib.sh'
printf '%s' "$agent_context" | grep -q 'FILE agents/orchestrator.sh'
printf '%s' "$agent_context" | grep -q 'run_codex_exec'

ui_context="$(build_prompt_source_context \
  "Im UI muss ich aktuell Zuviel scrollen" \
  "Inspect the board route and the component that causes the most vertical scrolling.")"

printf '%s' "$ui_context" | grep -q 'FILE codex-dashboard/index.html'
printf '%s' "$ui_context" | grep -q 'FILE codex-dashboard/server.js'

echo "prompt source context test passed"
