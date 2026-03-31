#!/usr/bin/env bash
# validate-metrics.sh — Pre-dispatch metrics validation guard
#
# Ensures metrics.json is consistent with actual task registry state.
# Designed to be called from memory-sync.sh, self-improve.sh, or queue-worker.sh
# BEFORE they read metrics.json.
#
# Fixes the recurring metrics drift problem (3+ consecutive sync cycles).
# If drift is detected, recomputes the drifted fields inline (fast path)
# without needing a full task_metrics.py run.

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

METRICS_FILE="${METRICS_FILE:-$ROOT_DIR/codex-learning/metrics.json}"
REGISTRY_FILE="${REGISTRY_FILE:-$ROOT_DIR/codex-memory/tasks.json}"

if [ ! -f "$METRICS_FILE" ] || [ ! -f "$REGISTRY_FILE" ]; then
  echo "[validate-metrics] SKIP: metrics.json or tasks.json missing" >&2
  exit 0
fi

# Fast validation: compare key counts between metrics and registry
python3 -c "
import json, sys
from pathlib import Path

scripts_dir = Path('$ROOT_DIR') / 'scripts'
if str(scripts_dir) not in sys.path:
    sys.path.insert(0, str(scripts_dir))

try:
    from task_metrics import build_persisted_board_health_signals
except Exception:
    build_persisted_board_health_signals = None

def normalize_project_name(value):
    text = str(value or '').strip()
    return text or 'codex-agent-system'

def discover_registry_targets(primary_registry_path):
    primary_path = Path(primary_registry_path).resolve()
    repo_root = primary_path.parent.parent
    projects_dir = repo_root / 'projects'
    registry_targets = []
    seen = set()

    def append_target(project, candidate):
        resolved = str(Path(candidate).resolve())
        if resolved in seen:
            return
        seen.add(resolved)
        registry_targets.append({
            'project': normalize_project_name(project),
            'resolved_path': resolved,
        })

    if projects_dir.is_dir():
        for entry in sorted(projects_dir.iterdir(), key=lambda item: item.name):
            if not entry.is_dir():
                continue
            metadata_path = entry / 'project.json'
            try:
                metadata = json.loads(metadata_path.read_text(encoding='utf-8'))
            except Exception:
                metadata = {}
            if not isinstance(metadata, dict):
                metadata = {}
            registry_candidate = Path(str(metadata.get('task_registry_file') or '').strip() or str(primary_path))
            project_name = metadata.get('project') or metadata.get('project_id') or entry.name
            append_target(project_name, registry_candidate)

    append_target('codex-agent-system', primary_path)
    return registry_targets


def read_registry_tasks(registry_targets, primary_registry_path):
    primary_path = Path(primary_registry_path).resolve()
    tasks = []
    for target in registry_targets:
        try:
            registry = json.loads(Path(target['resolved_path']).read_text(encoding='utf-8'))
        except Exception:
            continue
        if not isinstance(registry, dict):
            continue
        registry_tasks = registry.get('tasks', [])
        if not isinstance(registry_tasks, list):
            continue
        is_cross_project = Path(target['resolved_path']).resolve() != primary_path
        for task in registry_tasks:
            if not isinstance(task, dict):
                continue
            task_record = dict(task)
            if is_cross_project:
                task_record['_cross_project'] = True
                task_record['_source_project'] = normalize_project_name(target.get('project'))
            tasks.append(task_record)
    return tasks

with open('$METRICS_FILE') as f:
    metrics = json.load(f)

tasks = read_registry_tasks(discover_registry_targets('$REGISTRY_FILE'), '$REGISTRY_FILE')
local_tasks = [task for task in tasks if not task.get('_cross_project')]

actual = {
    'task_registry_total': len(tasks),
    'approved_tasks': len([t for t in local_tasks if t.get('status') == 'approved']),
    'approved_backlog': len([t for t in local_tasks if t.get('status') == 'approved']),
    'pending_approval_tasks': len([t for t in local_tasks if t.get('status') == 'pending_approval']),
    'queued_tasks': len([t for t in local_tasks if t.get('status') == 'queued']),
    'running_tasks': len([t for t in local_tasks if t.get('status') == 'running']),
}

drifted = {k: (metrics.get(k), v) for k, v in actual.items() if metrics.get(k) != v}
if build_persisted_board_health_signals is not None:
    board_health = build_persisted_board_health_signals(tasks)
else:
    pending_approval_count = len([t for t in tasks if t.get('status') == 'pending_approval'])
    executable_backlog_count = len([t for t in tasks if t.get('status') in {'approved', 'running'}])
    active_execution_count = len([
        t for t in tasks
        if isinstance(t.get('execution'), dict) and t.get('execution', {}).get('state') in {'running', 'retrying'}
    ])
    board_health = {
        'retry_churn_detected': bool(metrics.get('retry_churn_detected')),
        'queue_starvation_detected': executable_backlog_count > 0 and active_execution_count == 0,
        'pending_approval_blocked_detected': (
            pending_approval_count > 0 and executable_backlog_count == 0 and active_execution_count == 0
        ),
    }

board_health_drift = {
    field: (bool(metrics.get(field)), bool(board_health.get(field)))
    for field in ('retry_churn_detected', 'queue_starvation_detected', 'pending_approval_blocked_detected')
    if bool(metrics.get(field)) != bool(board_health.get(field))
}

if not drifted and not board_health_drift:
    print('[validate-metrics] OK: metrics match registry')
    sys.exit(0)

print('[validate-metrics] DRIFT DETECTED — correcting:')
for k, (old, new) in drifted.items():
    print(f'  {k}: {old} -> {new}')
    metrics[k] = new

# Also clear false alert flags that depend on drifted counts
if actual['approved_tasks'] == 0 and metrics.get('approved_backlog', 0) > 0:
    metrics['approved_backlog'] = 0
    print('  approved_backlog: forced to 0 (no approved tasks)')

for field in ('retry_churn_detected', 'queue_starvation_detected', 'pending_approval_blocked_detected'):
    expected = bool(board_health.get(field))
    current = bool(metrics.get(field))
    if current != expected:
        print(f'  {field}: {current} -> {expected} (aligned to persisted board health)')
        metrics[field] = expected

with open('$METRICS_FILE', 'w') as f:
    json.dump(metrics, f, indent=2)
    f.write('\n')

print('[validate-metrics] Corrected and saved.')
"
