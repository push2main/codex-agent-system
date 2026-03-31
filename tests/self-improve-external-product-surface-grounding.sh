#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"
EXTERNAL_WORKSPACE="$TMP_DIR/superheld-repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p \
  "$REPO_ROOT/scripts" \
  "$REPO_ROOT/codex-memory" \
  "$REPO_ROOT/codex-learning" \
  "$REPO_ROOT/codex-logs" \
  "$REPO_ROOT/queues" \
  "$REPO_ROOT/projects/superheld" \
  "$EXTERNAL_WORKSPACE/.codex-agent" \
  "$EXTERNAL_WORKSPACE/apps/cloud-brain/src" \
  "$EXTERNAL_WORKSPACE/packages/schema" \
  "$EXTERNAL_WORKSPACE/scripts"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/src/incident-flow.mjs" <<'EOF'
export function buildIncidentFlow(input) {
  return {
    incidentId: String(input?.incidentId || "incident-unknown"),
    severity: String(input?.severity || "unknown"),
  };
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/schema/incident.schema.json" <<'EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Incident",
  "type": "object",
  "properties": {
    "incident_type": {
      "type": "string",
      "enum": [
        "social_message_risk",
        "credential_recovery_required"
      ]
    }
  },
  "examples": [
    {
      "incident_id": "inc_social_001",
      "incident_type": "social_message_risk",
      "household_id": "hh_demo_family",
      "summary": "Social risk example.",
      "recommended_learning_modules": [
        "safe_dm_responses"
      ]
    }
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/scripts/lib.sh" <<'EOF'
#!/usr/bin/env bash
baseline_verification_fail() {
  return 1
}

run_baseline_verification() {
  return 0
}
EOF

cat >"$EXTERNAL_WORKSPACE/scripts/verify-baseline.sh" <<'EOF'
#!/usr/bin/env bash
require_pattern() {
  return 0
}

require_pattern "foo" "bar"
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "recent_success_rate": 0.14,
  "first_pass_success_rate": 0.82,
  "timeout_failure_rate": 0.33,
  "zero_step_timeout_rate": 0.6,
  "retry_classification_coverage": 0.82,
  "retry_classified_count": 41,
  "retry_total_count": 50,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "total_tasks": 240
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-29T20:00:00Z","project":"superheld","task":"Successful first-pass task 1","task_id":"success-1","result":"SUCCESS","attempt":1}
{"timestamp":"2026-03-29T20:01:00Z","project":"superheld","task":"Successful first-pass task 2","task_id":"success-2","result":"SUCCESS","attempt":1}
{"timestamp":"2026-03-29T20:02:00Z","project":"superheld","task":"Successful first-pass task 3","task_id":"success-3","result":"SUCCESS","attempt":1}
{"timestamp":"2026-03-29T20:03:00Z","project":"superheld","task":"Timeout task 1","task_id":"timeout-1","result":"FAILURE","attempt":2,"attempts":2,"failure_kind":"timeout","total_step_attempts":0}
{"timestamp":"2026-03-29T20:04:00Z","project":"superheld","task":"Timeout task 2","task_id":"timeout-2","result":"FAILURE","attempt":2,"attempts":2,"failure_kind":"timeout","total_step_attempts":0}
{"timestamp":"2026-03-29T20:05:00Z","project":"superheld","task":"Timeout task 3","task_id":"timeout-3","result":"FAILURE","attempt":2,"attempts":2,"failure_kind":"timeout","total_step_attempts":0}
{"timestamp":"2026-03-29T20:06:00Z","project":"superheld","task":"Timeout task 4","task_id":"timeout-4","result":"FAILURE","attempt":2,"attempts":2,"failure_kind":"timeout","total_step_attempts":1}
{"timestamp":"2026-03-29T20:07:00Z","project":"superheld","task":"Timeout task 5","task_id":"timeout-5","result":"FAILURE","attempt":2,"attempts":2,"failure_kind":"timeout","total_step_attempts":1}
{"timestamp":"2026-03-29T20:08:00Z","project":"superheld","task":"Retry failure task 1","task_id":"retry-1","result":"FAILURE","attempt":2,"attempts":2,"failure_kind":"tool_failure","total_step_attempts":2}
{"timestamp":"2026-03-29T20:09:00Z","project":"superheld","task":"Retry failure task 2","task_id":"retry-2","result":"FAILURE","attempt":2,"attempts":2,"failure_kind":"tool_failure","total_step_attempts":2}
{"timestamp":"2026-03-29T20:10:00Z","project":"superheld","task":"Retry failure task 3","task_id":"retry-3","result":"FAILURE","attempt":2,"attempts":2,"failure_kind":"tool_failure","total_step_attempts":2}
{"timestamp":"2026-03-29T20:11:00Z","project":"superheld","task":"Retry failure task 4","task_id":"retry-4","result":"FAILURE","attempt":2,"attempts":2,"failure_kind":"tool_failure","total_step_attempts":2}
{"timestamp":"2026-03-29T20:12:00Z","project":"superheld","task":"Retry failure task 5","task_id":"retry-5","result":"FAILURE","attempt":2,"attempts":2,"failure_kind":"tool_failure","total_step_attempts":2}
EOF

cat >"$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-006-cloud-brain-runtime-scaffold",
      "title": "Implement a deterministic cloud-brain runtime scaffold",
      "project": "superheld",
      "category": "stability",
      "status": "completed",
      "target_files": ["apps/cloud-brain/src/incident-flow.mjs"],
      "updated_at": "2026-03-29T20:16:00Z"
    },
    {
      "id": "task-007-reduce-timeout-rate",
      "title": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%",
      "project": "superheld",
      "category": "performance",
      "status": "failed",
      "target_files": ["agents/planner.sh", "agents/orchestrator.sh", "scripts/queue-worker.sh"],
      "task_intent": {
        "source": "self-improve",
        "objective": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%",
        "project": "superheld",
        "category": "performance",
        "affected_files": ["agents/planner.sh", "agents/orchestrator.sh", "scripts/queue-worker.sh"]
      },
      "step_artifacts": {
        "step_1_inspection": {
          "identified_file": "scripts/verify-baseline.sh",
          "edit_anchor": "the top-level verification block immediately after `require_pattern()`",
          "location": {
            "line": 5,
            "context": "after `require_pattern()` in `scripts/verify-baseline.sh`"
          }
        }
      },
      "updated_at": "2026-03-27T20:36:00Z"
    },
    {
      "id": "task-008-improve-retry-success-rate",
      "title": "[self-improve:high] Improve retry success rate -- Retry attempts are failing 79% of the time (21% overall vs 100% first-pass). Analyze recen",
      "project": "superheld",
      "category": "stability",
      "status": "failed",
      "target_files": ["agents/orchestrator.sh", "scripts/lib.sh"],
      "task_intent": {
        "source": "self-improve",
        "objective": "[self-improve:high] Improve retry success rate -- Retry attempts are failing 79% of the time (21% overall vs 100% first-pass). Analyze recen",
        "project": "superheld",
        "category": "stability",
        "affected_files": ["agents/orchestrator.sh", "scripts/lib.sh"]
      },
      "step_artifacts": {
        "step_1_inspection": {
          "identified_file": "scripts/lib.sh",
          "edit_anchor": "insert a retry-failure context helper immediately after `baseline_verification_fail()` and before `run_baseline_verification()`",
          "location": {
            "line": 2,
            "context": "top-level shell helper section between `baseline_verification_fail()` and `run_baseline_verification()`"
          }
        }
      },
      "updated_at": "2026-03-27T20:21:47Z"
    }
  ]
}
EOF

