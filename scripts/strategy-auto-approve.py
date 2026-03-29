"""Strategy loop: unconditional auto-approval of stale pipeline tasks.

Extracted from strategy-loop.sh inline heredoc (iteration 20 fix) to avoid
macOS bash 3.2 parsing bug with <<'MARKER' inside $() command substitutions.

Usage: python3 scripts/strategy-auto-approve.py REGISTRY_FILE METRICS_FILE [TASK_LOG]
"""
import json, sys, os, tempfile
from pathlib import Path
from datetime import datetime, timedelta, timezone

registry_path = Path(sys.argv[1])
metrics_path = Path(sys.argv[2])
task_log_path = Path(sys.argv[3]) if len(sys.argv) > 3 and str(sys.argv[3]).strip() else registry_path.with_name("tasks.log")
ZOMBIE_FAILURE_THRESHOLD = 5
try:
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

tasks = registry.get("tasks", [])


def normalize_text(value: object) -> str:
    return " ".join(str(value or "").strip().lower().split())


def normalize_project(value: object) -> str:
    return "-".join(filter(None, "".join(ch if ch.isalnum() or ch in "_-" else "-" for ch in str(value or "").strip().lower()).split("-")))


def task_execution_text(task: dict) -> str:
    execution_brief = task.get("execution_brief") if isinstance(task.get("execution_brief"), dict) else {}
    return str(execution_brief.get("queue_task") or task.get("execution_task") or task.get("title") or "").strip()


def normalize_provider(value: object) -> str:
    provider = normalize_text(value)
    return provider if provider in ("codex", "claude") else ""


def task_execution_provider(task: dict) -> str:
    provider_selection = task.get("provider_selection") if isinstance(task.get("provider_selection"), dict) else {}
    return normalize_provider(
        task.get("execution_provider")
        or provider_selection.get("selected")
        or ((task.get("execution") if isinstance(task.get("execution"), dict) else {}).get("provider"))
    )


def normalize_task_intent(task: dict, queue_task: str, project: str) -> dict | None:
    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    normalized = {
        "source": str(task_intent.get("source") or "strategy_followup").strip(),
        "objective": str(task_intent.get("objective") or queue_task).strip(),
        "project": normalize_project(task_intent.get("project") or project or "codex-agent-system"),
        "category": normalize_text(task_intent.get("category") or task.get("category") or "code_quality"),
        "context_hint": str(task_intent.get("context_hint") or "").strip(),
        "constraints": list(task_intent.get("constraints")) if isinstance(task_intent.get("constraints"), list) else [],
        "success_signals": list(task_intent.get("success_signals")) if isinstance(task_intent.get("success_signals"), list) else [],
        "affected_files": list(task_intent.get("affected_files")) if isinstance(task_intent.get("affected_files"), list) else [],
    }
    return normalized if any((normalized["source"], normalized["objective"], normalized["context_hint"], normalized["constraints"], normalized["success_signals"], normalized["affected_files"])) else None


def append_queue_task(project: str, queue_task: str) -> str:
    root_dir = registry_path.parent.parent
    queues_dir = root_dir / "queues"
    queues_dir.mkdir(parents=True, exist_ok=True)
    queue_file = queues_dir / f"{normalize_project(project or 'codex-agent-system')}.txt"
    existing_lines = []
    if queue_file.exists():
        existing_lines = [line.strip() for line in queue_file.read_text(encoding="utf-8").splitlines() if line.strip()]
    if queue_task in existing_lines:
        return "already_queued"
    with queue_file.open("a", encoding="utf-8") as handle:
        handle.write(f"{queue_task}\n")
    return "queued"


def build_approval_execution_snapshot(*, approved_at: str, project: str, queue_task: str, provider: str, queue_status: str) -> dict:
    return {
        "approved_at": approved_at,
        "project": normalize_project(project or "codex-agent-system"),
        "queue_task": str(queue_task or "").strip(),
        "provider": normalize_provider(provider) or "codex",
        "queue_status": str(queue_status or "").strip(),
    }


