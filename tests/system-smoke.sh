#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_DIR="$TMP_DIR/project"
RUN_DIR="$TMP_DIR/run"
PLAN_FILE="$TMP_DIR/plan.json"
STEP_FILE="$TMP_DIR/step.json"
MEMORY_FILE="$TMP_DIR/memory.txt"
CODER_FILE="$TMP_DIR/coder.json"
REVIEWER_FILE="$TMP_DIR/reviewer.json"
EVALUATOR_FILE="$TMP_DIR/evaluator.json"
LEARNER_FILE="$TMP_DIR/learner.json"
SAFETY_FILE="$TMP_DIR/safety.json"
PROMPT_RULES_FILE="$TMP_DIR/prompt-rules.md"
RULES_FILE="$TMP_DIR/rules.md"

mkdir -p "$PROJECT_DIR" "$RUN_DIR"
printf '# Context\n\n- deterministic smoke test\n' >"$MEMORY_FILE"

bash -n "$ROOT_DIR"/agents/*.sh "$ROOT_DIR"/scripts/*.sh
node --check "$ROOT_DIR/codex-dashboard/server.js"

CODEX_DISABLE=1 bash "$ROOT_DIR/agents/planner.sh" \
  "$PROJECT_DIR" \
  "create hello world script in shell" \
  "$PLAN_FILE" \
  "$MEMORY_FILE" \
  >"$TMP_DIR/planner.stdout"

jq -e '
  .status == "success" and
  (.message | type == "string") and
  (.data | type == "object") and
  (.data.steps | type == "array") and
  (.data.steps | length) >= 2
' "$PLAN_FILE" >/dev/null

jq -cn \
  --argjson index 2 \
  --arg text "$(jq -r '.data.steps[1]' "$PLAN_FILE")" \
  '{index:$index,text:$text}' >"$STEP_FILE"

CODEX_DISABLE=1 bash "$ROOT_DIR/agents/coder.sh" \
  "$PROJECT_DIR" \
  "create hello world script in shell" \
  "$STEP_FILE" \
  "$PLAN_FILE" \
  "$MEMORY_FILE" \
  "" \
  "$CODER_FILE" \
  >"$TMP_DIR/coder.stdout"

jq -e '
  .status == "success" and
  (.data | type == "object") and
  (.data.changed == true) and
  (.data.files | type == "array")
' "$CODER_FILE" >/dev/null

CODEX_DISABLE=1 bash "$ROOT_DIR/agents/reviewer.sh" \
  "$PROJECT_DIR" \
  "create hello world script in shell" \
  "$STEP_FILE" \
  "$PLAN_FILE" \
  "$CODER_FILE" \
  "$REVIEWER_FILE" \
  >"$TMP_DIR/reviewer.stdout"

jq -e '
  .status == "approved" and
  (.data | type == "object") and
  (.data.findings | type == "array")
' "$REVIEWER_FILE" >/dev/null

CODEX_DISABLE=1 bash "$ROOT_DIR/agents/evaluator.sh" \
  "$PROJECT_DIR" \
  "create hello world script in shell" \
  "$STEP_FILE" \
  "$PLAN_FILE" \
  "$REVIEWER_FILE" \
  "$EVALUATOR_FILE" \
  >"$TMP_DIR/evaluator.stdout"

jq -e '
  .status == "success" and
  (.data | type == "object") and
  (.data.score | type == "number")
' "$EVALUATOR_FILE" >/dev/null

CODEX_DISABLE=1 bash "$ROOT_DIR/agents/learner.sh" \
  "$PROJECT_DIR" \
  "create hello world script in shell" \
  "SUCCESS" \
  "$RUN_DIR" \
  "$PROMPT_RULES_FILE" \
  "$LEARNER_FILE" \
  >"$TMP_DIR/learner.stdout"

jq -e '
  .status == "success" and
  (.data | type == "object") and
  (.data.rules | type == "array") and
  (.data.rules | length) >= 1
' "$LEARNER_FILE" >/dev/null
grep -q '^- ' "$PROMPT_RULES_FILE"

CODEX_DISABLE=1 bash "$ROOT_DIR/agents/safety.sh" \
  "$PROMPT_RULES_FILE" \
  "$RULES_FILE" \
  "$SAFETY_FILE" \
  >"$TMP_DIR/safety.stdout"

jq -e '
  .status == "success" and
  (.data | type == "object") and
  (.data.rules | type == "array") and
  (.data.rules | length) >= 1
' "$SAFETY_FILE" >/dev/null
grep -q '^- ' "$RULES_FILE"

echo "smoke test passed"
