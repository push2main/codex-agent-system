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
  "$EXTERNAL_WORKSPACE/packages/playbooks"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "recent_success_rate": 0.12,
  "first_pass_success_rate": 0.75,
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
  "retry_churn_detected": true,
  "loop_effort_task_count": 1,
  "loop_effort_extra_step_attempts": 1,
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
{"timestamp":"2026-03-29T20:10:00Z","project":"superheld","task":"retry churn sample","task_id":"fail-1","result":"FAILURE","attempt":2,"attempts":2,"failure_kind":"review_rejection","total_step_attempts":2}
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
        "credential_recovery_required"
      ]
    },
    "playbook_id": {
      "type": "string",
      "enum": [
        "social_message_risk_review",
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
        "media_authenticity_risk_detected"
      ]
    }
  },
  "examples": [
    {
      "event_id": "evt_social_001",
      "event_type": "social_message_risk_detected"
    }
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/schema/README.md" <<'EOF'
# Schema Package

- every incident must map to at least one event
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/account_recovery_after_credential_risk.json" <<'EOF'
{
  "id": "account_recovery_after_credential_risk",
  "incident_type": "credential_recovery_required",
  "trigger_event_types": [
    "credential_risk_detected",
    "user_reported_credential_exposure"
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

pending_summary="$(
  jq -r '
    .tasks
    | map(select(.status == "pending_approval"))
    | map([.title, (.target_files[0] // ""), .reason] | @tsv)
    | .[]
  ' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if ! printf '%s\n' "$pending_summary" | grep -Fq $'Add credential recovery trigger coverage to telemetry event schema\tpackages/schema/telemetry-event.schema.json'; then
  echo "expected telemetry playbook coverage task for missing credential triggers, got: $pending_summary" >&2
  exit 1
fi

if ! printf '%s\n' "$pending_summary" | grep -Fq 'credential_risk_detected'; then
  echo "expected telemetry gap task to mention missing credential trigger event type, got: $pending_summary" >&2
  exit 1
fi

if ! printf '%s\n' "$pending_summary" | grep -Fq 'user_reported_credential_exposure'; then
  echo "expected telemetry gap task to mention both missing trigger event types, got: $pending_summary" >&2
  exit 1
fi

if printf '%s\n' "$pending_summary" | grep -Fq 'Break retry churn'; then
  echo "expected external control-plane retry churn task to stay suppressed, got: $pending_summary" >&2
  exit 1
fi

echo "self improve external telemetry playbook gap generation test passed"