def build_execution_brief(
    *,
    approved_at: str,
    project: str,
    queue_task: str,
    provider: str,
    queue_status: str,
    task_intent: dict | None,
    task_shape: dict | None,
) -> dict:
    normalized_task_intent = task_intent if isinstance(task_intent, dict) else None
    normalized_task_shape = task_shape if isinstance(task_shape, dict) else None

    def normalize_files(value: object) -> list[str]:
        if not isinstance(value, list):
            return []
        return [str(entry).strip() for entry in value if str(entry or "").strip()]

    editable_files = normalize_files((normalized_task_shape or {}).get("editable_files"))
    if not editable_files:
        editable_files = normalize_files((normalized_task_intent or {}).get("affected_files"))

    return {
        "approved_at": approved_at,
        "project": normalize_project(project or "codex-agent-system"),
        "queue_task": str(queue_task or "").strip(),
        "provider": normalize_provider(provider) or "codex",
        "queue_status": str(queue_status or "").strip(),
        "status": str(queue_status or "").strip(),
        "source": str((normalized_task_intent or {}).get("source") or "").strip(),
        "objective": str((normalized_task_intent or {}).get("objective") or queue_task or "").strip(),
        "category": str((normalized_task_intent or {}).get("category") or "").strip(),
        "context_hint": str((normalized_task_intent or {}).get("context_hint") or "").strip(),
        "constraints": list((normalized_task_intent or {}).get("constraints") or []),
        "success_signals": list((normalized_task_intent or {}).get("success_signals") or []),
        "editable_files": editable_files,
        "frozen_files": normalize_files((normalized_task_shape or {}).get("frozen_files")),
        "frozen_verify_command": str((normalized_task_shape or {}).get("verification_command") or "").strip(),
        "affected_files": list((normalized_task_intent or {}).get("affected_files") or []),
        "task_intent": normalized_task_intent,
    }


def stale_pipeline_auto_approvable(task: dict) -> bool:
    intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    if normalize_text(intent.get("source")) == "self-improve":
        return True

    strategy_template = normalize_text(task.get("strategy_template"))
    if strategy_template in {"self_improvement", "bounded_learning_inventory"}:
        return True

    for key in ("source_task_id", "root_source_task_id", "original_failed_root_id"):
        if normalize_text(task.get(key)) == "self-improve":
            return True

    return False


def stale_pipeline_auto_approve_threshold(task: dict, *, zero_queue: bool, stale_duration: float) -> int:
    if zero_queue:
        threshold = 600
    elif stale_duration > 43200:
        threshold = 3600
    else:
        threshold = 5400

    strategy_template = normalize_text(task.get("strategy_template"))
    title = normalize_text(task.get("title") or task_execution_text(task))
    if stale_duration > 43200 and (
        strategy_template == "bounded_learning_inventory"
        or title.startswith("inventory current decision path")
    ):
        return min(threshold, 60)

    return threshold


def read_task_log_failure_counts(path: Path) -> dict[tuple[str, str], int]:
    counts: dict[tuple[str, str], int] = {}
    if not path.exists():
        return counts
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return counts
    for raw_line in lines:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            record = json.loads(raw_line)
        except Exception:
            continue
        if not isinstance(record, dict):
            continue
        if normalize_text(record.get("result")) != "failure":
            continue
        project_key = normalize_project(record.get("project") or "codex-agent-system")
        task_key = normalize_text(record.get("task"))[:80]
        if not task_key:
            continue
        counts[(project_key, task_key)] = counts.get((project_key, task_key), 0) + 1
    return counts


task_log_failure_counts = read_task_log_failure_counts(task_log_path)

# Iteration 17 fix: Compute pipeline_stale INDEPENDENTLY from task log,
# not from metrics.json. The metrics file depends on strategy.sh completing
# successfully — if strategy.sh crashes, metrics never update pipeline_stale,
# creating a circular dependency where auto-approval can't fire because
# metrics say "not stale" while the pipeline IS stale.
pipeline_stale = metrics.get("pipeline_stale") is True
if not pipeline_stale and task_log_path and task_log_path.exists():
    try:
        lines = task_log_path.read_text(encoding="utf-8", errors="ignore").strip().splitlines()
        if not lines:
            pipeline_stale = True
        else:
            last_record = json.loads(lines[-1])
            # Iteration 18 fix: also fall back to "timestamp" field — many task log
            # entries only have this field, causing false pipeline_stale=True
            ts_str = (last_record.get("completed_at") or last_record.get("updated_at")
                      or last_record.get("created_at") or last_record.get("timestamp") or "")
            if not ts_str:
                pipeline_stale = True
            else:
                ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                pipeline_stale = (datetime.now(timezone.utc) - ts) > timedelta(hours=6)
    except Exception:
        pipeline_stale = True
# Check no approved/running work exists
has_active = any(
    isinstance(t, dict)
    and str(t.get("status", "")).strip().lower() in ("approved", "running", "queued")
    for t in tasks
)

