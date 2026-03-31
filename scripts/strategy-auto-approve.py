"""Strategy loop: unconditional auto-approval of stale pipeline tasks.

Extracted from strategy-loop.sh inline heredoc (iteration 20 fix) to avoid
macOS bash 3.2 parsing bug with <<'MARKER' inside $() command substitutions.

Usage: python3 scripts/strategy-auto-approve.py REGISTRY_FILE METRICS_FILE [TASK_LOG]
"""
import json, sys, os, tempfile, re, shlex
from pathlib import Path
from datetime import datetime, timedelta, timezone

REPO_ROOT = Path(__file__).resolve().parent.parent
registry_path = Path(sys.argv[1])
metrics_path = Path(sys.argv[2])
task_log_path = Path(sys.argv[3]) if len(sys.argv) > 3 and str(sys.argv[3]).strip() else registry_path.with_name("tasks.log")
projects_dir = REPO_ROOT / "projects"
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


def normalize_improvement_title(value: object) -> str:
    text = normalize_text(value)
    if text.startswith("[self-improve:") and "]" in text:
        text = text.split("]", 1)[1].strip()
    if " (files:" in text:
        text = text.split(" (files:", 1)[0].strip()
    if " -- " in text:
        text = text.split(" -- ", 1)[0].strip()
    return text


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
    queues_dir = REPO_ROOT / "queues"
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


def read_project_workspace(project: str) -> Path | None:
    metadata_path = projects_dir / project / "project.json"
    try:
        payload = json.loads(metadata_path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    workspace = str(payload.get("workspace") or "").strip()
    if not workspace:
        return None
    try:
        return Path(workspace).resolve()
    except Exception:
        return None


def read_project_spec_path(project: str) -> Path | None:
    metadata_path = projects_dir / project / "project.json"
    default_path = projects_dir / project / "spec.md"
    try:
        payload = json.loads(metadata_path.read_text(encoding="utf-8"))
    except Exception:
        payload = {}
    if isinstance(payload, dict):
        spec_file = str(payload.get("spec_file") or "").strip()
        if spec_file:
            try:
                candidate = Path(spec_file)
                if not candidate.is_absolute():
                    candidate = (REPO_ROOT / candidate).resolve()
                else:
                    candidate = candidate.resolve()
                return candidate
            except Exception:
                pass
    return default_path if default_path.is_file() else None


def extract_spec_milestone_seed_block(spec_text: str) -> str | None:
    import re

    match = re.search(
        r"(?ms)^## Milestone Seeds\s*\n```json\s*\n(.*?)\n```\s*(?=^## |\Z)",
        spec_text,
    )
    if not match:
        return None
    payload = str(match.group(1) or "").strip()
    return payload or None


def parse_project_spec_milestone_seeds(project: str) -> list[dict]:
    spec_path = read_project_spec_path(project)
    if spec_path is None or not spec_path.is_file():
        return []
    try:
        payload = extract_spec_milestone_seed_block(spec_path.read_text(encoding="utf-8"))
    except Exception:
        return []
    if not payload:
        return []
    try:
        decoded = json.loads(payload)
    except Exception:
        return []
    if isinstance(decoded, dict):
        decoded = decoded.get("seeds")
    if not isinstance(decoded, list):
        return []
    return [item for item in decoded if isinstance(item, dict)]


def seed_string_list(value: object) -> list[str]:
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item or "").strip()]
    text = str(value or "").strip()
    return [text] if text else []


def resolve_workspace_seed_file(workspace: Path, candidate: object) -> Path | None:
    relative_path = str(candidate or "").strip()
    if not relative_path:
        return None
    path = Path(relative_path)
    resolved = path.resolve() if path.is_absolute() else (workspace / path).resolve()
    try:
        resolved.relative_to(workspace)
    except Exception:
        return None
    return resolved if resolved.is_file() else None


def external_structured_seed_resolved_reason(task: dict, project: str) -> str:
    if not project or project == "codex-agent-system":
        return ""
    if normalize_text(task.get("status")) not in {"pending_approval", "failed"}:
        return ""
    workspace = read_project_workspace(project)
    if workspace is None:
        return ""
    title_key = normalize_improvement_title(task.get("title") or task_execution_text(task))
    if not title_key:
        return ""
    for seed in parse_project_spec_milestone_seeds(project):
        if normalize_improvement_title(seed.get("title") or "") != title_key:
            continue
        done_markers = seed_string_list(seed.get("done_markers"))
        target_path = resolve_workspace_seed_file(workspace, seed.get("target_file"))
        if target_path is None or not done_markers:
            continue
        try:
            target_text = target_path.read_text(encoding="utf-8")
        except Exception:
            continue
        normalized_target_text = normalize_text(target_text)
        if all(normalize_text(marker) in normalized_target_text for marker in done_markers):
            return f"structured spec seed markers already present in {target_path.relative_to(workspace).as_posix()}"
    return ""


