#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPT_FILE="$ROOT_DIR/prompts/push2main-codex-agent-system.md"
BOOTSTRAP_FILE="$ROOT_DIR/prompts/push2main-codex-agent-system.bootstrap.txt"

grep -F 'MUST run `AUTOMATION_CONTEXT_AUTO_REFRESH_SELF_IMPROVE=1 bash /Users/benediktpoller/code/codex-agent-system/scripts/prepare-automation-context.sh codex-agent-system 8` before selecting the next improvement and consume the returned JSON' "$PROMPT_FILE" >/dev/null
grep -F 'MUST inspect `data.self_improve_artifact_refresh` from that JSON and preserve any non-`not_needed` status in the run summary when it influenced decision input freshness' "$PROMPT_FILE" >/dev/null
grep -F 'MUST inspect `data.self_improve_artifact` from that JSON before selecting the next improvement' "$PROMPT_FILE" >/dev/null
grep -F 'If `data.self_improve_artifact.status == "current"`, use the latest `codex-learning/self-improve-run.json` ranking as existing decision evidence instead of ignoring it' "$PROMPT_FILE" >/dev/null
grep -F 'If `data.self_improve_artifact.status != "current"` after the wrapper run, treat the ranking as stale or missing decision input and let that influence the next improvement choice and final run summary' "$PROMPT_FILE" >/dev/null

grep -F 'Inspect `data.self_improve_artifact_refresh` from the same JSON and preserve any non-`not_needed` status when it changed decision-input freshness.' "$BOOTSTRAP_FILE" >/dev/null
grep -F 'Inspect `data.self_improve_artifact` from the same JSON before selecting the next improvement.' "$BOOTSTRAP_FILE" >/dev/null
grep -F 'If `data.self_improve_artifact.status == "current"`, treat the latest `codex-learning/self-improve-run.json` ranking as existing decision evidence instead of ignoring it.' "$BOOTSTRAP_FILE" >/dev/null
grep -F 'If `data.self_improve_artifact.status != "current"` after the wrapper run, treat the ranking as stale or missing decision input and let that influence the next improvement choice and run summary.' "$BOOTSTRAP_FILE" >/dev/null

echo "prompt self-improve artifact consumption test passed"
