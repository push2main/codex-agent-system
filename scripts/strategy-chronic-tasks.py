"""Strategy loop: mark chronically failing tasks as permanently failed.

Extracted from strategy-loop.sh inline heredoc (iteration 20 fix) to avoid
macOS bash 3.2 parsing bug with <<'MARKER' inside $() command substitutions.

Usage: python3 scripts/strategy-chronic-tasks.py REGISTRY_FILE
"""
import json, sys, os, tempfile
from pathlib import Path
from datetime import datetime, timezone

registry_path = Path(sys.argv[1])
try:
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

tasks = registry.get("tasks", [])
changed = False

for task in tasks:
    status = str(task.get("status", "")).strip().lower()
    if status not in ("approved", "queued"):
        continue
    # Fix: read attempts from execution.attempt (actual counter), fall back to top-level
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    attempts = max(
        int(execution.get("attempt") or 0),
        int(task.get("attempts") or 0),
    )
    # Fix: read failure_kind from execution.failure_kind OR top-level last_failure_kind
    last_failure = str(
        execution.get("failure_kind")
        or task.get("last_failure_kind")
        or ""
    ).strip()
    # 3+ attempts and a persistent/non-retriable failure kind -> mark permanently failed
    chronic_kinds = {"missing_environment", "missing_build_tool", "missing_platform",
                     "sandbox_restriction", "auth_failure", "missing_config",
                     "unknown_persistent", "vague_specification", "stale_task_timeout"}
    if attempts >= 3 or last_failure in chronic_kinds:
        if last_failure in chronic_kinds or attempts >= 4:
            task["status"] = "failed"
            task["status_reason"] = f"Chronic failure after {attempts} attempts: {last_failure}"
            task["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            changed = True

if changed:
    tmp = tempfile.NamedTemporaryFile(mode="w", dir=registry_path.parent,
                                       suffix=".tmp", delete=False)
    json.dump(registry, tmp, indent=2)
    tmp.close()
    os.replace(tmp.name, str(registry_path))
    print(f"Marked chronically failing tasks as permanently failed")