def task_combined_lower(task: dict) -> str:
    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    parts: list[str] = [
        str(task.get("title") or "").strip(),
        str(task.get("reason") or "").strip(),
        str(task_execution_text(task) or "").strip(),
        str(task_intent.get("objective") or "").strip(),
        str(task_intent.get("context_hint") or "").strip(),
    ]
    constraints = task_intent.get("constraints")
    if isinstance(constraints, list):
        parts.extend(str(entry).strip() for entry in constraints if str(entry or "").strip())
    success_signals = task_intent.get("success_signals")
    if isinstance(success_signals, list):
        parts.extend(str(entry).strip() for entry in success_signals if str(entry or "").strip())
    return normalize_text(" ".join(part for part in parts if part)).lower()


def default_verification_command_for_external_task(task: dict, project: str) -> str:
    if not project or project == "codex-agent-system":
        return ""
    workspace = read_project_workspace(project)
    if workspace is None:
        return ""
    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    category = normalize_text(task.get("category") or task_intent.get("category") or "code_quality")
    combined_lower = task_combined_lower(task)
    normalized_hints = [normalize_text(path).lower() for path in task_file_hints(task)]
    smoke_verify_command = "node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing"
    smoke_script = workspace / "apps" / "cloud-brain" / "scripts" / "smoke.mjs"
    if smoke_script.is_file():
        smoke_related_paths = (
            "apps/cloud-brain/scripts/smoke.mjs",
            "apps/cloud-brain/src/incident-flow.mjs",
            "packages/playbooks/account_recovery_after_credential_risk.json",
        )
        if any(
            hint.endswith(candidate)
            for hint in normalized_hints
            for candidate in smoke_related_paths
        ) or re.search(r"\b(smoke flow|credential recovery|dashboard incident payload)\b", combined_lower):
            return smoke_verify_command
    baseline_verify = workspace / "scripts" / "verify-baseline.sh"
    if any(hint.endswith("scripts/verify-baseline.sh") for hint in normalized_hints) or "verify-baseline.sh" in combined_lower:
        if baseline_verify.is_file():
            return "bash scripts/verify-baseline.sh"
    is_ui_like = (
        category == "ui"
        or re.search(r"\b(dashboard|ui|iphone|ipad|tablet|mobile|playwright|screenshot)\b", combined_lower) is not None
    )
    if not is_ui_like:
        return ""
    playwright_script = workspace / "scripts" / "run-playwright-docker.sh"
    screenshot_test = workspace / "tests" / "dashboard-screenshot-verification.sh"
    if playwright_script.is_file() and screenshot_test.is_file():
        return "bash scripts/run-playwright-docker.sh bash tests/dashboard-screenshot-verification.sh"
    if baseline_verify.is_file():
        return "bash scripts/verify-baseline.sh"
    return ""


def command_path_candidates(command: str) -> list[str]:
    text = str(command or "").strip()
    if not text:
        return []
    try:
        tokens = shlex.split(text)
    except Exception:
        tokens = text.split()
    candidates: list[str] = []
    for token in tokens:
        value = str(token or "").strip()
        if not value:
            continue
        if value in {"bash", "sh", "node", "python", "python3", "env", "timeout", "gtimeout", "npm", "pnpm", "yarn", "npx"}:
            continue
        if value in {"&&", "||", "|", ";"}:
            continue
        if value.startswith("-"):
            continue
        if "=" in value and "/" not in value and value.count("=") == 1:
            continue
        if "/" in value or value.endswith((".sh", ".bash", ".js", ".mjs", ".py", ".json", ".md")):
            candidates.append(value)
    return candidates


def command_missing_workspace_paths(command: str, workspace: Path) -> list[str]:
    missing: list[str] = []
    for raw_path in command_path_candidates(command):
        path = Path(raw_path)
        try:
            resolved = path.resolve() if path.is_absolute() else (workspace / path).resolve()
            resolved.relative_to(workspace)
        except Exception:
            continue
        if not resolved.exists():
            missing.append(raw_path)
    return missing


def repair_external_task_verification_command(task: dict, project: str) -> tuple[str, str]:
    if not project or project == "codex-agent-system":
        return "", ""
    if normalize_text(task.get("status")) not in {"pending_approval", "approved", "failed"}:
        return "", ""
    workspace = read_project_workspace(project)
    if workspace is None:
        return "", ""
    task_shape = task.get("task_shape") if isinstance(task.get("task_shape"), dict) else {}
    current_command = str(task_shape.get("verification_command") or "").strip()
    desired_command = default_verification_command_for_external_task(task, project)
    if not desired_command:
        return "", ""
    current_missing = command_missing_workspace_paths(current_command, workspace) if current_command else []
    if current_command == desired_command and not current_missing:
        return "", ""
    desired_missing = command_missing_workspace_paths(desired_command, workspace)
    if desired_missing:
        return "", ""
    if current_command and not current_missing:
        return "", ""
    if current_command:
        note = (
            "Replaced invalid external verification command "
            f"`{current_command}` with project-local `{desired_command}` after missing paths: {', '.join(current_missing)}."
        )
    else:
        note = f"Filled missing external verification command with project-local `{desired_command}`."
    return desired_command, note


