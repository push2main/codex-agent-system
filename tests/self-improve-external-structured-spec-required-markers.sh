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
  "$EXTERNAL_WORKSPACE/apps/cloud-brain" \
  "$EXTERNAL_WORKSPACE/docs" \
  "$EXTERNAL_WORKSPACE/scripts"
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
      "milestone": "Add verification gates for every initial component.",
      "title": "Extend baseline verification for initial learning and slice markers",
      "category": "stability",
      "target_file": "scripts/verify-baseline.sh",
      "done_markers": [
        "## Incident-Linked Learning Scope",
        "## First Production-Lean Slice"
      ],
      "required_markers": [
        {
          "file": "docs/overview.md",
          "marker": "## Incident-Linked Learning Scope"
        },
        {
          "file": "apps/cloud-brain/README.md",
          "marker": "## First Production-Lean Slice"
        }
      ],
      "reason_template": "Start with `{target_file}` near the top-level path constants and the existing `require_pattern` block after the README checks. `{spec_ref}` lists milestone `{milestone}`, but baseline verification still does not require `docs/overview.md` to keep `## Incident-Linked Learning Scope` or `apps/cloud-brain/README.md` to keep `## First Production-Lean Slice`. Add the missing deterministic file constant plus `require_file`/`require_pattern` checks so the initial component markers stay guarded.",
      "priority": "medium",
      "impact": 5,
      "effort": 2,
      "confidence": 0.84
    }
  ]
}
```
EOF

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/README.md" <<'EOF'
# Cloud Brain

## Decision Table

- narrow first slice
EOF

cat >"$EXTERNAL_WORKSPACE/docs/overview.md" <<'EOF'
# Overview

## Current Focus

- learning follows incidents
EOF

cat >"$EXTERNAL_WORKSPACE/scripts/verify-baseline.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "baseline verification passed"
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
{"timestamp":"2026-03-30T08:00:00Z","project":"superheld","task":"Baseline required markers success","task_id":"success-1","result":"SUCCESS","attempt":1}
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

pending_count_before="$(
  jq '[.tasks[] | select(.status == "pending_approval")] | length' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"
if [ "${pending_count_before:-0}" != "0" ]; then
  echo "expected no task before required markers exist, got: $pending_count_before" >&2
  exit 1
fi

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/README.md" <<'EOF'
# Cloud Brain

## Decision Table

- narrow first slice

## First Production-Lean Slice

- runtime anchors
EOF

cat >"$EXTERNAL_WORKSPACE/docs/overview.md" <<'EOF'
# Overview

## Current Focus

- learning follows incidents

## Incident-Linked Learning Scope

- narrow v1 scope
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
  echo "expected required-markers structured seed task, got: $pending_summary" >&2
  exit 1
fi

echo "self improve external structured spec required markers test passed"
