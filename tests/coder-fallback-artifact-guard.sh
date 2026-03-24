#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/fallback-guard"
PLAN_FILE="$TMP_DIR/plan.json"
STEP_FILE="$TMP_DIR/step.json"
MEMORY_FILE="$TMP_DIR/memory.txt"
OUTPUT_FILE="$TMP_DIR/coder.json"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects" \
  "$PROJECT_DIR"

cat >"$PLAN_FILE" <<'JSON'
{"status":"success","message":"ok","data":{"steps":["Add the Gradle wrapper files (`gradlew`, `gradlew.bat`, and `gradle/wrapper/*`) only."]}}
JSON

cat >"$STEP_FILE" <<'JSON'
{"index":1,"text":"Add the Gradle wrapper files (`gradlew`, `gradlew.bat`, and `gradle/wrapper/*`) only."}
JSON

cat >"$MEMORY_FILE" <<'EOF'
# Memory
EOF

(
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 bash "$TEST_ROOT/agents/coder.sh" \
    "$PROJECT_DIR" \
    "Add Gradle wrapper" \
    "$STEP_FILE" \
    "$PLAN_FILE" \
    "$MEMORY_FILE" \
    "" \
    "$OUTPUT_FILE" >/dev/null
)

jq -e '
  .status == "fail" and
  (.message | test("Fallback implementation is unavailable")) and
  (.data.changed == false) and
  (.data.files | length == 0)
' "$OUTPUT_FILE" >/dev/null

test ! -f "$PROJECT_DIR/TASK_RESPONSE.md"

echo "coder fallback artifact guard test passed"