def task_file_hints(task: dict) -> list[str]:
    hints: list[str] = []
    seen: set[str] = set()
    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    for candidate_list in (task_intent.get("affected_files"), task.get("target_files")):
        if not isinstance(candidate_list, list):
            continue
        for raw_value in candidate_list:
            value = str(raw_value or "").strip()
            key = normalize_text(value)
            if not value or not key or key in seen:
                continue
            hints.append(value)
            seen.add(key)
    return hints


def external_project_task_has_grounded_target(task: dict, project: str) -> bool:
    if not project or project == "codex-agent-system":
        return True
    workspace = read_project_workspace(project)
    if workspace is None:
        return True
    file_hints = task_file_hints(task)
    if not file_hints:
        return False
    for raw_path in file_hints:
        path = Path(raw_path)
        try:
            resolved = path.resolve() if path.is_absolute() else (workspace / path).resolve()
            resolved.relative_to(workspace)
        except Exception:
            continue
        if resolved.is_file():
            return True
    return False


def fast_zero_queue_external_self_improve_task(task: dict) -> bool:
    project = normalize_project(task.get("project") or "codex-agent-system")
    if not project or project == "codex-agent-system":
        return False
    if not stale_pipeline_auto_approvable(task):
        return False
    file_hints = task_file_hints(task)
    if len(file_hints) != 1:
        return False
    return external_project_task_has_grounded_target(task, project)


def stale_pipeline_auto_approve_threshold(task: dict, *, zero_queue: bool, stale_duration: float) -> int:
    if zero_queue:
        threshold = 600
    elif stale_duration > 43200:
        threshold = 3600
    else:
        threshold = 5400

    strategy_template = normalize_text(task.get("strategy_template"))
    title = normalize_text(task.get("title") or task_execution_text(task))
    if zero_queue and (
        strategy_template == "bounded_learning_inventory"
        or title.startswith("inventory current decision path")
    ):
        return min(threshold, 60)
    if stale_duration > 43200 and (
        strategy_template == "bounded_learning_inventory"
        or title.startswith("inventory current decision path")
    ):
        return min(threshold, 60)
    if zero_queue and fast_zero_queue_external_self_improve_task(task):
        return 0

    return threshold


def task_failure_kind(task: dict) -> str:
    execution = task.get("execution") if isinstance(task.get("execution"), dict) else {}
    execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}
    failure_context = task.get("failure_context") if isinstance(task.get("failure_context"), dict) else {}
    return normalize_text(
        task.get("last_failure_kind")
        or execution.get("failure_kind")
        or failure_context.get("failure_kind")
        or execution_context.get("failure_kind")
    )


def task_has_history_action(task: dict, action: str) -> bool:
    history = task.get("history") if isinstance(task.get("history"), list) else []
    target = normalize_text(action)
    return any(
        isinstance(entry, dict)
        and normalize_text(entry.get("action")) == target
        for entry in history
    )


def history_action_count(task: dict, action: str) -> int:
    history = task.get("history") if isinstance(task.get("history"), list) else []
    target = normalize_text(action)
    count = 0
    for entry in history:
        if not isinstance(entry, dict):
            continue
        if normalize_text(entry.get("action")) == target:
            count += 1
    return count


def grounded_missing_source_requeueable(task: dict, *, project: str) -> bool:
    if str(task.get("status", "")).strip().lower() != "failed":
        return False
    if task_failure_kind(task) != "missing_source_file":
        return False
    strategy_template = normalize_text(task.get("strategy_template"))
    title = normalize_text(task.get("title") or task_execution_text(task))
    if strategy_template != "bounded_learning_inventory" and not title.startswith("inventory current decision path"):
        return False
    if history_action_count(task, "auto_requeue_grounded_missing_source") >= 3:
        return False
    if not external_project_task_has_grounded_target(task, project):
        return False
    return True


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


def write_registry() -> None:
    tmp = tempfile.NamedTemporaryFile(mode="w", dir=registry_path.parent, suffix=".tmp", delete=False)
    json.dump(registry, tmp, indent=2)
    tmp.close()
    os.replace(tmp.name, str(registry_path))


