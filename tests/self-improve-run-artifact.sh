#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

make_repo() {
  local repo_root="$1"
  mkdir -p "$repo_root"
  cp -R "$ROOT_DIR/scripts" "$repo_root/scripts"
  mkdir -p "$repo_root/codex-memory" "$repo_root/codex-learning" "$repo_root/codex-logs" "$repo_root/queues" "$repo_root/projects"
}

REPO_ROOT="$TMP_DIR/repo"
make_repo "$REPO_ROOT"
mkdir -p "$REPO_ROOT/projects/codex-agent-system"

cat >"$REPO_ROOT/projects/codex-agent-system/project.json" <<EOF
{
  "project": "codex-agent-system",
  "project_id": "codex-agent-system",
  "workspace": "$REPO_ROOT",
  "repo_url": "https://example.com/codex-agent-system.git",
  "memory_file": "$REPO_ROOT/projects/codex-agent-system/memory.md",
  "spec_file": "$REPO_ROOT/projects/codex-agent-system/spec.md",
  "policy_file": "$REPO_ROOT/projects/codex-agent-system/policy.json",
  "task_registry_file": "$REPO_ROOT/codex-memory/tasks.json",
  "automation_id": "push2main-codex-agent-system"
}
EOF

mkdir -p "$REPO_ROOT/projects/codex-agent-system/automation-memory"
cat >"$REPO_ROOT/projects/codex-agent-system/automation-memory/push2main-codex-agent-system.md" <<'EOF'
# Automation Memory

project: codex-agent-system
automation_id: push2main-codex-agent-system

- 2026-03-25T05:10:00Z | artifact hydration fixture | external_sync_pending=false
EOF

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "first_pass_success_rate": 0.64,
  "timeout_failure_rate": 0.11,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "task_registry_total": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "external_signal_status": "fresh",
  "total_tasks": 100
}
EOF

(
  cd "$REPO_ROOT"
  HOME="$TMP_DIR/home" IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

artifact_file="$REPO_ROOT/codex-learning/self-improve-run.json"
if [ ! -f "$artifact_file" ]; then
  echo "expected self-improve run artifact to be written" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.detected,
      .counts.generated,
      .counts.submitted,
      .counts.skipped,
      .gating.dominant_reason,
      .gating.submission_reason,
      .gating.active_self_improve_count,
      .gating.active_self_improve_cap,
      .gating.overload.active,
      (.gating.overload.candidates | length)
    ] | @tsv
  ' "$artifact_file"
)"

if [ "$artifact_summary" != $'2\t2\t1\t1\tsubmission_limit\tcritical_low_success_rate\t0\t3\tfalse\t0' ]; then
  echo "unexpected self-improve artifact summary: $artifact_summary" >&2
  exit 1
fi

overload_summary="$(
  jq -r '
    [
      .gating.overload.active,
      .gating.overload.preserved_title,
      .gating.overload.preserved_reason,
      .gating.overload.candidate_count,
      .gating.overload.blocked_candidate_count
    ] | @tsv
  ' "$artifact_file"
)"

if [ "$overload_summary" != $'false\t\tinactive\t0\t0' ]; then
  echo "unexpected self-improve overload summary: $overload_summary" >&2
  exit 1
fi

automation_memory_summary="$(
  jq -r '
    [
      .automation_memory.automation_id,
      .automation_memory.source,
      .automation_memory.external_hydrated,
      .automation_memory.external_sync_pending,
      .automation_memory.readable,
      .automation_memory.continuity_status
    ] | @tsv
  ' "$artifact_file"
)"

if [ "$automation_memory_summary" != $'push2main-codex-agent-system\texternal\ttrue\tfalse\ttrue\thydrated_external' ]; then
  echo "unexpected automation memory artifact summary: $automation_memory_summary" >&2
  exit 1
fi

metrics_input_summary="$(
  jq -r '
    [
      .metrics_input.status,
      .metrics_input.refresh_performed,
      .metrics_input.reason,
      (.metrics_input.missing_keys | join(","))
    ] | @tsv
  ' "$artifact_file"
)"

if [ "$metrics_input_summary" != $'complete\tfalse\tcomplete_snapshot\t' ]; then
  echo "unexpected metrics input artifact summary: $metrics_input_summary" >&2
  exit 1
fi

selection_summary="$(
  jq -r '
    [
      .selected_improvement,
      .selection.selected_title,
      .selection.state,
      (.selection.submitted_titles | join(",")),
      (.selection.ranked_titles | length)
    ] | @tsv
  ' "$artifact_file"
)"

if [ "$selection_summary" != $'Reduce timeout rate\tReduce timeout rate\tsubmitted\tReduce timeout rate\t2' ]; then
  echo "unexpected self-improve selection summary: $selection_summary" >&2
  exit 1
fi

echo "self improve run artifact test passed"
