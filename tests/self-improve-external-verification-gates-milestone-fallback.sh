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
  "$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts" \
  "$EXTERNAL_WORKSPACE/docs/architecture" \
  "$EXTERNAL_WORKSPACE/docs" \
  "$EXTERNAL_WORKSPACE/packages/playbooks" \
  "$EXTERNAL_WORKSPACE/packages/schema" \
  "$EXTERNAL_WORKSPACE/scripts"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/projects/superheld/spec.md" <<'EOF'
# Project Spec

project: superheld

## Goal

Build Superheld as a family-focused security platform.

## First Milestones

4. Define the initial learning-center scope tied to incidents.
5. Bootstrap the first production-lean code slice in the repo.
6. Add verification gates for every initial component.
EOF

cat >"$EXTERNAL_WORKSPACE/docs/architecture/first-slice.md" <<'EOF'
# First Slice

## Scope

- deterministic incident handling

## Mandatory MVP Protection Cases

- account recovery after credential risk
EOF

cat >"$EXTERNAL_WORKSPACE/docs/overview.md" <<'EOF'
# Superheld Overview

## Current Focus

- approval-gated risky actions

## Incident-Linked Learning Scope

- credential-recovery-required risk -> account recovery and account hardening
EOF

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/README.md" <<'EOF'
# Cloud Brain

## Runtime Blueprint

- normalized event intake

## Runtime Components

- `incidents/buildIncidentKey`

## Decision Table

- deterministic playbook binding

## First Production-Lean Slice

- `apps/cloud-brain/src/incident-flow.mjs` is the first deterministic runtime path
- `apps/cloud-brain/scripts/smoke.mjs` is the first executable verification path

## First Slice Boundaries

- one event at a time
EOF

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/src/incident-flow.mjs" <<'EOF'
const INCIDENT_TYPE_BY_EVENT = {
  credential_recovery_trigger: "credential_recovery_required",
};

const LEARNING_MODULES_BY_INCIDENT = {
  credential_recovery_required: [
    "account_recovery_basics",
    "password_manager_setup",
  ],
};

export function buildIncidentSummary(incidentType) {
  if (incidentType === "credential_recovery_required") {
    return {
      incident_type: "credential_recovery_required",
      recommended_learning_modules: LEARNING_MODULES_BY_INCIDENT[incidentType],
    };
  }
  return { incident_type: incidentType, recommended_learning_modules: [] };
}
EOF

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts/smoke.mjs" <<'EOF'
const supportedPlaybooks = [
  "social_message_risk_review",
  "account_recovery_after_credential_risk",
];

const expected = {
  event_type: "credential_recovery_trigger",
  incident_type: "credential_recovery_required",
  playbook_id: "account_recovery_after_credential_risk",
};

console.log(JSON.stringify({ supportedPlaybooks, expected }));
EOF

cat >"$EXTERNAL_WORKSPACE/scripts/verify-baseline.sh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLOUD_README="$ROOT_DIR/apps/cloud-brain/README.md"
WEB_README="$ROOT_DIR/apps/web/README.md"

require_pattern() {
  :
}

require_pattern "## Runtime Blueprint" "$CLOUD_README" "cloud-brain runtime blueprint marker is missing"
require_pattern "## Runtime Components" "$CLOUD_README" "cloud-brain runtime components marker is missing"
require_pattern "## Decision Table" "$CLOUD_README" "cloud-brain decision table marker is missing"
require_pattern "## First-Screen Layout" "$WEB_README" "web first-screen layout marker is missing"
require_pattern "## Approval Flow" "$WEB_README" "web approval flow marker is missing"
require_pattern "## Learning Recommendations" "$WEB_README" "web learning recommendations marker is missing"
EOF

cat >"$EXTERNAL_WORKSPACE/packages/schema/telemetry-event.schema.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "event_type": {
      "type": "string",
      "enum": [
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
  "type": "object",
  "properties": {
    "incident_type": {
      "type": "string",
      "enum": [
        "credential_recovery_required"
      ]
    }
  },
  "examples": [
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
  "trigger_event_types": [
    "social_message_warning"
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/media_authenticity_risk_review.json" <<'EOF'
{
  "id": "media_authenticity_risk_review",
  "trigger_event_types": [
    "media_authenticity_warning"
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/phishing_link_response.json" <<'EOF'
{
  "id": "phishing_link_response",
  "trigger_event_types": [
    "phishing_link_warning"
  ]
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/account_recovery_after_credential_risk.json" <<'EOF'
{
  "id": "account_recovery_after_credential_risk",
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
{"timestamp":"2026-03-30T08:00:00Z","project":"superheld","task":"Baseline verification success","task_id":"success-1","result":"SUCCESS","attempt":1}
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

pending_summary="$(
  jq -r '
    .tasks[]
    | select(.status == "pending_approval")
    | [.title, (.target_files[0] // ""), (.reason // "")]
    | @tsv
  ' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if ! printf '%s\n' "$pending_summary" | grep -Fq $'Extend baseline verification for initial learning and slice markers\tscripts/verify-baseline.sh\tStart with `scripts/verify-baseline.sh` near the top-level path constants and the existing `require_pattern` block after the README checks.'; then
  echo "expected verification-gates milestone fallback task, got: $pending_summary" >&2
  exit 1
fi

if ! printf '%s\n' "$pending_summary" | grep -Fq 'docs/overview.md'; then
  echo "expected verification-gates fallback to mention overview verification, got: $pending_summary" >&2
  exit 1
fi

echo "self improve external verification gates milestone fallback test passed"
