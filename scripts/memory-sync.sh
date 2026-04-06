#!/usr/bin/env bash
# memory-sync.sh — Shared Memory Synchronization Layer
#
# Synchronizes learnings and context between:
# 1. Codex Agent System (codex-memory/topics/, index.md)
# 2. Claude Code (CLAUDE.md, .claude/rules/)
# 3. Codex CLI (AGENTS.md)
#
# Usage:
#   bash scripts/memory-sync.sh sync       # Full bidirectional sync
#   bash scripts/memory-sync.sh export     # Export from codex-memory to Claude/Codex files
#   bash scripts/memory-sync.sh import     # Import from Claude/Codex files to codex-memory

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap memory-sync

MODE="${1:-sync}"

MEMORY_DIR="$ROOT_DIR/codex-memory"
TOPICS_DIR="$MEMORY_DIR/topics"
INDEX_FILE="$MEMORY_DIR/index.md"
LEARNING_DIR="$ROOT_DIR/codex-learning"

# Target files for synchronization
CLAUDE_MD_FILE="$ROOT_DIR/CLAUDE.md"
CLAUDE_RULES_DIR="$ROOT_DIR/.claude/rules"
AGENTS_MD_FILE="$ROOT_DIR/AGENTS.md"

# Sync state tracking
SYNC_STATE_FILE="$ROOT_DIR/codex-logs/memory-sync.state"
SYNC_LOG_FILE="$ROOT_DIR/codex-logs/memory-sync.log"

log_sync() {
  local level="$1"
  local msg="$2"
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf '[%s] %s: %s\n' "$timestamp" "$level" "$msg" >> "$SYNC_LOG_FILE" 2>/dev/null || true
  log_msg "$level" memory-sync "$msg"
}

# ─── EXPORT: codex-memory → CLAUDE.md / AGENTS.md ───

