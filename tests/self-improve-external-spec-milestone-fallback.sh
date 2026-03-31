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

cat >"$EXTERNAL_WORKSPACE/packages/schema/incident.schema.json" <<'EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Incident",
  "type": "object",
  "properties": {
    "incident_type": {
      "type": "string",
      "enum": [
        "social_message_risk"
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

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/social_message_risk_review.json" <<'EOF'
{
  "id": "social_message_risk_review",
  "incident_type": "social_message_risk",
  "trigger_event_types": [
    "social_message_warning"
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/media_authenticity_risk_review.json" <<'EOF'
{
  "id": "media_authenticity_risk_review",
  "incident_type": "social_message_risk",
  "trigger_event_types": [
    "media_authenticity_warning"
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/phishing_link_response.json" <<'EOF'
{
  "id": "phishing_link_response",
  "incident_type": "social_message_risk",
  "trigger_event_types": [
    "phishing_link_warning"
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/account_recovery_after_credential_risk.json" <<'EOF'
{
  "id": "account_recovery_after_credential_risk",
  "incident_type": "social_message_risk",
  "trigger_event_types": [
    "credential_recovery_trigger"
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.82,
  "recent_success_rate": 0.82,
  "first_pass_success_rate": 0.9,
  "timeout_failure_rate": 0.05,
  "zero_step_timeout_rate": 0.0,
  "retry_classification_coverage": 1.0,
  "retry_classified_count": 4,
  "retry_total_count": 4,
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
  "total_tasks": 12
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-30T08:00:00Z","project":"superheld","task":"Baseline schema alignment","task_id":"success-1","result":"SUCCESS","attempt":1}
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

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh superheld >/dev/null 2>&1
)

pending_count="$(
  jq '[.tasks[] | select(.status == "pending_approval")] | length' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"
if [ "${pending_count:-0}" != "1" ]; then
  echo "expected one milestone fallback task, got: $pending_count" >&2
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

if ! printf '%s\n' "$pending_summary" | grep -Fq $'Document mandatory MVP protection cases in first slice\tdocs/architecture/first-slice.md\tStart with `docs/architecture/first-slice.md` after `## Scope`.'; then
  echo "expected first-slice milestone fallback task, got: $pending_summary" >&2
  exit 1
fi

if ! printf '%s\n' "$pending_summary" | grep -Fq 'packages/playbooks/social_message_risk_review.json'; then
  echo "expected milestone fallback to mention current playbook coverage, got: $pending_summary" >&2
  exit 1
fi

echo "self improve external spec milestone fallback test passed"