registry_changed = False
for task in tasks:
    if not isinstance(task, dict):
        continue
    project_key = normalize_project(task.get("project") or "codex-agent-system")
    repaired_command, repair_note = repair_external_task_verification_command(task, project_key)
    if repaired_command:
        transition_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        status = str(task.get("status") or "").strip().lower()
        task_shape = task.get("task_shape") if isinstance(task.get("task_shape"), dict) else {}
        task_shape["verification_command"] = repaired_command
        task_shape["updated_at"] = transition_at
        task["task_shape"] = task_shape
        execution_brief = task.get("execution_brief") if isinstance(task.get("execution_brief"), dict) else None
        if execution_brief is not None:
            execution_brief["frozen_verify_command"] = repaired_command
            task["execution_brief"] = execution_brief
        task["updated_at"] = transition_at
        history = task.get("history") if isinstance(task.get("history"), list) else []
        history.append({
            "at": transition_at,
            "action": "auto_repair_verification_command",
            "from_status": status,
            "to_status": status,
            "project": project_key,
            "queue_task": task_execution_text(task),
            "note": repair_note,
        })
        task["history"] = history
        registry_changed = True
    resolved_reason = external_structured_seed_resolved_reason(task, project_key)
    if not resolved_reason:
        continue
    transition_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    from_status = str(task.get("status") or "").strip().lower() or "pending_approval"
    task["status"] = "shelved"
    task["updated_at"] = transition_at
    task["shelved_reason"] = f"auto-shelved: {resolved_reason}"
    if isinstance(task.get("execution"), dict):
        task["execution"]["state"] = "shelved"
        task["execution"]["updated_at"] = transition_at
    history = task.get("history") if isinstance(task.get("history"), list) else []
    history.append({
        "at": transition_at,
        "action": "auto_shelve",
        "from_status": from_status,
        "to_status": "shelved",
        "project": project_key,
        "queue_task": task_execution_text(task),
        "note": (
            "Task was automatically retired because the structured external project seed is already satisfied: "
            f"{resolved_reason}."
        ),
    })
    task["history"] = history
    registry_changed = True

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
    if registry_changed:
        write_registry()
    raise SystemExit(0)
if has_active:
    if registry_changed:
        write_registry()
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
    task_key = normalize_text(task_execution_text(task))[:80]
    project_key = normalize_project(task.get("project") or "codex-agent-system")
    if task_log_failure_counts.get((project_key, task_key), 0) >= ZOMBIE_FAILURE_THRESHOLD:
        continue

    status = str(task.get("status", "")).strip().lower()
    candidate_priority = 0
    created_at_str = ""
    threshold = 0

    if status == "pending_approval":
        if not stale_pipeline_auto_approvable(task):
            continue
        if not external_project_task_has_grounded_target(task, project_key):
            continue
        created_at_str = str(task.get("created_at", "")).strip()
        if not created_at_str:
            continue
        threshold = stale_pipeline_auto_approve_threshold(task, zero_queue=zero_queue, stale_duration=stale_duration)
        candidate_priority = 2
    elif grounded_missing_source_requeueable(task, project=project_key):
        created_at_str = (
            str(task.get("failed_at") or "").strip()
            or str(task.get("updated_at") or "").strip()
            or str(task.get("created_at") or "").strip()
        )
        if not created_at_str:
            continue
        threshold = min(
            stale_pipeline_auto_approve_threshold(task, zero_queue=zero_queue, stale_duration=stale_duration),
            60,
        )
        candidate_priority = 1
    else:
        continue

    try:
        created_at = datetime.fromisoformat(created_at_str.replace("Z", "+00:00"))
    except Exception:
        continue
    age = max((now - created_at).total_seconds(), 0)
    if age < threshold:
        continue
    score = 0.0
    try:
        score = float(task.get("score", 0))
    except (TypeError, ValueError):
        pass
    candidates.append((candidate_priority, score, idx, task, age, threshold))

if not candidates:
    if registry_changed:
        write_registry()
    raise SystemExit(0)

candidates.sort(key=lambda x: (-x[0], -x[1], x[2]))
best_priority, _, best_idx, best_task, best_age, best_threshold = candidates[0]
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
if best_priority == 1:
    history.append({
        "at": transition_at,
        "action": "auto_requeue_grounded_missing_source",
        "from_status": "failed",
        "to_status": "approved",
        "project": project,
        "queue_task": queue_task,
        "note": (
            "Auto-requeued by strategy-loop after a grounded missing_source_file failure. "
            f"threshold={int(best_threshold)}s, age={int(best_age)}s, score={best_task.get('score')}."
        ),
    })
else:
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

write_registry()
if best_priority == 1:
    print(f"AUTO_REQUEUED:{best_task.get('title')}|score={best_task.get('score')}|age={int(best_age)}s")
else:
    print(f"AUTO_APPROVED:{best_task.get('title')}|score={best_task.get('score')}|age={int(best_age)}s")
