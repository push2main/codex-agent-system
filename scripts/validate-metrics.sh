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
import json, re, sys
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

# v12 fix: Also validate payload_bytes and learning_rules_count — these drift
# during idle periods and were the #1 recurring audit finding across v6-v11.
import os as _os
# v15 fix: Count rules from BOTH rules.md AND prompt-rules.md (union with dedup)
# Previous versions only counted rules.md, causing false drift detection (audits v6-v13).
# task_metrics.py:unique_markdown_bullet_rules() counts the union — validate must match.
rules_files = [
    Path('$ROOT_DIR') / 'codex-learning' / 'rules.md',
    Path('$ROOT_DIR') / 'codex-learning' / 'prompt-rules.md',
]
try:
    all_rules = set()
    for rf in rules_files:
        if rf.is_file():
            for line in rf.read_text(encoding='utf-8').splitlines():
                stripped = line.strip()
                if stripped.startswith('-'):
                    # Normalize for dedup: strip leading '- ' and collapse whitespace
                    rule_text = re.sub(r'\s+', ' ', stripped.lstrip('-').strip())
                    if rule_text:
                        all_rules.add(rule_text)
    rules_count = len(all_rules) if all_rules else None
except Exception:
    rules_count = None

# Compute actual registry payload bytes from all discovered registry files
# v18 fix: Detect sandbox environment where cross-project registries are unreachable.
# When discovered registries < expected (metrics already tracks cross-project totals),
# only correct LOCAL metrics (local_registry_bytes, local task counts) — never
# overwrite cross-project totals (task_registry_total, shared_registry_bytes,
# task_registry_payload_bytes) with partial data.
discovered_targets = discover_registry_targets('$REGISTRY_FILE')
discovered_count = sum(1 for t in discovered_targets if Path(t['resolved_path']).is_file())
expected_cross_project_count = metrics.get('task_registry_total', 0) - len(local_tasks)
sandbox_mode = discovered_count == 1 and expected_cross_project_count > 0

actual_payload_bytes = 0
local_payload_bytes = 0
for target in discovered_targets:
    try:
        size = _os.path.getsize(target['resolved_path'])
        actual_payload_bytes += size
        if Path(target['resolved_path']).resolve() == Path('$REGISTRY_FILE').resolve():
            local_payload_bytes = size
    except Exception:
        pass

if rules_count is not None and metrics.get('learning_rules_count') != rules_count:
    actual['learning_rules_count'] = rules_count

if sandbox_mode:
    # Sandbox: only correct local_registry_bytes and local task counts
    if local_payload_bytes > 0 and abs(metrics.get('local_registry_bytes', 0) - local_payload_bytes) > 1024:
        actual['local_registry_bytes'] = local_payload_bytes
    # Do NOT touch task_registry_total, shared_registry_bytes, or payload_bytes —
    # these are cross-project sums and we can't verify the remote registries.
    actual.pop('task_registry_total', None)
    print(f'[validate-metrics] SANDBOX MODE: only {discovered_count} registry found, skipping cross-project corrections')
elif actual_payload_bytes > 0:
    for key in ('task_registry_payload_bytes', 'task_registry_pressure_bytes', 'shared_registry_bytes'):
        if abs(metrics.get(key, 0) - actual_payload_bytes) > 1024:  # only fix if > 1KB drift
            actual[key] = actual_payload_bytes
    if local_payload_bytes > 0 and abs(metrics.get('local_registry_bytes', 0) - local_payload_bytes) > 1024:
        actual['local_registry_bytes'] = local_payload_bytes

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