generate_claude_md() {
  log_sync INFO "Generating CLAUDE.md from codex-memory..."

  cat > "$CLAUDE_MD_FILE" << 'HEADER'
# CLAUDE.md — Project Intelligence for Claude Code
# Auto-generated from codex-memory by memory-sync.sh
# Last sync: SYNC_TIMESTAMP
#
# This file is loaded into every Claude Code session.
# Keep under 200 lines for optimal adherence.

HEADER

  # Replace timestamp
  sed -i "s/SYNC_TIMESTAMP/$(date -u +"%Y-%m-%dT%H:%M:%SZ")/" "$CLAUDE_MD_FILE" 2>/dev/null || true

  # Core architecture rules from index
  if [ -f "$INDEX_FILE" ]; then
    printf '## Core Rules\n\n' >> "$CLAUDE_MD_FILE"
    grep -E '^\- ' "$INDEX_FILE" | head -n 15 >> "$CLAUDE_MD_FILE"
    printf '\n' >> "$CLAUDE_MD_FILE"
  fi

  # Learned rules from codex-learning (include ALL rules, not just last 10 lines)
  if [ -f "$LEARNING_DIR/rules.md" ]; then
    printf '## Learned Rules\n\n' >> "$CLAUDE_MD_FILE"
    grep -E '^\- ' "$LEARNING_DIR/rules.md" >> "$CLAUDE_MD_FILE" || true
    printf '\n' >> "$CLAUDE_MD_FILE"
  fi

  # Provider routing summary
  if [ -f "$LEARNING_DIR/provider-routing.json" ]; then
    printf '## Provider Routing\n\n' >> "$CLAUDE_MD_FILE"
    printf 'Use `claude` provider for UI tasks. Use `codex` for all other categories.\n' >> "$CLAUDE_MD_FILE"
    printf 'See `codex-learning/provider-routing.json` for detailed routing rules.\n\n' >> "$CLAUDE_MD_FILE"
  fi

  # Topic summaries: extract success/failure counts and any Rules: lines (not raw log entries)
  if [ -d "$TOPICS_DIR" ]; then
    printf '## Key Learnings by Topic\n\n' >> "$CLAUDE_MD_FILE"
    python3 - "$TOPICS_DIR" >> "$CLAUDE_MD_FILE" <<'PYTOPICS'
import sys
from pathlib import Path

topics_dir = Path(sys.argv[1])
for topic_file in sorted(topics_dir.glob("*.md")):
    topic_name = topic_file.stem
    lines = topic_file.read_text(encoding="utf-8").strip().splitlines()
    # Count successes and failures
    successes = sum(1 for l in lines if "succeeded" in l.lower() or "SUCCESS" in l)
    failures = sum(1 for l in lines if "failed" in l.lower() or "FAILURE" in l)
    # Extract unique Rules: lines (the distilled learnings, not raw task entries)
    rules = set()
    for l in lines:
        if "Rules:" in l:
            rule_text = l.split("Rules:", 1)[1].strip()[:200]
            if rule_text:
                rules.add(rule_text)
    total = len([l for l in lines if l.strip().startswith("- ")])
    rate = f"{successes}/{total}" if total > 0 else "0/0"
    summary = f"- **{topic_name}**: {rate} success"
    if rules:
        # Show the most recent rule snippet (up to 100 chars)
        latest_rule = sorted(rules)[-1][:100]
        summary += f" | Rule: {latest_rule}"
    print(summary)
PYTOPICS
    printf '\n' >> "$CLAUDE_MD_FILE"
  fi

  # Pre-dispatch metrics validation: recompute drifted fields before reading
  # This guard prevents the recurring metrics drift (3+ consecutive sync cycles)
  if [ -x "$ROOT_DIR/scripts/validate-metrics.sh" ]; then
    bash "$ROOT_DIR/scripts/validate-metrics.sh" >> "$SYNC_LOG_FILE" 2>&1 || true
  fi

  # System metrics summary
  if [ -f "$LEARNING_DIR/metrics.json" ]; then
    printf '## System Health\n\n' >> "$CLAUDE_MD_FILE"
    local success_rate timeout_rate recent_rate first_pass_rate
    success_rate="$(jq -r '.success_rate // 0' "$LEARNING_DIR/metrics.json" 2>/dev/null || printf '0')"
    recent_rate="$(jq -r '.recent_success_rate // "n/a"' "$LEARNING_DIR/metrics.json" 2>/dev/null || printf 'n/a')"
    timeout_rate="$(jq -r '.timeout_failure_rate // 0' "$LEARNING_DIR/metrics.json" 2>/dev/null || printf '0')"
    first_pass_rate="$(jq -r '.first_pass_success_rate // 0' "$LEARNING_DIR/metrics.json" 2>/dev/null || printf '0')"
    local q4_rate loop_effort_count zombie_info
    q4_rate="$(jq -r '.recent_success_rate // "n/a"' "$LEARNING_DIR/metrics.json" 2>/dev/null || printf 'n/a')"
    loop_effort_count="$(jq -r '.loop_effort_extra_step_attempts // 0' "$LEARNING_DIR/metrics.json" 2>/dev/null || printf '0')"
    printf 'All-time success rate: %s. Recent (last 50): %s. Q4 (last 132): %s. First-pass: %s. Timeout rate: %s.\n' \
      "$success_rate" "$recent_rate" "$q4_rate" "$first_pass_rate" "$timeout_rate" >> "$CLAUDE_MD_FILE"
    # Dynamic focus based on current dominant signal
    if [ "$(echo "$timeout_rate > 0.30" | bc -l 2>/dev/null || printf '0')" = "1" ]; then
      printf 'Focus: reduce timeout rate (%s of failures), prevent zero-step-attempt timeouts via simpler plans.\n' "$timeout_rate" >> "$CLAUDE_MD_FILE"
    elif [ "$(echo "$success_rate < 0.20" | bc -l 2>/dev/null || printf '0')" = "1" ]; then
      printf 'Focus: raise success rate above 20%% — current %s is critically low.\n' "$success_rate" >> "$CLAUDE_MD_FILE"
    else
      printf 'Focus: maintain improvement trend, reduce loop effort (%s wasted step attempts).\n' "$loop_effort_count" >> "$CLAUDE_MD_FILE"
    fi
    # Add iteration trend if available
    local trend_improving trend_delta
    trend_improving="$(jq -r '.iteration_trend_improving // false' "$LEARNING_DIR/metrics.json" 2>/dev/null || printf 'false')"
    trend_delta="$(jq -r '.iteration_trend_delta_pp // 0' "$LEARNING_DIR/metrics.json" 2>/dev/null || printf '0')"
    if [ "$trend_improving" = "true" ]; then
      printf 'Trend: IMPROVING (+%spp first-half vs second-half success rate).\n' "$trend_delta" >> "$CLAUDE_MD_FILE"
    elif [ "$trend_delta" != "0" ]; then
      printf 'Trend: NOT IMPROVING (%spp first-half vs second-half success rate).\n' "$trend_delta" >> "$CLAUDE_MD_FILE"
    fi
    local zombie_count zero_step
    zombie_count="$(jq -r '.zombie_task_count // 0' "$LEARNING_DIR/metrics.json" 2>/dev/null || printf '0')"
    zero_step="$(jq -r '.zero_step_timeout_count // 0' "$LEARNING_DIR/metrics.json" 2>/dev/null || printf '0')"
    if [ "${zombie_count:-0}" -gt 0 ] || [ "${zero_step:-0}" -gt 0 ]; then
      printf 'Waste: %s zombie tasks (5+ repeated failures), %s zero-step timeouts (planning overhead).\n' "$zombie_count" "$zero_step" >> "$CLAUDE_MD_FILE"
    fi
    printf '\n' >> "$CLAUDE_MD_FILE"
  fi

  local line_count
  line_count="$(wc -l < "$CLAUDE_MD_FILE")"
  log_sync INFO "Generated CLAUDE.md with $line_count lines"
}

