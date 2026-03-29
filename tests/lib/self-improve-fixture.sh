#!/usr/bin/env bash

write_self_improve_metrics_fixture() {
  local output_path="${1:?output path required}"

  python3 - "$output_path" <<'PY'
import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
raw_overrides = sys.stdin.read().strip()
overrides = json.loads(raw_overrides) if raw_overrides else {}
if not isinstance(overrides, dict):
    raise SystemExit("self-improve metrics fixture overrides must be a JSON object")

payload = {
    "success_rate": 0.0,
    "recent_success_rate": 0.0,
    "timeout_failure_rate": 0.0,
    "first_pass_success_rate": 0.0,
    "approved_tasks": 0,
    "pending_approval_tasks": 0,
    "approved_backlog": 0,
    "queued_tasks": 0,
    "running_tasks": 0,
    "task_registry_total": 0,
    "retry_classification_coverage": 1.0,
    "retry_classified_count": 0,
    "retry_total_count": 0,
    "zero_step_timeout_rate": 0.0,
    "task_registry_payload_bytes": 128000,
    "task_registry_pressure_bytes": 128000,
    "task_registry_pressure_detected": False,
    "strategy_saturation": False,
    "strategy_saturation_detected": False,
    "retry_churn_detected": False,
    "self_improve_paused": False,
    "self_improve_pause_escalated": False,
    "self_improve_pause_age_seconds": 0,
    "external_signal_status": "fresh",
    "fresh_external_signal_count": 1,
    "latest_external_signal_source": "Fixture releases",
    "total_tasks": 0,
}
payload.update(overrides)

output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}