cat >"$REPO_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_WORKSPACE",
  "repo_url": "https://example.invalid/superheld",
  "memory_file": "$EXTERNAL_WORKSPACE/.codex-agent/memory.md",
  "spec_file": "$EXTERNAL_WORKSPACE/.codex-agent/spec.md",
  "policy_file": "$EXTERNAL_WORKSPACE/.codex-agent/policy.json",
  "task_registry_file": "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh superheld >/dev/null 2>&1
)

pending_count="$(
  jq '[.tasks[] | select(.status == "pending_approval")] | length' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"
if [ "${pending_count:-0}" != "1" ]; then
  echo "expected one product-grounded pending_approval task, got: $pending_count" >&2
  exit 1
fi

pending_summary="$(
  jq -r '
    .tasks[]
    | select(.status == "pending_approval")
    | [.title, (.target_files[0] // ""), (.reason // "")]
    | @tsv
  ' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"
if ! printf '%s\n' "$pending_summary" | grep -Fq $'Add canonical incident example for credential recovery required\tpackages/schema/incident.schema.json\tStart with `packages/schema/incident.schema.json`'; then
  echo "expected external product-surface grounding to produce a schema-gap task, got: $pending_summary" >&2
  exit 1
fi

if ! printf '%s\n' "$pending_summary" | grep -Fq 'incident_type: "credential_recovery_required"'; then
  echo "expected external product-surface grounding to keep incident_type-based schema guidance, got: $pending_summary" >&2
  exit 1
fi

if printf '%s\n' "$pending_summary" | grep -Eq 'Break retry churn|Reduce timeout rate|Improve retry success rate|Cap pre-step planning budget'; then
  echo "expected external product-surface grounding to suppress control-plane tasks, got: $pending_summary" >&2
  exit 1
fi

echo "self improve external product surface grounding test passed"
