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
  "$EXTERNAL_WORKSPACE/docs" \
  "$EXTERNAL_WORKSPACE/packages/schema" \
  "$EXTERNAL_WORKSPACE/packages/playbooks" \
  "$EXTERNAL_WORKSPACE/apps/cloud-brain/src" \
  "$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/projects/superheld/spec.md" <<'EOF'
# Project Spec

project: superheld

## Goal

Build Superheld as a family-focused security platform.

## First Milestones

1. Define telemetry schema, incident model, and first playbooks.
2. Align credential recovery playbook trigger coverage with the telemetry contract.
3. Enforce trigger-aware playbook routing in the cloud-brain runtime.
4. Verify trigger-aware credential recovery routing in the smoke flow.
EOF

cat >"$EXTERNAL_WORKSPACE/docs/overview.md" <<'EOF'
# Superheld Overview

## Repo Bootstrap Decision

- contracts in the repo are the source of truth
EOF

cat >"$EXTERNAL_WORKSPACE/packages/schema/README.md" <<'EOF'
# Schema Package

Current contracts:

- `telemetry-event.schema.json`
- `incident.schema.json`

## Baseline Contract Map

- current contracts are canonical
EOF

cat >"$EXTERNAL_WORKSPACE/packages/schema/telemetry-event.schema.json" <<'EOF'
{
  "properties": {
    "event_type": {
      "enum": [
        "credential_recovery_trigger"
      ]
    }
  }
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/schema/incident.schema.json" <<'EOF'
{"title":"Incident"}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/README.md" <<'EOF'
# Playbooks Package

Current baseline coverage:

- account recovery
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

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/src/incident-flow.mjs" <<'EOF'
export function resolveIncidentPlaybook(playbooks, incidentType) {
  return playbooks.find((playbook) => playbook.incident_type === incidentType);
}

export function runIncidentFlow({ event, playbooks }) {
  return {
    playbook: resolveIncidentPlaybook(playbooks, "credential_recovery_required"),
    event,
  };
}
EOF

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts/smoke.mjs" <<'EOF'
const credentialRecoveryRun = {
  playbook: {
    id: "account_recovery_after_credential_risk"
  }
};

console.log("cloud-brain smoke passed");
EOF

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
{"timestamp":"2026-03-30T08:00:00Z","project":"superheld","task":"Runtime chain seed success","task_id":"success-1","result":"SUCCESS","attempt":1}
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

printf '%s\n' "$generator_output" | jq -e '.status == "success" and .data.seed_count == 4 and (.data.unresolved_milestones | length) == 0' >/dev/null

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

if ! printf '%s\n' "$pending_summary_first" | grep -Fq $'Align credential recovery trigger coverage in account recovery playbook\tpackages/playbooks/account_recovery_after_credential_risk.json\tStart with `packages/playbooks/account_recovery_after_credential_risk.json` in `trigger_event_types`.'; then
  echo "expected trigger-coverage seed first, got: $pending_summary_first" >&2
  exit 1
fi

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/account_recovery_after_credential_risk.json" <<'EOF'
{
  "id": "account_recovery_after_credential_risk",
  "incident_type": "credential_recovery_required",
  "trigger_event_types": [
    "credential_risk_detected",
    "user_reported_credential_exposure",
    "credential_recovery_trigger"
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

if ! printf '%s\n' "$pending_summary_second" | grep -Fq $'Enforce trigger-aware playbook routing in incident flow\tapps/cloud-brain/src/incident-flow.mjs\tStart with `apps/cloud-brain/src/incident-flow.mjs` at `resolveIncidentPlaybook`.'; then
  echo "expected incident-flow seed second, got: $pending_summary_second" >&2
  exit 1
fi

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/src/incident-flow.mjs" <<'EOF'
export function resolveIncidentPlaybook(playbooks, incidentType, eventType) {
  return playbooks.find(
    (playbook) =>
      playbook.incident_type === incidentType &&
      Array.isArray(playbook.trigger_event_types) &&
      playbook.trigger_event_types.includes(eventType)
  );
}

export function runIncidentFlow({ event, playbooks }) {
  return {
    playbook: resolveIncidentPlaybook(playbooks, "credential_recovery_required", event.event_type),
    event,
  };
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

pending_summary_third="$(
  jq -r '
    .tasks[]
    | select(.status == "pending_approval")
    | [.title, (.target_files[0] // ""), (.reason // "")]
    | @tsv
  ' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if ! printf '%s\n' "$pending_summary_third" | grep -Fq $'Verify trigger-aware credential recovery routing in smoke flow\tapps/cloud-brain/scripts/smoke.mjs\tStart with `apps/cloud-brain/scripts/smoke.mjs` around `credentialRecoveryRun`.'; then
  echo "expected smoke verification seed third, got: $pending_summary_third" >&2
  exit 1
fi

echo "generate milestone seeds runtime chain test passed"