# Iteration 21 fix (Problem 70): Auto-approve should also trigger when queue is
# completely empty (0 approved + 0 running + 0 queued), not just when pipeline is
# stale. This prevents the 6-hour dead zone where the system is idle but
# pipeline_stale hasn't fired yet. When nothing is running and nothing is queued,
# approving a pending task is always safe — it's the only way to make progress.
zero_queue = not has_active

if not pipeline_stale and not zero_queue:
    raise SystemExit(0)
if has_active:
    raise SystemExit(0)

# Determine threshold
stale_since_str = metrics.get("pipeline_stale_since", "")
stale_duration = 0
if stale_since_str:
    try:
        ts = datetime.fromisoformat(stale_since_str.replace("Z", "+00:00"))
        stale_duration = max((datetime.now(timezone.utc) - ts).total_seconds(), 0)
    except Exception:
        pass
# Find best auto-approvable candidate
candidates = []
now = datetime.now(timezone.utc)
for idx, task in enumerate(tasks):
    if not isinstance(task, dict):
        continue
    if str(task.get("status", "")).strip().lower() != "pending_approval":
        continue
    if not stale_pipeline_auto_approvable(task):
        continue
    task_key = normalize_text(task_execution_text(task))[:80]
    project_key = normalize_project(task.get("project") or "codex-agent-system")
    if task_log_failure_counts.get((project_key, task_key), 0) >= ZOMBIE_FAILURE_THRESHOLD:
        continue
    created_at_str = task.get("created_at", "")
    if not created_at_str:
        continue
    try:
        created_at = datetime.fromisoformat(created_at_str.replace("Z", "+00:00"))
    except Exception:
        continue
    age = max((now - created_at).total_seconds(), 0)
    threshold = stale_pipeline_auto_approve_threshold(task, zero_queue=zero_queue, stale_duration=stale_duration)
    if age < threshold:
        continue
    score = 0.0
    try:
        score = float(task.get("score", 0))
    except (TypeError, ValueError):
        pass
    candidates.append((score, idx, task, age, threshold))

if not candidates:
    raise SystemExit(0)

candidates.sort(key=lambda x: (-x[0], x[1]))
_, best_idx, best_task, best_age, best_threshold = candidates[0]
transition_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
project = normalize_project(best_task.get("project") or "codex-agent-system")
queue_task = task_execution_text(best_task)
provider = task_execution_provider(best_task) or "codex"
normalized_task_intent = normalize_task_intent(best_task, queue_task, project)
queue_status = append_queue_task(project, queue_task)
best_task["status"] = "approved"
best_task["updated_at"] = transition_at
best_task["approved_at"] = transition_at
best_task["project"] = project
best_task["execution_provider"] = provider
if normalized_task_intent is not None:
    best_task["task_intent"] = normalized_task_intent
best_task["approval_execution_brief"] = build_approval_execution_snapshot(
    approved_at=transition_at,
    project=project,
    queue_task=queue_task,
    provider=provider,
    queue_status=queue_status,
)
best_task["execution_brief"] = build_execution_brief(
    approved_at=transition_at,
    project=project,
    queue_task=queue_task,
    provider=provider,
    queue_status=queue_status,
    task_intent=normalized_task_intent,
    task_shape=(best_task.get("task_shape") if isinstance(best_task.get("task_shape"), dict) else None),
)
best_task["queue_handoff"] = {
    "at": transition_at,
    "project": project,
    "task": queue_task,
    "status": queue_status,
    "provider": provider,
    **({"task_intent": normalized_task_intent} if normalized_task_intent is not None else {}),
}
if isinstance(best_task.get("execution"), dict):
    best_task["execution"]["state"] = "approved"
    best_task["execution"]["updated_at"] = transition_at
history = best_task.get("history") if isinstance(best_task.get("history"), list) else []
history.append({
    "at": transition_at,
    "action": "auto_approve_stale_pipeline",
    "from_status": "pending_approval",
    "to_status": "approved",
    "project": project,
    "queue_task": queue_task,
    "note": f"Auto-approved by strategy-loop unconditional path (iteration 16). threshold={int(best_threshold)}s, stale={int(stale_duration)}s, age={int(best_age)}s, score={best_task.get('score')}.",
})
best_task["history"] = history

tmp = tempfile.NamedTemporaryFile(mode="w", dir=registry_path.parent, suffix=".tmp", delete=False)
json.dump(registry, tmp, indent=2)
tmp.close()
os.replace(tmp.name, str(registry_path))
print(f"AUTO_APPROVED:{best_task.get('title')}|score={best_task.get('score')}|age={int(best_age)}s")
