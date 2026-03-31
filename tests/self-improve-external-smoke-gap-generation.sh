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
  "$EXTERNAL_WORKSPACE/packages/playbooks" \
  "$EXTERNAL_WORKSPACE/apps/cloud-brain/src" \
  "$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts"
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
{"timestamp":"2026-03-29T20:00:00Z","project":"superheld","task":"completed task 1","task_id":"done-1","result":"SUCCESS","attempt":1}
EOF

cat >"$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": []
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
        "phishing_link_risk",
        "media_authenticity_risk",
        "credential_recovery_required"
      ]
    },
    "playbook_id": {
      "type": "string",
      "enum": [
        "social_message_risk_review",
        "phishing_link_response",
        "media_authenticity_risk_review",
        "account_recovery_after_credential_risk"
      ]
    }
  },
  "examples": [
    {
      "incident_id": "inc_social_001",
      "incident_type": "social_message_risk",
      "playbook_id": "social_message_risk_review"
    },
    {
      "incident_id": "inc_phishing_001",
      "incident_type": "phishing_link_risk",
      "playbook_id": "phishing_link_response"
    },
    {
      "incident_id": "inc_media_001",
      "incident_type": "media_authenticity_risk",
      "playbook_id": "media_authenticity_risk_review"
    },
    {
      "incident_id": "inc_credential_recovery_001",
      "incident_type": "credential_recovery_required",
      "playbook_id": "account_recovery_after_credential_risk"
    }
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/schema/telemetry-event.schema.json" <<'EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "TelemetryEvent",
  "type": "object",
  "properties": {
    "event_type": {
      "type": "string",
      "enum": [
        "social_message_risk_detected",
        "link_risk_detected",
        "media_authenticity_risk_detected",
        "credential_recovery_trigger"
      ]
    }
  },
  "examples": [
    {
      "event_id": "evt_social_001",
      "event_type": "social_message_risk_detected"
    },
    {
      "event_id": "evt_link_001",
      "event_type": "link_risk_detected"
    },
    {
      "event_id": "evt_media_001",
      "event_type": "media_authenticity_risk_detected"
    },
    {
      "event_id": "evt_credential_001",
      "event_type": "credential_recovery_trigger"
    }
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/account_recovery_after_credential_risk.json" <<'EOF'
{
  "id": "account_recovery_after_credential_risk",
  "incident_type": "credential_recovery_required",
  "trigger_event_types": [
    "credential_recovery_trigger"
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/src/incident-flow.mjs" <<'EOF'
const INCIDENT_TYPE_BY_EVENT = {
  social_message_risk_detected: "social_message_risk",
  link_risk_detected: "phishing_link_risk",
  media_authenticity_risk_detected: "media_authenticity_risk",
  credential_recovery_trigger: "credential_recovery_required",
};

const LEARNING_MODULES_BY_INCIDENT = {
  social_message_risk: ["spotting_unknown_contacts", "safe_dm_responses"],
  phishing_link_risk: ["fake_account_warning_basics", "phishing_link_checks"],
  media_authenticity_risk: ["deepfake_basics", "evidence_preservation_for_families"],
  credential_recovery_required: ["account_recovery_basics", "password_manager_setup"],
};

export function buildIncidentSummary(event, incidentType) {
  if (incidentType === "credential_recovery_required") {
    return "Confirmed credential exposure requires immediate account recovery.";
  }
  return incidentType;
}
EOF

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts/smoke.mjs" <<'EOF'
const playbooks = [
  "social_message_risk_review",
  "phishing_link_response",
  "media_authenticity_risk_review",
];

function runSmoke(exampleEvents) {
  const firstRun = exampleEvents[0];
  const secondRun = exampleEvents[1];
  const thirdRun = exampleEvents[2];
  return [firstRun, secondRun, thirdRun, playbooks];
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

pending_summary="$(
  jq -r '
    .tasks
    | map(select(.status == "pending_approval"))
    | map([.title, (.target_files[0] // ""), .reason] | @tsv)
    | .[]
  ' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if ! printf '%s\n' "$pending_summary" | grep -Fq $'Add credential recovery smoke coverage to cloud-brain\tapps/cloud-brain/scripts/smoke.mjs'; then
  echo "expected credential recovery smoke task, got: $pending_summary" >&2
  exit 1
fi

if ! printf '%s\n' "$pending_summary" | grep -Fq 'account_recovery_after_credential_risk'; then
  echo "expected smoke task to ground the edit on the account recovery playbook id, got: $pending_summary" >&2
  exit 1
fi

if ! printf '%s\n' "$pending_summary" | grep -Fq 'credential_recovery_required'; then
  echo "expected smoke task to ground the edit on credential_recovery_required, got: $pending_summary" >&2
  exit 1
fi

echo "self improve external smoke gap generation test passed"
