#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/workspaces/superheld"
OUTPUT_FILE="$TMP_DIR/plan.json"
MARKER_FILE="$TMP_DIR/provider-invoked"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p \
  "$TEST_ROOT/bin" \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects/superheld" \
  "$PROJECT_DIR/.codex-agent" \
  "$PROJECT_DIR/packages/schema"

cat >"$TEST_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$PROJECT_DIR",
  "repo_url": "https://example.invalid/superheld",
  "policy_file": "$TEST_ROOT/projects/superheld/policy.json",
  "task_registry_file": "$PROJECT_DIR/.codex-agent/tasks.json"
}
EOF

cat >"$TEST_ROOT/projects/superheld/policy.json" <<'EOF'
{
  "project": "superheld",
  "risk_profile": "high",
  "auto_approve_allowed": true,
  "manual_review_required_keywords": []
}
EOF

cat >"$PROJECT_DIR/packages/schema/incident.schema.json" <<'EOF'
{
  "title": "Incident schema fixture"
}
EOF

cat >"$PROJECT_DIR/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-superheld-learning-inventory",
      "title": "Inventory current decision path for cap pre-step planning budget",
      "project": "superheld",
      "status": "approved",
      "created_at": "2026-03-29T23:16:01Z",
      "updated_at": "2026-03-29T23:16:01Z",
      "strategy_template": "bounded_learning_inventory",
      "experiment": "Inspect the current code path most directly related to cap pre-step planning budget, starting with agents/planner.sh, then write one compact inventory artifact at codex-memory/self-improve-inventory-cap-pre-step-planning-budget.md. Expected: identify one existing file and one concrete edit location before making changes. Record secondary files, functions, metrics, or gates only when they directly feed that primary edit site. Do not implement code changes in the same run.",
      "task_intent": {
        "source": "self-improve",
        "objective": "Inventory current decision path for cap pre-step planning budget",
        "project": "superheld",
        "category": "learning",
        "context_hint": "Start with `packages/schema/incident.schema.json` at insert an `examples` array after the `properties` object and before the final root `}`.",
        "affected_files": [
          "packages/schema/incident.schema.json"
        ]
      },
      "execution_brief": {
        "project": "superheld",
        "editable_files": [
          "packages/schema/incident.schema.json"
        ],
        "task_intent": {
          "source": "self-improve",
          "objective": "Inventory current decision path for cap pre-step planning budget",
          "project": "superheld",
          "category": "learning",
          "affected_files": [
            "packages/schema/incident.schema.json"
          ]
        }
      },
      "failure_context": {
        "failed_step": "Inspect only `packages/schema/incident.schema.js` and identify the narrowest existing function, branch, or state transition that controls the current retry."
      }
    }
  ]
}
EOF

: >"$PROJECT_DIR/.codex-agent/tasks.log"

cat >"$TEST_ROOT/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'invoked\n' >>"${PLANNER_PROVIDER_MARKER:?}"
exit 99
EOF
chmod +x "$TEST_ROOT/bin/codex"

TASK_TEXT='In `packages/schema/incident.schema.json`, implement the smallest safe change for: Inventory current decision path for cap pre-step planning budget. Focus on Start with `packages/schema/incident.schema.json` at insert an `examples` array after the `properties` object and before the final root `}`. Direct retries for cap pre-step planning budget are current.'

(
  cd "$TEST_ROOT"
  PATH="$TEST_ROOT/bin:$PATH" \
  CLAUDE_DISABLE=1 \
  PLANNER_PROVIDER_MARKER="$MARKER_FILE" \
  PROJECT_NAME="superheld" \
  TASK_REGISTRY_FILE="$PROJECT_DIR/.codex-agent/tasks.json" \
  TASK_LOG="$PROJECT_DIR/.codex-agent/tasks.log" \
  ROOT_DIR="$TEST_ROOT" \
  TASK_ID="task-superheld-learning-inventory" \
  bash "$TEST_ROOT/agents/planner.sh" \
    "$PROJECT_DIR" \
    "$TASK_TEXT" \
    "$OUTPUT_FILE" >/dev/null
)

if [ -e "$MARKER_FILE" ]; then
  echo "planner should have skipped provider execution for bounded learning inventory tasks" >&2
  exit 1
fi

jq -e '
  .status == "success" and
  .message == "Created deterministic fallback plan." and
  .data.fallback.trigger == "bounded_learning_inventory" and
  (.data.steps[0] | contains("packages/schema/incident.schema.json")) and
  (.data.steps[0] | contains("Do not modify any file in this step")) and
  (.data.steps[0] | contains("Do not read any other file unless the target file is missing.")) and
  (.data.steps[1] | contains("codex-memory/self-improve-inventory-cap-pre-step-planning-budget.md")) and
  (.data.steps[-1] == "Run `test -s codex-memory/self-improve-inventory-cap-pre-step-planning-budget.md` and confirm the exact pass/fail outcome.") and
  ((.data.steps | join(" ")) | contains("`packages/schema/incident.schema.js`") | not) and
  ((.data.steps | join(" ")) | contains("agents/planner.sh") | not)
' "$OUTPUT_FILE" >/dev/null

grep -Fq 'bounded inventory-only follow-up' "$TEST_ROOT/codex-logs/system.log"

echo "planner bounded learning inventory external grounding test passed"