generate_claude_rules() {
  log_sync INFO "Generating .claude/rules/ from scoped-rules.json..."

  mkdir -p "$CLAUDE_RULES_DIR"

  # Convert scoped-rules.json to individual rule files
  local scoped_rules="$MEMORY_DIR/scoped-rules.json"
  [ -f "$scoped_rules" ] || return 0

  python3 - "$scoped_rules" "$CLAUDE_RULES_DIR" <<'PY'
import json, sys
from pathlib import Path

rules_path = Path(sys.argv[1])
output_dir = Path(sys.argv[2])

try:
    rules = json.loads(rules_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

for entry in rules:
    paths = entry.get("paths", [])
    rule_list = entry.get("rules", [])
    if not paths or not rule_list:
        continue

    # Create rule file named after the first path pattern
    safe_name = paths[0].replace("/", "-").replace("*", "").replace(".", "-").strip("-")
    if not safe_name:
        safe_name = "general"

    rule_file = output_dir / f"{safe_name}.md"

    # Build frontmatter with path globs
    content = "---\n"
    for p in paths:
        content += f"paths: {p}\n"
    content += "---\n\n"

    for rule in rule_list:
        content += f"- {rule}\n"

    rule_file.write_text(content)
    print(f"Created rule: {rule_file.name}")
PY

  log_sync INFO "Claude rules directory updated"
}

update_agents_md() {
  log_sync INFO "Updating AGENTS.md with latest learnings..."

  python3 - "$AGENTS_MD_FILE" "$INDEX_FILE" "$LEARNING_DIR/rules.md" <<'PY'
import sys
from pathlib import Path

agents_md = Path(sys.argv[1])
index_file = Path(sys.argv[2])
rules_file = Path(sys.argv[3])

marker_start = "## Auto-Synced Learnings"
marker_end = "## End Auto-Synced"

if agents_md.exists():
    content = agents_md.read_text(encoding="utf-8")
else:
    content = ""


def stable_index_lines(path):
    if not path.exists():
        return []

    skipped_markers = (
        "task failed",
        "[code_quality]",
        "step 1:",
        "expected:",
        "planner timed out",
    )
    lines = []
    seen = set()
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line.startswith("- "):
            continue
        text = raw_line[2:].strip()
        lowered = text.lower()
        if not text or len(text) > 180:
            continue
        if any(marker in lowered for marker in skipped_markers):
            continue
        if text in seen:
            continue
        seen.add(text)
        lines.append(raw_line)
    return lines


def stable_rules(path):
    if not path.exists():
        return []
    rules = []
    seen = set()
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line.startswith("- "):
            continue
        text = raw_line[2:].strip()
        if not text or text in seen:
            continue
        seen.add(text)
        rules.append(raw_line)
    return rules

new_section = f"{marker_start}\n\n"
new_section += "<!-- Auto-generated by memory-sync.sh. Do not edit manually. -->\n\n"
new_section += "## Stable Operating Rules\n\n"
for line in stable_index_lines(index_file)[:14]:
    new_section += f"{line}\n"
new_section += "\n"

new_section += "## Current Learned Rules\n\n"
rules = stable_rules(rules_file)
if rules:
    for line in rules[:8]:
        new_section += f"{line}\n"
else:
    new_section += "- No learned rules recorded yet.\n"
new_section += "\n"

new_section += "## Detailed Memory\n\n"
new_section += "- See codex-memory/index.md for compact architecture memory.\n"
new_section += "- See codex-memory/learnings.md and codex-memory/topics/ for detailed failure history and experiments.\n\n"
new_section += f"{marker_end}\n"

start_idx = content.find(marker_start)
end_idx = content.find(marker_end)

if start_idx != -1 and end_idx != -1 and end_idx > start_idx:
    end_idx += len(marker_end)
    content = content[:start_idx] + new_section + content[end_idx:]
elif start_idx != -1:
    content = content[:start_idx] + new_section
else:
    if content and not content.endswith("\n"):
        content += "\n"
    if content:
        content += "\n"
    content += new_section

agents_md.write_text(content, encoding="utf-8")
print("Updated AGENTS.md auto-sync section")
PY
}

# ─── IMPORT: CLAUDE.md / transcript learnings → codex-memory ───

import_claude_code_learnings() {
  log_sync INFO "Importing learnings from Claude Code auto-memory..."

  # Check for Claude Code memory directory
  local claude_memory_dir
  claude_memory_dir="$(find "$HOME/.claude/projects" -maxdepth 2 -name "memory" -type d 2>/dev/null | head -1 || true)"

  if [ -z "$claude_memory_dir" ] || [ ! -d "$claude_memory_dir" ]; then
    log_sync INFO "No Claude Code auto-memory found at ~/.claude/projects/*/memory/"
    return 0
  fi

  local memory_md="$claude_memory_dir/MEMORY.md"
  if [ ! -f "$memory_md" ]; then
    log_sync INFO "No MEMORY.md found in Claude Code auto-memory"
    return 0
  fi

  # Extract new learnings (lines we haven't imported yet)
  local last_import_hash
  last_import_hash="$(grep 'claude_code_memory_hash=' "$SYNC_STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
  local current_hash
  current_hash="$(md5sum "$memory_md" 2>/dev/null | cut -d' ' -f1 || true)"

  if [ "$last_import_hash" = "$current_hash" ]; then
    log_sync INFO "Claude Code memory unchanged since last import"
    return 0
  fi

  # Import learnings into appropriate topics
  python3 - "$memory_md" "$TOPICS_DIR" "$INDEX_FILE" <<'PY'
import re, sys
from pathlib import Path
from datetime import datetime, timezone

memory_file = Path(sys.argv[1])
topics_dir = Path(sys.argv[2])
index_file = Path(sys.argv[3])

topics_dir.mkdir(parents=True, exist_ok=True)

content = memory_file.read_text(encoding="utf-8")
timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# Category detection keywords
category_map = {
    "stability": r"(crash|error|fail|timeout|restart|stable|resilient|race condition)",
    "ui": r"(dashboard|ui|mobile|button|display|render|css|html|frontend)",
    "performance": r"(speed|slow|fast|cache|optimize|performance|latency|memory)",
    "code_quality": r"(refactor|lint|clean|quality|test|format|style|pattern)",
    "queue-handling": r"(queue|worker|lane|poll|dispatch|retry|requeue)",
    "timeout-patterns": r"(timeout|deadline|duration|seconds)",
}

imported = 0
for line in content.splitlines():
    line = line.strip()
    if not line or line.startswith("#") or line.startswith("<!--"):
        continue
    if not line.startswith("- "):
        continue

    learning = line[2:].strip()
    if len(learning) < 10:
        continue

    # Categorize
    category = "code_quality"  # default
    learning_lower = learning.lower()
    for cat, pattern in category_map.items():
        if re.search(pattern, learning_lower):
            category = cat
            break

    # Write to topic file
    topic_file = topics_dir / f"{category}.md"
    if not topic_file.exists():
        topic_file.write_text(f"# {category.replace('-', ' ').title()} Learnings\n")

    with open(topic_file, "a") as f:
        f.write(f"- {timestamp} [claude-code]: {learning}\n")

    imported += 1

print(f"Imported {imported} learnings from Claude Code auto-memory")
PY

  # Update sync state
  mkdir -p "$(dirname "$SYNC_STATE_FILE")"
  printf 'claude_code_memory_hash=%s\nlast_import=%s\n' "$current_hash" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$SYNC_STATE_FILE"
  log_sync INFO "Import from Claude Code auto-memory completed"
}

# ─── MAIN ───

case "$MODE" in
  export)
    generate_claude_md
    generate_claude_rules
    update_agents_md
    log_sync INFO "Export complete"
    ;;
  import)
    import_claude_code_learnings
    log_sync INFO "Import complete"
    ;;
  sync)
    import_claude_code_learnings
    generate_claude_md
    generate_claude_rules
    update_agents_md
    # Growth-mode trigger: when pipeline is idle and healthy, invoke self-improve
    # to generate capability expansion tasks. This closes the gap where
    # strategy-loop.sh doesn't run during idle periods.
    if [ -x "$ROOT_DIR/scripts/self-improve.sh" ] && [ -f "$LEARNING_DIR/metrics.json" ]; then
      _pipeline_stale="$(jq -r '.pipeline_stale // false' "$LEARNING_DIR/metrics.json" 2>/dev/null || printf 'false')"
      _recent_rate="$(jq -r '.recent_success_rate // 0' "$LEARNING_DIR/metrics.json" 2>/dev/null || printf '0')"
      _running="$(jq -r '.running_tasks // 0' "$LEARNING_DIR/metrics.json" 2>/dev/null || printf '0')"
      _queued="$(jq -r '.queued_tasks // 0' "$LEARNING_DIR/metrics.json" 2>/dev/null || printf '0')"
      if [ "$_pipeline_stale" = "true" ] && [ "$_running" = "0" ] && [ "$_queued" = "0" ] \
         && [ "$(echo "$_recent_rate >= 0.90" | bc -l 2>/dev/null || printf '0')" = "1" ]; then
        log_sync INFO "Pipeline idle with high success rate — triggering self-improve for growth-mode"
        bash "$ROOT_DIR/scripts/self-improve.sh" >> "$SYNC_LOG_FILE" 2>&1 || true
      fi
    fi
    log_sync INFO "Full sync complete"
    ;;
  *)
    echo "usage: memory-sync.sh [sync|export|import]" >&2
    exit 2
    ;;
esac
