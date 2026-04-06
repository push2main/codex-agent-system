#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap learner

PROJECT_DIR="${1:-$ROOT_DIR}"
TASK="${2:-}"
RESULT="${3:-UNKNOWN}"
RUN_DIR="${4:-$RUNS_DIR}"
RULES_OUTPUT_FILE="${5:-$PROMPT_RULES_FILE}"
OUTPUT_FILE="${6:-$LOG_DIR/learner-latest.json}"
RAW_RULES_FILE="$RUN_DIR/learner-rules.txt"
TARGET_PROJECT_NAME="${PROJECT_NAME:-$(basename "$PROJECT_DIR")}"
PROJECT_METRICS_FILE="$RUN_DIR/learner-project-metrics.json"
PROMPT_FILE="$RUN_DIR/learner-prompt.txt"
TASK_CONTEXT_ID="${TASK_ID:-}"

ensure_runtime_dirs
mkdir -p "$RUN_DIR" "$(dirname "$RULES_OUTPUT_FILE")" "$(dirname "$OUTPUT_FILE")"

RECENT_TASKS="$(tail -n 20 "$TASK_LOG" 2>/dev/null || true)"
RECENT_LOGS="$(safe_tail_structured_logs 80 "$SYSTEM_LOG")"
CURRENT_RULES="$(tail -n 50 "$RULES_FILE" 2>/dev/null || true)"
MEMORY_TEXT="$(read_memory_context "$TARGET_PROJECT_NAME" "$TASK")"
MEMORY_TEXT="$(truncate_context_to_budget "$MEMORY_TEXT" 2500)"
SIMILAR_TASKS="$(build_similar_task_context "$TASK" "$TARGET_PROJECT_NAME" "$TASK_CONTEXT_ID")"
SIMILAR_TASKS="$(truncate_context_to_budget "$SIMILAR_TASKS" 3000)"
CURRENT_TASK_GUIDANCE="$(python3 - "$SIMILAR_TASKS" "$TASK" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any


similar_raw = sys.argv[1]
fallback_task = sys.argv[2]


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def normalize_list(value: Any, *, limit: int = 3) -> list[str]:
    if not isinstance(value, list):
        return []
    items: list[str] = []
    for entry in value:
        normalized = normalize_text(entry)
        if not normalized or normalized in items:
            continue
        items.append(normalized)
        if len(items) >= limit:
            break
    return items


def pick_current_task(tasks: Any) -> dict[str, Any] | None:
    if not isinstance(tasks, list):
        return None
    for task in tasks:
        if isinstance(task, dict) and task.get("current_task") is True:
            return task
    return None


def task_intent_payload(task: dict[str, Any]) -> dict[str, Any]:
    intent = task.get("task_intent")
    if isinstance(intent, dict):
        return intent
    execution_brief = task.get("execution_brief")
    if isinstance(execution_brief, dict):
        brief_intent = execution_brief.get("task_intent")
        if isinstance(brief_intent, dict):
            return brief_intent
    return {}


def verification_command(task: dict[str, Any]) -> str:
    task_shape = task.get("task_shape")
    if isinstance(task_shape, dict):
        return normalize_text(task_shape.get("verification_command"))
    return ""


try:
    similar_tasks = json.loads(similar_raw)
except Exception:
    similar_tasks = []

current_task = pick_current_task(similar_tasks)
if not isinstance(current_task, dict):
    raise SystemExit(0)

intent = task_intent_payload(current_task)
objective = normalize_text(intent.get("objective") or current_task.get("title") or fallback_task)
context_hint = normalize_text(intent.get("context_hint"))
affected_files = normalize_list(intent.get("affected_files"))
constraints = normalize_list(intent.get("constraints"))
success_signals = normalize_list(intent.get("success_signals"))
command = verification_command(current_task)

lines: list[str] = []
if objective:
    lines.append(f"- Objective: {objective}")
if context_hint:
    lines.append(f"- Focus: {context_hint}")
if affected_files:
    lines.append("- Affected files: " + ", ".join(f"`{path}`" for path in affected_files))
if constraints:
    lines.append("- Constraints: " + "; ".join(constraints))
if success_signals:
    lines.append("- Success signals: " + "; ".join(success_signals))
