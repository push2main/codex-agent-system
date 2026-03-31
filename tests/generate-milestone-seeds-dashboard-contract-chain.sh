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
  "$EXTERNAL_WORKSPACE/apps/web" \
  "$EXTERNAL_WORKSPACE/apps/cloud-brain/src" \
  "$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts" \
  "$EXTERNAL_WORKSPACE/packages/schema" \
  "$EXTERNAL_WORKSPACE/scripts"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/projects/superheld/spec.md" <<'EOF'
# Project Spec

project: superheld

## Goal

Build Superheld as a family-focused security platform.

## First Milestones

1. Align incident status enum with the dashboard contract.
2. Align incident approval states with the dashboard contract.
3. Add dashboard incident payload fields to the incident schema.
4. Project dashboard contract fields from the cloud-brain runtime.
5. Verify dashboard incident payload coverage in the smoke flow.
6. Add verification gates for dashboard payload and approval-state contract fields.
EOF

cat >"$EXTERNAL_WORKSPACE/apps/web/README.md" <<'EOF'
# Web

## Core Cards

- incident summary

## Incident State Contract

### Approval State Field

- allowed states:
  `not_required`
  `pending`
  `approved`
  `denied`
  `postponed`
EOF

cat >"$EXTERNAL_WORKSPACE/packages/schema/incident.schema.json" <<'EOF'
{
  "required": [
    "incident_id",
    "status",
    "approval_state"
  ],
  "properties": {
    "status": {
      "type": "string",
      "enum": [
        "open",
        "awaiting_approval",
        "resolved"
      ]
    },
    "approval_state": {
      "type": "string",
      "enum": [
        "not_required",
        "pending",
        "approved",
        "denied"
      ]
    }
  },
  "examples": [
    {
      "incident_id": "inc-1",
      "status": "awaiting_approval",
      "approval_state": "pending"
    }
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/src/incident-flow.mjs" <<'EOF'
export function runIncidentFlow() {
  return {
    incident: {
      incident_id: "inc-1",
      status: "awaiting_approval",
      approval_state: "pending"
    }
  };
}
EOF

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts/smoke.mjs" <<'EOF'
const credentialRecoveryRun = {
  incident: {
    incident_id: "inc-1"
  }
};

console.log(credentialRecoveryRun.incident.incident_id);
EOF

cat >"$EXTERNAL_WORKSPACE/scripts/verify-baseline.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
require_query() {
  :
}
EOF
chmod +x "$EXTERNAL_WORKSPACE/scripts/verify-baseline.sh"

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.9,
  "recent_success_rate": 0.9,
  "first_pass_success_rate": 0.9,
  "timeout_failure_rate": 0.0,
  "zero_step_timeout_rate": 0.0,
  "retry_classification_coverage": 1.0,
  "retry_classified_count": 2,
  "retry_total_count": 2,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_payload_bytes": 16000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "total_tasks": 8
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-30T08:00:00Z","project":"superheld","task":"Dashboard contract seed success","task_id":"success-1","result":"SUCCESS","attempt":1}
EOF

cat >"$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_WORKSPACE",
  "repo_url": "https://example.invalid/superheld",
  "memory_file": "$REPO_ROOT/projects/superheld/memory.md",
  "spec_file": "$REPO_ROOT/projects/superheld/spec.md",
  "policy_file": "$REPO_ROOT/projects/superheld/policy.json",
  "task_registry_file": "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
}
EOF

generator_output="$(
  python3 "$REPO_ROOT/scripts/generate-milestone-seeds.py" --root "$REPO_ROOT" superheld --write
)"

printf '%s\n' "$generator_output" | jq -e '.status == "success" and .data.seed_count == 6 and (.data.unresolved_milestones | length) == 0' >/dev/null
grep -Fq '"title": "Align incident status enum with dashboard contract"' "$REPO_ROOT/projects/superheld/spec.md"
grep -Fq '"title": "Verify dashboard incident payload coverage in smoke flow"' "$REPO_ROOT/projects/superheld/spec.md"

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh superheld >/dev/null 2>&1
)

pending_summary_first="$(
  jq -r '
    .tasks[]
    | select(.status == "pending_approval")
    | [.title, (.target_files[0] // ""), (.reason // "")]
    | @tsv
  ' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if ! printf '%s\n' "$pending_summary_first" | grep -Fq $'Align incident status enum with dashboard contract\tpackages/schema/incident.schema.json\tStart with `packages/schema/incident.schema.json` at the `status` enum.'; then
  echo "expected status enum seed first, got: $pending_summary_first" >&2
  exit 1
fi

cat >"$EXTERNAL_WORKSPACE/packages/schema/incident.schema.json" <<'EOF'
{
  "required": [
    "incident_id",
    "status",
    "approval_state"
  ],
  "properties": {
    "status": {
      "type": "string",
      "enum": [
        "open",
        "pending_approval",
        "resolved"
      ]
    },
    "approval_state": {
      "type": "string",
      "enum": [
        "not_required",
        "pending",
        "approved",
        "denied"
      ]
    }
  },
  "examples": [
    {
      "incident_id": "inc-1",
      "status": "pending_approval",
      "approval_state": "pending"
    }
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh superheld >/dev/null 2>&1
)

pending_summary_second="$(
  jq -r '
    .tasks[]
    | select(.status == "pending_approval")
    | [.title, (.target_files[0] // ""), (.reason // "")]
    | @tsv
  ' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if ! printf '%s\n' "$pending_summary_second" | grep -Fq $'Align incident approval states with dashboard contract\tpackages/schema/incident.schema.json\tStart with `packages/schema/incident.schema.json` at the `approval_state` enum.'; then
  echo "expected approval-state seed second, got: $pending_summary_second" >&2
  exit 1
fi

echo "generate milestone seeds dashboard contract chain test passed"
