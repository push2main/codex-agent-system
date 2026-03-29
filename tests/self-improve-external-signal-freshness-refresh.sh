#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"
source "$ROOT_DIR/tests/lib/self-improve-fixture.sh"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$REPO_ROOT"
cp -R "$ROOT_DIR/scripts" "$REPO_ROOT/scripts"
mkdir -p "$REPO_ROOT/codex-memory" "$REPO_ROOT/codex-learning" "$REPO_ROOT/codex-logs" "$REPO_ROOT/queues"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

: >"$REPO_ROOT/codex-memory/tasks.log"

write_self_improve_metrics_fixture "$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "total_tasks": 0
}
EOF

cat >"$REPO_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "2026-03-20T12:00:00Z",
  "signals": [
    {
      "source_id": "fixture",
      "source_label": "Fixture releases",
      "title": "Old signal",
      "url": "https://example.com/releases/old",
      "published_at": "2026-03-20T12:00:00Z",
      "fresh": true
    }
  ],
  "errors": []
}
EOF

touch -t 202603201200 "$REPO_ROOT/codex-learning/metrics.json"
touch -t 202603201200 "$REPO_ROOT/codex-learning/external-signals.json"
touch -t 202603201200 "$REPO_ROOT/codex-memory/tasks.json"
touch -t 202603201200 "$REPO_ROOT/codex-memory/tasks.log"

(
  cd "$REPO_ROOT"
  CODEX_EXTERNAL_SIGNAL_NOW="2026-03-28T12:00:00Z" IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

artifact_summary="$(
  jq -r '
    [
      .metrics_input.status,
      .metrics_input.refresh_performed,
      .metrics_input.reason,
      .metrics_snapshot.external_signal_status,
      .metrics_snapshot.fresh_external_signal_count
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'refreshed\ttrue\tstale_against_external_signal_freshness\tstale\t0' ]; then
  echo "unexpected self-improve artifact after external-signal freshness refresh: $artifact_summary" >&2
  exit 1
fi

metrics_summary="$(
  jq -r '
    [
      .external_signal_status,
      .fresh_external_signal_count
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/metrics.json"
)"
if [ "$metrics_summary" != $'stale\t0' ]; then
  echo "expected self-improve to refresh external-signal freshness drift: $metrics_summary" >&2
  exit 1
fi

echo "self improve external signal freshness refresh test passed"
