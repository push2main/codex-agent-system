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
  "$EXTERNAL_WORKSPACE/packages/schema" \
  "$EXTERNAL_WORKSPACE/apps/web" \
  "$EXTERNAL_WORKSPACE/apps/cloud-brain/src" \
  "$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts" \
  "$EXTERNAL_WORKSPACE/scripts"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.64,
  "recent_success_rate": 0.64,
  "first_pass_success_rate": 0.72,
  "timeout_failure_rate": 0.01,
  "zero_step_timeout_rate": 0.0,
  "retry_classification_coverage": 0.9,
  "retry_classified_count": 9,
  "retry_total_count": 10,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 25
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-31T07:00:00Z","project":"superheld","task":"completed task 1","task_id":"done-1","result":"SUCCESS","attempt":1}
EOF

reset_registry() {
  cat >"$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF
}

reset_registry

cat >"$EXTERNAL_WORKSPACE/apps/web/README.md" <<'EOF'
# Web App

## Incident State Contract

### First Dashboard Incident Payload

- `incident_id`: stable incident record identifier rendered by the dashboard
- `affected_person`: household member label shown on the incident card
- `status`: incident lifecycle state shown in dashboard lists
EOF

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/src/incident-flow.mjs" <<'EOF'
export function projectDashboardContractFields({ incident, event }) {
  return {
    ...incident,
    affected_person: incident.affected_person || event.member_id,
    status: incident.status || "pending_approval",
  };
}
EOF

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts/smoke.mjs" <<'EOF'
const dashboardIncidentFields = [
  "incident_id",
  "status"
];

const credentialRecoveryDashboardPayload = Object.fromEntries(
  dashboardIncidentFields.map((field) => [field, credentialRecoveryRun.incident[field]])
);
EOF

cat >"$EXTERNAL_WORKSPACE/scripts/verify-baseline.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

require_query() {
  :
}

require_query '.properties.status.enum | index("pending_approval")' \
  "packages/schema/incident.schema.json" \
  "dashboard incident status contract is missing"
EOF
chmod +x "$EXTERNAL_WORKSPACE/scripts/verify-baseline.sh"

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

cat >"$EXTERNAL_WORKSPACE/packages/schema/incident.schema.json" <<'EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Incident",
  "type": "object",
  "required": [
    "incident_id",
    "status"
  ],
  "properties": {
    "incident_id": {
      "type": "string"
    },
    "status": {
      "type": "string",
      "enum": ["open", "pending_approval", "resolved"]
    }
  },
  "examples": [
    {
      "incident_id": "inc_001",
      "status": "pending_approval"
    }
  ]
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh superheld >/dev/null 2>&1
)

pending_summary_schema="$(
  jq -r '
    .tasks
    | map(select(.status == "pending_approval"))
    | map([.title, (.target_files[0] // ""), .reason] | @tsv)
    | .[]
  ' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"
schema_verification_command="$(
  jq -r '.tasks[] | select(.status == "pending_approval") | .task_shape.verification_command' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if ! printf '%s\n' "$pending_summary_schema" | grep -Fq $'Add dashboard affected person field to incident schema\tpackages/schema/incident.schema.json'; then
  echo "expected dashboard affected person schema task, got: $pending_summary_schema" >&2
  exit 1
fi

if ! printf '%s\n' "$pending_summary_schema" | grep -Fq 'apps/web/README.md'; then
  echo "expected schema gap task to ground on the web contract, got: $pending_summary_schema" >&2
  exit 1
fi

if [[ "$schema_verification_command" != jq\ -e*affected_person*packages/schema/incident.schema.json* ]]; then
  echo "expected schema gap task to freeze a focused jq verification command, got: $schema_verification_command" >&2
  exit 1
fi

reset_registry

cat >"$EXTERNAL_WORKSPACE/packages/schema/incident.schema.json" <<'EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Incident",
  "type": "object",
  "required": [
    "incident_id",
    "affected_person",
    "status"
  ],
  "properties": {
    "incident_id": {
      "type": "string"
    },
    "affected_person": {
      "type": "string",
      "minLength": 1
    },
    "status": {
      "type": "string",
      "enum": ["open", "pending_approval", "resolved"]
    }
  },
  "examples": [
    {
      "incident_id": "inc_001",
      "affected_person": "child-1",
      "status": "pending_approval"
    }
  ]
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh superheld >/dev/null 2>&1
)

pending_summary_smoke="$(
  jq -r '
    .tasks
    | map(select(.status == "pending_approval"))
    | map([.title, (.target_files[0] // ""), .reason] | @tsv)
    | .[]
  ' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"
smoke_verification_command="$(
  jq -r '.tasks[] | select(.status == "pending_approval") | .task_shape.verification_command' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if ! printf '%s\n' "$pending_summary_smoke" | grep -Fq $'Verify dashboard affected person field in smoke flow\tapps/cloud-brain/scripts/smoke.mjs'; then
  echo "expected dashboard affected person smoke task, got: $pending_summary_smoke" >&2
  exit 1
fi

if ! printf '%s\n' "$pending_summary_smoke" | grep -Fq 'dashboardIncidentFields'; then
  echo "expected smoke gap task to ground on dashboardIncidentFields, got: $pending_summary_smoke" >&2
  exit 1
fi

if [ "$smoke_verification_command" != "node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing" ]; then
  echo "expected smoke gap task to freeze the project-local smoke verification command, got: $smoke_verification_command" >&2
  exit 1
fi

reset_registry

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts/smoke.mjs" <<'EOF'
const dashboardIncidentFields = [
  "incident_id",
  "affected_person",
  "status"
];

const credentialRecoveryDashboardPayload = Object.fromEntries(
  dashboardIncidentFields.map((field) => [field, credentialRecoveryRun.incident[field]])
);

if (credentialRecoveryDashboardPayload.affected_person !== credentialRecoveryEvent.member_id) {
  throw new Error("credential recovery incident should expose dashboard affected_person payload");
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh superheld >/dev/null 2>&1
)

pending_summary_verify="$(
  jq -r '
    .tasks
    | map(select(.status == "pending_approval"))
    | map([.title, (.target_files[0] // ""), .reason] | @tsv)
    | .[]
  ' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"
baseline_verification_command="$(
  jq -r '.tasks[] | select(.status == "pending_approval") | .task_shape.verification_command' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if ! printf '%s\n' "$pending_summary_verify" | grep -Fq $'Guard dashboard affected person field in baseline verification\tscripts/verify-baseline.sh'; then
  echo "expected dashboard affected person baseline verification task, got: $pending_summary_verify" >&2
  exit 1
fi

if ! printf '%s\n' "$pending_summary_verify" | grep -Fq 'dashboard field `affected_person`'; then
  echo "expected baseline gap task to ground on affected_person, got: $pending_summary_verify" >&2
  exit 1
fi

if [ "$baseline_verification_command" != "bash scripts/verify-baseline.sh" ]; then
  echo "expected baseline gap task to freeze the project-local baseline verification command, got: $baseline_verification_command" >&2
  exit 1
fi

echo "self improve external dashboard contract continuation chain test passed"
