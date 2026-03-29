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

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.41,
  "first_pass_success_rate": 0.55,
  "timeout_failure_rate": 0.12,
  "approved_tasks": 1,
  "approved_backlog": 1,
  "pending_approval_tasks": 2,
  "task_registry_payload_bytes": 93000,
  "task_registry_pressure_bytes": 93000,
  "task_registry_pressure_sources": [
    {
      "project": "superheld",
      "file": "/tmp/superheld/.codex-agent/tasks.json",
      "payload_bytes": 61000
    },
    {
      "project": "codex-agent-system",
      "file": "/tmp/codex-agent-system/codex-memory/tasks.json",
      "payload_bytes": 32000
    }
  ],
  "strategy_saturation": false,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "recent_success_rate": 0.48,
  "total_tasks": 37
}
EOF

cat >"$REPO_ROOT/codex-learning/self-improve-run.json" <<'EOF'
{
  "status": "success",
  "project": "codex-agent-system",
  "generated_at": "2026-03-25T01:15:00Z",
  "counts": {
    "detected": 1,
    "generated": 1,
    "submitted": 1,
    "skipped": 0,
    "blocked_analysis": 0
  },
  "gating": {
    "dominant_reason": "low_success_rate",
    "analysis_reason": "low_success_rate",
    "submission_reason": "low_success_rate",
    "backlog_gate_active": false,
    "overload": {
      "active": false,
      "preserved_title": "",
      "preserved_reason": "inactive",
      "candidate_count": 0,
      "blocked_candidate_count": 0,
      "candidates": []
    }
  },
  "metrics_snapshot": {
    "success_rate": 0.15
  }
}
EOF

date +%s >"$REPO_ROOT/codex-logs/self-improve-codex-agent-system-cooldown"

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=3600 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

artifact_file="$REPO_ROOT/codex-learning/self-improve-run.json"
if [ ! -f "$artifact_file" ]; then
  echo "expected cooldown path to keep writing self-improve artifact" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .status,
      .counts.generated,
      .counts.submitted,
      .counts.skipped,
      .gating.dominant_reason,
      .gating.submission_reason,
      .metrics_input.status,
      .metrics_input.reason,
      .metrics_snapshot.success_rate,
      .metrics_snapshot.backlog,
      .metrics_snapshot.registry_pressure_scope,
      .metrics_snapshot.local_registry_bytes,
      (.metrics_snapshot.registry_pressure_dominant_source.project // "")
    ] | @tsv
  ' "$artifact_file"
)"

if [ "$artifact_summary" != $'success\t0\t0\t0\tcooldown_active\tcooldown_active\tcomplete\tcomplete_snapshot\t0.41\t3\tnone\t32000\tsuperheld' ]; then
  echo "unexpected cooldown artifact summary: $artifact_summary" >&2
  exit 1
fi

generated_at="$(
  jq -r '.generated_at' "$artifact_file"
)"
if [ "$generated_at" = "2026-03-25T01:15:00Z" ] || [ -z "$generated_at" ] || [ "$generated_at" = "null" ]; then
  echo "expected cooldown path to refresh generated_at, got: $generated_at" >&2
  exit 1
fi

echo "self improve cooldown artifact test passed"
