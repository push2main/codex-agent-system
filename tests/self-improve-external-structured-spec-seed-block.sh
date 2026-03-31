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
  "$EXTERNAL_WORKSPACE/packages/playbooks"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/projects/superheld/spec.md" <<'EOF'
# Project Spec

project: superheld

## Goal

Build Superheld as a family-focused security platform.

## Milestone Seeds
```json
{
  "seeds": [
    {
      "milestone": "Confirm mandatory MVP protection cases.",
      "title": "Document mandatory MVP protection cases in first slice",
      "category": "learning",
      "target_file": "docs/architecture/first-slice.md",
      "anchor": "## Scope",
      "done_markers": [
        "## Mandatory MVP Protection Cases"
      ],
      "reference_globs": [
        "packages/playbooks/*.json"
      ],
      "reference_min_count": 1,
      "reference_limit": 4,
      "reason_template": "Start with `{target_file}` after `{anchor}`. `{spec_ref}` defines milestone `{milestone}`, but the first-slice architecture doc does not yet define a dedicated `## Mandatory MVP Protection Cases` section. Add one deterministic section that enumerates the currently supported first-slice protection cases backed by {reference_paths}.",
      "priority": "medium",
      "impact": 5,
      "effort": 2,
      "confidence": 0.84,
      "success_signals": [
        "The first-slice doc includes a `## Mandatory MVP Protection Cases` section."
      ],
      "verification_command": "bash scripts/verify-baseline.sh"
    }
  ]
}
```
EOF

cat >"$EXTERNAL_WORKSPACE/docs/architecture/first-slice.md" <<'EOF'
# First Slice

## Scope

- deterministic incident intake
- family-safe explanation
- approval-gated risky follow-up actions
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/social_message_risk_review.json" <<'EOF'
{"id":"social_message_risk_review"}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/media_authenticity_risk_review.json" <<'EOF'
{"id":"media_authenticity_risk_review"}
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
{"timestamp":"2026-03-30T08:00:00Z","project":"superheld","task":"Baseline spec seed success","task_id":"success-1","result":"SUCCESS","attempt":1}
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

pending_task_json="$(
  jq -c '
    .tasks[]
    | select(.status == "pending_approval")
    | {
        title,
        target_file: (.target_files[0] // ""),
        reason: (.reason // ""),
        verification_command: (.task_shape.verification_command // ""),
        success_signals: (.task_intent.success_signals // [])
      }
  ' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if ! printf '%s\n' "$pending_task_json" | jq -e '
  .title == "Document mandatory MVP protection cases in first slice" and
  .target_file == "docs/architecture/first-slice.md" and
  .verification_command == "bash scripts/verify-baseline.sh" and
  (.success_signals | index("The first-slice doc includes a `## Mandatory MVP Protection Cases` section.")) != null and
  (.reason | contains("Start with `docs/architecture/first-slice.md` after `## Scope`.")) and
  (.reason | contains("packages/playbooks/social_message_risk_review.json")) and
  (.reason | contains("packages/playbooks/media_authenticity_risk_review.json"))
' >/dev/null; then
  echo "expected structured spec seed task, got: $pending_task_json" >&2
  exit 1
fi

echo "self improve external structured spec seed block test passed"
