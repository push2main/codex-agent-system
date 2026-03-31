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

recent_terminal_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=30)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

mkdir -p \
  "$REPO_ROOT/scripts" \
  "$REPO_ROOT/codex-memory" \
  "$REPO_ROOT/codex-learning" \
  "$REPO_ROOT/codex-logs" \
  "$REPO_ROOT/queues" \
  "$REPO_ROOT/projects/superheld" \
  "$EXTERNAL_WORKSPACE/.codex-agent" \
  "$EXTERNAL_WORKSPACE/docs/architecture" \
  "$EXTERNAL_WORKSPACE/packages/playbooks" \
  "$EXTERNAL_WORKSPACE/packages/schema"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/projects/superheld/spec.md" <<'EOF'
# Project Spec

project: superheld

## Goal

Build Superheld as a family-focused security platform.

## First Milestones

1. Confirm mandatory MVP protection cases.
2. Define telemetry schema, incident model, and first playbooks.
EOF

cat >"$EXTERNAL_WORKSPACE/docs/architecture/first-slice.md" <<'EOF'
# First Slice: Social Message, Fake Profile, and Authenticity Risk Review

## Scope

- detection or intake of a suspicious message, fake profile, fake account warning, or user-reported authenticity-risk signal
- normalized event creation
- incident creation and deduplication
- family-safe explanation
- learning recommendation
- approval-gated risky follow-up actions
EOF

cat >"$EXTERNAL_WORKSPACE/packages/schema/README.md" <<'EOF'
# Schema Package

Rules:

- every incident must map to at least one event
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
      "event_type": "credential_recovery_trigger"
    }
  ]
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
      "household_id": "hh_demo_family",
      "summary": "Social risk example.",
      "playbook_id": "social_message_risk_review",
      "recommended_learning_modules": [
        "safe_dm_responses"
      ]
    },
    {
      "incident_id": "inc_credential_recovery_001",
      "incident_type": "credential_recovery_required",
      "household_id": "hh_demo_family",
      "summary": "Credential recovery example.",
      "playbook_id": "account_recovery_after_credential_risk",
      "recommended_learning_modules": [
        "account_recovery_basics"
      ]
    }
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/social_message_risk_review.json" <<'EOF'
{
  "id": "social_message_risk_review",
  "incident_type": "social_message_risk",
  "trigger_event_types": [
    "social_message_risk_detected"
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/media_authenticity_risk_review.json" <<'EOF'
{
  "id": "media_authenticity_risk_review",
  "incident_type": "media_authenticity_risk",
  "trigger_event_types": [
    "media_authenticity_risk_detected"
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/phishing_link_response.json" <<'EOF'
{
  "id": "phishing_link_response",
  "incident_type": "phishing_link_risk",
  "trigger_event_types": [
    "link_risk_detected"
  ]
}
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

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.22,
  "recent_success_rate": 0.26,
  "first_pass_success_rate": 1.0,
  "timeout_failure_rate": 0.44,
  "zero_step_timeout_rate": 0.9,
  "retry_classification_coverage": 1.0,
  "retry_classified_count": 12,
  "retry_total_count": 12,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_payload_bytes": 24000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "total_tasks": 40
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<EOF
{"timestamp":"$recent_terminal_at","project":"superheld","task":"Seed success","task_id":"success-1","result":"SUCCESS","attempt":1}
EOF

cat >"$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-001-gap",
      "project": "superheld",
      "title": "Add credential recovery trigger coverage to telemetry event schema",
      "status": "failed",
      "updated_at": "$recent_terminal_at",
      "target_files": [
        "packages/schema/telemetry-event.schema.json"
      ],
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-002-gap-inventory",
      "project": "superheld",
      "title": "Inventory current decision path for add credential recovery trigger coverage to telemetry event schema",
      "status": "completed",
      "updated_at": "$recent_terminal_at",
      "completed_at": "$recent_terminal_at",
      "strategy_template": "bounded_learning_inventory",
      "target_files": [
        "packages/schema/telemetry-event.schema.json"
      ],
      "task_intent": {
        "source": "self-improve"
      }
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
  "memory_file": "$REPO_ROOT/projects/superheld/memory.md",
  "spec_file": "$REPO_ROOT/projects/superheld/spec.md",
  "policy_file": "$REPO_ROOT/projects/superheld/policy.json",
  "task_registry_file": "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS=86400 \
  SELF_IMPROVE_TITLE_FAMILY_RETRY_COOLDOWN_SECONDS=7200 \
  SELF_IMPROVE_TITLE_FAMILY_SATURATION_COOLDOWN_SECONDS=86400 \
  bash scripts/self-improve.sh superheld >/dev/null 2>&1
)

pending_summary="$(
  jq -r '
    .tasks
    | map(select(.status == "pending_approval"))
    | map([.title, (.target_files[0] // ""), (.reason // "")] | @tsv)
    | .[]
  ' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if ! printf '%s\n' "$pending_summary" | grep -Fq $'Document mandatory MVP protection cases in first slice\tdocs/architecture/first-slice.md'; then
  echo "expected spec milestone seed fallback when the external product gap family is cooled down, got: $pending_summary" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.detected,
      .counts.generated,
      .counts.submitted,
      .selection.selected_title
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"

if [ "$artifact_summary" != $'2\t1\t1\tDocument mandatory MVP protection cases in first slice' ]; then
  echo "unexpected external blocked-gap seed fallback summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve external blocked gap seed fallback test passed"