if command:
    lines.append(f"- Verification command: `{command}`")

if lines:
    lines.append("- Use this metadata to extract rules only for the approved scope instead of broadening the queue title.")
    print("\n".join(lines))
PY
)"
CURRENT_TASK_GUIDANCE="$(truncate_context_to_budget "$CURRENT_TASK_GUIDANCE" 1000)"

# Gather failure context from the run directory for richer analysis
FAILURE_CONTEXT=""
if [ "$RESULT" != "SUCCESS" ] && [ -d "$RUN_DIR" ]; then
  # Extract errors from codex/claude logs
  for logfile in "$RUN_DIR"/*.codex.log "$RUN_DIR"/*.claude.log; do
    [ -f "$logfile" ] || continue
    local_errors="$(grep -i 'error\|invalid\|TIMEOUT\|fail' "$logfile" 2>/dev/null | head -5 || true)"
    if [ -n "$local_errors" ]; then
      FAILURE_CONTEXT="${FAILURE_CONTEXT}Errors in $(basename "$logfile"):
$local_errors
"
    fi
  done
  # Check failed step from execution context
  if [ -f "$RUN_DIR/plan.json" ]; then
    local plan_status
    plan_status="$(jq -r '.status // "unknown"' "$RUN_DIR/plan.json" 2>/dev/null || true)"
    FAILURE_CONTEXT="${FAILURE_CONTEXT}Plan status: $plan_status
"
  fi
fi

# Gather success/failure ratio from recent tasks for pattern detection
TASK_PATTERN_SUMMARY=""
if [ -f "$TASK_LOG" ]; then
  TASK_PATTERN_SUMMARY="$(python3 -c "
import json, sys, collections
lines = []
try:
    with open('$TASK_LOG') as f:
        for l in f:
            l = l.strip()
            if l:
                try: lines.append(json.loads(l))
                except: pass
except: pass
recent = lines[-30:] if len(lines) > 30 else lines
s = sum(1 for t in recent if t.get('result') == 'SUCCESS')
f = sum(1 for t in recent if t.get('result') == 'FAILURE')
avg_dur = sum(t.get('duration_seconds', 0) for t in recent) / max(len(recent), 1)
common_errors = {}
failure_kinds = collections.Counter()
for t in recent:
    if t.get('result') == 'FAILURE':
        task = t.get('task', '')[:50]
        common_errors[task] = common_errors.get(task, 0) + 1
        kind = t.get('failure_kind', 'unknown')
        failure_kinds[kind] += 1
top_errors = sorted(common_errors.items(), key=lambda x: -x[1])[:3]
print(f'Recent 30 tasks: {s} success, {f} failures, avg duration {avg_dur:.0f}s')
if top_errors:
    print(f'Most repeated failures: {top_errors}')
if failure_kinds:
    print(f'Failure categories: {dict(failure_kinds.most_common(5))}')
    top_kind = failure_kinds.most_common(1)[0]
    print(f'DOMINANT FAILURE: {top_kind[0]} ({top_kind[1]} occurrences) — rules should address this category')
" 2>/dev/null || true)"
fi

# Gather retry-failure-analysis for the learner
RETRY_FAILURE_SUMMARY=""
RETRY_ANALYSIS_FILE="$ROOT_DIR/codex-learning/retry-failure-analysis.jsonl"
if [ -f "$RETRY_ANALYSIS_FILE" ]; then
  RETRY_FAILURE_SUMMARY="$(python3 -c "
import json, sys, collections
lines = []
try:
    with open('$RETRY_ANALYSIS_FILE') as f:
        for l in f:
            l = l.strip()
            if l:
                try: lines.append(json.loads(l))
                except: pass
except: pass
recent = lines[-20:]
cats = collections.Counter(e.get('classification', 'unknown') for e in recent)
print(f'Last 20 retries by classification: {dict(cats.most_common())}')
unknown_pct = cats.get('unknown', 0) / max(len(recent), 1) * 100
if unknown_pct > 50:
    print(f'WARNING: {unknown_pct:.0f}% of retries are classified as unknown — classification needs improvement')
" 2>/dev/null || true)"
fi

# Prefer project-local metrics when the current project has its own task history.
python3 - "$ROOT_DIR" "$TARGET_PROJECT_NAME" "$TASK_LOG" "$TASK_REGISTRY_FILE" "$RETRY_ANALYSIS_LOG" "$METRICS_FILE" >"$PROJECT_METRICS_FILE" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
from typing import Any

root_dir, project_name, task_log_path, task_registry_path, retry_analysis_path, metrics_path = sys.argv[1:]
scripts_dir = os.path.join(root_dir, "scripts")
if scripts_dir not in sys.path:
    sys.path.insert(0, scripts_dir)

try:
    from task_metrics import (
        build_latest_success_timestamp_by_identity,
        build_retry_failure_kind_index,
        build_task_index_by_id,
        effective_retry_classification,
        is_unresolved_timeout_record,
    )
except Exception:
    build_latest_success_timestamp_by_identity = None
    build_retry_failure_kind_index = None
    build_task_index_by_id = None
    effective_retry_classification = None
    is_unresolved_timeout_record = None


def read_json(path: str, fallback: dict[str, Any]) -> dict[str, Any]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if isinstance(payload, dict):
            return payload
    except Exception:
        pass
    return dict(fallback)


def read_json_lines(path: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    if not os.path.exists(path):
        return records
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw_lines = handle.readlines()
    except Exception:
        return records
    for raw_line in raw_lines:
        line = raw_line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except Exception:
            continue
        if isinstance(payload, dict):
            records.append(payload)
    return records


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def normalize_project(value: Any) -> str:
    return normalize_text(value) or "codex-agent-system"


base_metrics = read_json(metrics_path, {})
tasks_payload = read_json(task_registry_path, {"tasks": []})
tasks = tasks_payload.get("tasks") if isinstance(tasks_payload.get("tasks"), list) else []
task_log_records = read_json_lines(task_log_path)
retry_failure_records = read_json_lines(retry_analysis_path)

project_key = normalize_project(project_name)
project_tasks = [
    task for task in tasks
    if isinstance(task, dict) and normalize_project(task.get("project") or task.get("target_project")) == project_key
]
project_task_log_records = [
    record for record in task_log_records
    if isinstance(record, dict) and normalize_project(record.get("project") or record.get("target_project")) == project_key
]
project_retry_failure_records = [
    record for record in retry_failure_records
    if isinstance(record, dict) and normalize_project(record.get("project") or record.get("target_project")) == project_key
]

snapshot = {
    "project": project_name,
    "scope": "global",
    "success_rate": base_metrics.get("success_rate", 0.15),
    "recent_success_rate": base_metrics.get("recent_success_rate", 0.28),
    "timeout_failure_rate": base_metrics.get("timeout_failure_rate", 0.36),
    "total_tasks": base_metrics.get("total_tasks", 500),
    "retry_classification_coverage": base_metrics.get("retry_classification_coverage", 0.87),
    "retry_classified_count": base_metrics.get("retry_classified_count", 0),
    "retry_total_count": base_metrics.get("retry_total_count", 0),
}

if project_tasks or project_task_log_records or project_retry_failure_records:
    snapshot["scope"] = "project_local"

    if project_task_log_records:
        total_tasks = len(project_task_log_records)
        success_records = sum(
            1 for record in project_task_log_records if str(record.get("result") or "").strip().upper() == "SUCCESS"
        )
        snapshot["total_tasks"] = total_tasks
        snapshot["success_rate"] = round(success_records / total_tasks, 2) if total_tasks else 0
        recent_project_records = [
            record
            for record in project_task_log_records
            if str(record.get("result") or "").strip().upper() in {"SUCCESS", "FAILURE"}
        ][-50:]
        snapshot["recent_success_rate"] = round(
            sum(1 for record in recent_project_records if str(record.get("result") or "").strip().upper() == "SUCCESS")
            / len(recent_project_records),
            2,
        ) if recent_project_records else 0

        if (
            build_task_index_by_id is not None
            and build_latest_success_timestamp_by_identity is not None
            and is_unresolved_timeout_record is not None
        ):
            tasks_by_id = build_task_index_by_id(project_tasks)
            latest_success_by_identity = build_latest_success_timestamp_by_identity(project_task_log_records)
            timeout_failure_records = sum(
                1
                for record in project_task_log_records
                if is_unresolved_timeout_record(record, tasks_by_id, latest_success_by_identity)
            )
        else:
            timeout_failure_records = sum(
                1
                for record in project_task_log_records
                if str(record.get("result") or "").strip().upper() == "FAILURE"
                and str(record.get("failure_kind") or "").strip().lower() == "timeout"
            )
        snapshot["timeout_failure_rate"] = round(timeout_failure_records / total_tasks, 2) if total_tasks else 0

    if project_retry_failure_records:
        snapshot["retry_total_count"] = len(project_retry_failure_records)
        if build_retry_failure_kind_index is not None and effective_retry_classification is not None:
            retry_failure_kind_index = build_retry_failure_kind_index(project_task_log_records)
            classified_count = sum(
                1
                for record in project_retry_failure_records
                if effective_retry_classification(record, retry_failure_kind_index) != "unknown"
            )
        else:
            classified_count = sum(
                1
                for record in project_retry_failure_records
                if normalize_text(record.get("classification")) not in {"", "unknown"}
            )
        snapshot["retry_classified_count"] = classified_count
        snapshot["retry_classification_coverage"] = round(
            classified_count / snapshot["retry_total_count"],
            2,
        ) if snapshot["retry_total_count"] else 0
    else:
        snapshot["retry_classified_count"] = 0
        snapshot["retry_total_count"] = 0
        snapshot["retry_classification_coverage"] = 0

snapshot["retry_classification_display"] = (
    f"{snapshot['retry_classification_coverage']:.2f}"
    if int(snapshot.get("retry_total_count") or 0) > 0
    else "n/a"
)
print(json.dumps(snapshot))
PY
PROJECT_METRICS_JSON="$(cat "$PROJECT_METRICS_FILE" 2>/dev/null || printf '{}')"

# Read live metrics for accurate learner context
LIVE_METRICS_SCOPE="$(jq -r '.scope // "global"' <<<"$PROJECT_METRICS_JSON" 2>/dev/null || printf 'global')"
LIVE_SUCCESS_RATE="$(jq -r '.success_rate // 0.15' <<<"$PROJECT_METRICS_JSON" 2>/dev/null || printf '0.15')"
LIVE_RECENT_RATE="$(jq -r '.recent_success_rate // 0.28' <<<"$PROJECT_METRICS_JSON" 2>/dev/null || printf '0.28')"
LIVE_TIMEOUT_RATE="$(jq -r '.timeout_failure_rate // 0.36' <<<"$PROJECT_METRICS_JSON" 2>/dev/null || printf '0.36')"
LIVE_TOTAL_TASKS="$(jq -r '.total_tasks // 500' <<<"$PROJECT_METRICS_JSON" 2>/dev/null || printf '500')"
LIVE_RULES_COUNT="$(jq -r '.learning_rules_count // 10' "$METRICS_FILE" 2>/dev/null || printf '10')"
LIVE_RETRY_COVERAGE="$(jq -r '.retry_classification_display // "n/a"' <<<"$PROJECT_METRICS_JSON" 2>/dev/null || printf 'n/a')"
LIVE_RETRY_CLASSIFIED_COUNT="$(jq -r '.retry_classified_count // 0' <<<"$PROJECT_METRICS_JSON" 2>/dev/null || printf '0')"
LIVE_RETRY_TOTAL_COUNT="$(jq -r '.retry_total_count // 0' <<<"$PROJECT_METRICS_JSON" 2>/dev/null || printf '0')"

FAILURE_CONTEXT_BLOCK=""
if [ -n "$FAILURE_CONTEXT" ]; then
  FAILURE_CONTEXT_BLOCK="$(printf 'Failure details from this run:\n%s\n' "$FAILURE_CONTEXT")"
fi

TASK_PATTERN_BLOCK=""
if [ -n "$TASK_PATTERN_SUMMARY" ]; then
  TASK_PATTERN_BLOCK="$(printf 'Pattern summary:\n%s\n' "$TASK_PATTERN_SUMMARY")"
fi

RETRY_FAILURE_BLOCK=""
if [ -n "$RETRY_FAILURE_SUMMARY" ]; then
  RETRY_FAILURE_BLOCK="$(printf 'Retry failure analysis:\n%s\n' "$RETRY_FAILURE_SUMMARY")"
fi

cat >"$PROMPT_FILE" <<EOF
You are the learner agent. Your job is to improve the system's success rate by analyzing patterns.

CRITICAL CONTEXT (live from system evidence):
- Metrics scope: ${LIVE_METRICS_SCOPE} for ${TARGET_PROJECT_NAME}.
- All-time success rate: ${LIVE_SUCCESS_RATE} across ${LIVE_TOTAL_TASKS} tasks. Recent (last 50): ${LIVE_RECENT_RATE}.
- Timeout failure rate: ${LIVE_TIMEOUT_RATE}.
- Retry classification coverage: ${LIVE_RETRY_COVERAGE} (${LIVE_RETRY_CLASSIFIED_COUNT}/${LIVE_RETRY_TOTAL_COUNT}). Active rules: ${LIVE_RULES_COUNT}.
- Learning rate is low — be AGGRESSIVE about extracting actionable rules from every failure pattern.

Role:
- Analyze the latest task result and recent task history.
- Identify PATTERNS in failures — any pattern appearing in 2+ tasks warrants a rule.
- Generate up to 5 simple, actionable rules that address the most common failure modes.
- Each rule must be ENFORCEABLE IN CODE — not generic advice. Good rules specify:
  * Concrete thresholds (e.g., "if word count > 15", "if duration > 300s")
  * Specific file/function targets (e.g., "in orchestrator.sh", "in classify_failure")
  * Measurable outcomes (e.g., "reduces timeout rate by X%", "prevents N wasted retries")
- BAD rule example: "Keep tasks focused" (too vague, not enforceable)
- GOOD rule example: "Tasks with >3 'and' conjunctions must be split into subtasks before execution — enforced in orchestrator pre-check"
- Rules MUST target: timeout prevention, scope reduction, better error classification, or environment validation.
- Be AGGRESSIVE about extracting rules — the system needs to learn faster.
- Return only bullet points beginning with "- ".

Latest task:
$TASK

Latest result:
$RESULT

$(if [ -n "$MEMORY_TEXT" ] && [ "$MEMORY_TEXT" != "null" ]; then printf 'PROJECT MEMORY:\n%s\n\n' "$MEMORY_TEXT"; fi)$(if [ -n "$CURRENT_TASK_GUIDANCE" ] && [ "$CURRENT_TASK_GUIDANCE" != "null" ]; then printf 'CURRENT TASK SHAPE:\n%s\n\n' "$CURRENT_TASK_GUIDANCE"; fi)

$FAILURE_CONTEXT_BLOCK

$TASK_PATTERN_BLOCK

$RETRY_FAILURE_BLOCK

IMPORTANT: Focus rules on the DOMINANT failure category. If sandbox_restriction or missing_environment dominate,
generate rules that prevent these tasks from being created in the first place. If unknown dominates, generate rules
that improve error reporting in coder/reviewer output. If timeout dominates, generate rules that reduce step scope.

Recent task history (JSON lines):
$RECENT_TASKS

Recent system logs:
$RECENT_LOGS

Current rules (keep what works, ADD new rules — do not drop existing good rules):
$CURRENT_RULES
EOF
PROMPT="$(cat "$PROMPT_FILE")"

fallback_learner() {
  # Seed from existing persistent rules instead of always overwriting with generics.
  # This prevents the learner from regressing accumulated knowledge on every fallback.
  if [ -f "$RULES_FILE" ] && grep -q '^- ' "$RULES_FILE"; then
    grep '^- ' "$RULES_FILE" | head -5 >"$RAW_RULES_FILE"
  else
    cat >"$RAW_RULES_FILE" <<EOF
- Keep prompt changes minimal and tied to repeated evidence.
- Prefer prompt rules that improve determinism and verification.
- Avoid task-specific prompt tweaks unless the same failure repeats.
- Capture outcomes in a way that future runs can reuse safely.
EOF
  fi

  if [ "$RESULT" != "SUCCESS" ]; then
    printf '%s\n' '- When retries are exhausted, narrow the next prompt instead of adding scope.' >>"$RAW_RULES_FILE"
  fi

  # Context-aware fallback: extract dominant failure category and add targeted rule
  if [ -n "$RETRY_FAILURE_SUMMARY" ]; then
    local dominant_cat
    dominant_cat="$(printf '%s' "$RETRY_FAILURE_SUMMARY" | grep -o 'DOMINANT FAILURE: [a-z_]*' | head -1 | sed 's/DOMINANT FAILURE: //' || true)"
    case "$dominant_cat" in
      review_rejection)
        printf '%s\n' '- When review_rejection occurs, diff the coder output against the reviewer objection to generate a targeted fix hint for retry.' >>"$RAW_RULES_FILE"
        ;;
      timeout)
        printf '%s\n' '- Track per-step duration and abort steps exceeding 80% of timeout budget to preserve time for verification.' >>"$RAW_RULES_FILE"
        ;;
      missing_environment|sandbox_restriction)
        printf '%s\n' '- For environment-related failures (sandbox_restriction, missing_environment), mark the task as environment-blocked rather than retrying.' >>"$RAW_RULES_FILE"
        ;;
      step_not_completed)
        printf '%s\n' '- When step_not_completed is the dominant failure, ensure coder outputs include explicit completion markers that the reviewer can verify.' >>"$RAW_RULES_FILE"
        ;;
    esac
  fi
}

if ! run_codex_exec learner "$PROJECT_DIR" "$PROMPT" "$RAW_RULES_FILE"; then
  fallback_learner
elif ! grep -q '^- ' "$RAW_RULES_FILE"; then
  log_msg WARN learner "codex learner output had no bullet rules; using fallback rules"
  fallback_learner
fi

RULES_JSON="$(extract_bullet_rules_json "$RAW_RULES_FILE" 5)"
if [ "$(jq 'length' <<<"$RULES_JSON")" -eq 0 ]; then
  fallback_learner
  RULES_JSON="$(extract_bullet_rules_json "$RAW_RULES_FILE" 5)"
fi

# ─── v33: Rules-hash freeze guard (moved BEFORE prompt-rules write) ───
# If >50% of recent trace entries have unique rules_hash values, the learner is
# modifying rules faster than they can be measured. Skip BOTH prompt-rules AND
# rules.md accumulation to stabilize the hash for effectiveness measurement.
# v30 original only protected rules.md but prompt-rules.md was still written
# unconditionally, causing a new hash every run (95% unique in last 20).
RULES_HASH_FROZEN="false"
TRACE_FILE="$ROOT_DIR/codex-learning/rule-outcome-trace.jsonl"
if [ -f "$TRACE_FILE" ]; then
  RULES_HASH_FROZEN="$(python3 - "$TRACE_FILE" <<'PYFREEZE'
import json, sys
from pathlib import Path

trace_path = Path(sys.argv[1])
lines = trace_path.read_text(encoding="utf-8").splitlines()[-20:]
hashes = []
for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except Exception:
        continue
    h = entry.get("rules_hash", "")
    if h:
        hashes.append(h)

if len(hashes) >= 10:
    unique_ratio = len(set(hashes)) / len(hashes)
    if unique_ratio > 0.50:
        print("true")
    else:
        print("false")
else:
    print("false")
PYFREEZE
)"
fi

if [ "$RULES_HASH_FROZEN" = "true" ]; then
  log_msg WARN learner "Rules-hash churn detected (>50% unique in last 20 traces). Skipping prompt-rules AND rules.md to stabilize hash."
else

# Only write prompt-rules when NOT frozen — this is the PRIMARY cause of hash churn
write_rules_markdown_file "# Prompt Rules" "$RULES_OUTPUT_FILE" "$RULES_JSON"

# ─── Accumulate rules into persistent rules.md (not just overwrite prompt-rules) ───
# The learner's biggest weakness was only keeping 5 rules total and overwriting each run.
# Now we merge new rules into the persistent rules.md with deduplication and a 20-rule cap.
python3 - "$RULES_FILE" "$RULES_JSON" <<'PYACCUMULATE'
import json, sys, difflib
from pathlib import Path

rules_file = Path(sys.argv[1])
new_rules_raw = sys.argv[2]

try:
    new_rules = json.loads(new_rules_raw)
except Exception:
    new_rules = []

if not new_rules:
    raise SystemExit(0)

# Read existing persistent rules
existing_rules = []
if rules_file.exists():
    for line in rules_file.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("- "):
            existing_rules.append(stripped[2:])

# Deduplicate: skip new rules too similar to existing ones (>65% match).
# Lowered from 80% on 2026-03-29 because short rules sharing common phrases
# ("reject tasks that...", "in agents/planner.sh...") were being incorrectly
# deduplicated, suppressing distinct rules. Learning rate was only 1.38/100 tasks.
added = 0
for new_rule in new_rules:
    new_rule = str(new_rule).strip()
    if not new_rule:
        continue
    is_duplicate = False
    for existing in existing_rules:
        similarity = difflib.SequenceMatcher(None, new_rule.lower(), existing.lower()).ratio()
        if similarity > 0.65:
            is_duplicate = True
            break
    if not is_duplicate:
        existing_rules.append(new_rule)
        added += 1

# Cap at 20 rules, keep most recent if over
MAX_RULES = 20
if len(existing_rules) > MAX_RULES:
    existing_rules = existing_rules[-MAX_RULES:]

# Write back
content = "# Learned Rules\n\n"
for rule in existing_rules:
    content += f"- {rule}\n"
content += "\n"
rules_file.write_text(content, encoding="utf-8")

if added > 0:
    print(f"Accumulated {added} new rules into rules.md (total: {len(existing_rules)})")
PYACCUMULATE

fi  # end rules_hash freeze guard

# Topic-based memory: categorize this learning into topic files
TOPICS_DIR="$MEMORY_DIR/topics"
mkdir -p "$TOPICS_DIR"
python3 - "$TASK" "$RESULT" "$TOPICS_DIR" "$RULES_JSON" <<'PYTOPIC'
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

task_text = sys.argv[1]
result = sys.argv[2]
topics_dir = Path(sys.argv[3])
rules_json_raw = sys.argv[4]

try:
    rules = json.loads(rules_json_raw)
except Exception:
    rules = []

task_lower = task_text.lower()
now_str = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# Keyword-based topic classification
topic_keywords = {
    "stability": ["crash", "error", "fail", "broken", "fix", "bug", "stable", "safety"],
    "queue": ["queue", "worker", "multi-queue", "drain", "starvation", "cooldown"],
    "dashboard": ["dashboard", "ui", "frontend", "css", "html", "chart", "metric"],
    "timeout": ["timeout", "slow", "performance", "latency", "300s", "180s"],
    "provider": ["codex", "claude", "provider", "auth", "cli", "api", "model"],
    "planning": ["planner", "plan", "step", "strategy", "pipeline"],
    "memory": ["memory", "context", "decisions", "learning", "rules", "prompt"],
    "testing": ["test", "smoke", "verify", "validation", "assert"],
}

matched_topics: set[str] = set()
for topic, keywords in topic_keywords.items():
    for kw in keywords:
        if kw in task_lower:
            matched_topics.add(topic)
            break

if not matched_topics:
    matched_topics.add("general")

learning_entry = f"- {now_str} | {result} | {task_text[:120]}"
if rules:
    learning_entry += f"\n  Rules: {'; '.join(str(r) for r in rules[:3])}"

for topic in matched_topics:
    topic_file = topics_dir / f"{topic}.md"
    existing = topic_file.read_text(encoding="utf-8") if topic_file.exists() else ""
    lines = existing.strip().split("\n") if existing.strip() else []
    # Keep max 50 LINES per topic (rolling window).
    # Multi-line entries (entry + rules) count as multiple lines.
    # Reserve space for the new entry's lines before appending.
    new_entry_lines = learning_entry.split("\n")
    max_existing = 50 - len(new_entry_lines)
    if len(lines) >= max_existing:
        lines = lines[-max_existing:]
    lines.extend(new_entry_lines)
    topic_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
PYTOPIC

DATA_JSON="$(jq -cn \
  --arg result "$RESULT" \
  --arg output_file "$(relative_path "$RULES_OUTPUT_FILE" "$ROOT_DIR")" \
  --argjson rules "$RULES_JSON" \
  '{result:$result,rules:$rules,output_file:$output_file}')"
write_json_file "$OUTPUT_FILE" "success" "Prompt improvements captured." "$DATA_JSON"

log_msg INFO learner "Prompt rules saved to $(relative_path "$RULES_OUTPUT_FILE" "$ROOT_DIR")"
print_json_file "$OUTPUT_FILE"
