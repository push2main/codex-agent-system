#!/usr/bin/env bash
set -Eeuo pipefail

# Analyzes rule-outcome trace data to determine which rule sets correlate
# with success or failure. Outputs a JSON report.
# Usage: analyze-rule-effectiveness.sh [min_samples]

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap analyze-rule-effectiveness

TRACE_FILE="$LEARNING_DIR/rule-outcome-trace.jsonl"
MIN_SAMPLES="${1:-5}"

if [ ! -f "$TRACE_FILE" ] || [ ! -s "$TRACE_FILE" ]; then
  printf '{"status":"no_data","message":"No rule-outcome trace data available yet."}\n'
  exit 0
fi

python3 - "$TRACE_FILE" "$MIN_SAMPLES" <<'PYANALYZE'
import json
import sys
from collections import defaultdict
from pathlib import Path

trace_path = Path(sys.argv[1])
min_samples = int(sys.argv[2])

# Parse trace entries
entries = []
for line in trace_path.read_text().strip().split("\n"):
    line = line.strip()
    if not line:
        continue
    try:
        entries.append(json.loads(line))
    except json.JSONDecodeError:
        continue

if len(entries) < min_samples:
    print(json.dumps({
        "status": "insufficient_data",
        "message": f"Only {len(entries)} trace entries, need {min_samples}",
        "entries": len(entries)
    }))
    raise SystemExit(0)

# Group by rules_hash to see how different rule sets perform
by_hash = defaultdict(list)
for e in entries:
    by_hash[e.get("rules_hash", "unknown")].append(e)

hash_stats = {}
for h, group in by_hash.items():
    successes = sum(1 for e in group if e.get("result") == "SUCCESS")
    failures = len(group) - successes
    avg_score = sum(e.get("score", 0) for e in group) / len(group) if group else 0
    avg_duration = sum(e.get("duration_seconds", 0) for e in group) / len(group) if group else 0
    avg_attempts = sum(e.get("attempts", 0) for e in group) / len(group) if group else 0
    hash_stats[h] = {
        "rules_hash": h,
        "total": len(group),
        "successes": successes,
        "failures": failures,
        "success_rate": round(successes / len(group), 3) if group else 0,
        "avg_score": round(avg_score, 2),
        "avg_duration_seconds": round(avg_duration, 1),
        "avg_attempts": round(avg_attempts, 2),
        "sample_tasks": [e.get("task", "")[:80] for e in group[:3]]
    }

# Provider effectiveness
by_provider = defaultdict(list)
for e in entries:
    by_provider[e.get("provider", "unknown")].append(e)

provider_stats = {}
for p, group in by_provider.items():
    successes = sum(1 for e in group if e.get("result") == "SUCCESS")
    provider_stats[p] = {
        "total": len(group),
        "successes": successes,
        "success_rate": round(successes / len(group), 3) if group else 0
    }

# Failure kind distribution
failure_kinds = defaultdict(int)
for e in entries:
    if e.get("result") == "FAILURE":
        fk = e.get("failure_kind", "unknown") or "unknown"
        failure_kinds[fk] += 1

# Trend: are recent tasks doing better?
recent = entries[-min(10, len(entries)):]
older = entries[:max(len(entries) - 10, 0)]
recent_sr = sum(1 for e in recent if e.get("result") == "SUCCESS") / len(recent) if recent else 0
older_sr = sum(1 for e in older if e.get("result") == "SUCCESS") / len(older) if older else 0

report = {
    "status": "ok",
    "total_traced_tasks": len(entries),
    "overall_success_rate": round(sum(1 for e in entries if e.get("result") == "SUCCESS") / len(entries), 3),
    "rule_set_performance": sorted(hash_stats.values(), key=lambda x: -x["total"]),
    "provider_performance": provider_stats,
    "failure_kind_distribution": dict(sorted(failure_kinds.items(), key=lambda x: -x[1])),
    "trend": {
        "recent_10_success_rate": round(recent_sr, 3),
        "older_success_rate": round(older_sr, 3),
        "improving": recent_sr > older_sr,
        "delta": round(recent_sr - older_sr, 3)
    },
    "recommendation": ""
}

# Generate recommendation
if report["trend"]["improving"]:
    report["recommendation"] = f"Positive trend: recent tasks show {report['trend']['delta']:.1%} improvement. Current rules are effective."
elif report["trend"]["delta"] < -0.1:
    report["recommendation"] = "Negative trend: recent rule changes may have degraded performance. Consider reverting the latest rule additions."
else:
    report["recommendation"] = "Flat trend: current rules are not producing measurable improvement. Focus on the top failure kinds: " + ", ".join(list(failure_kinds.keys())[:3])

print(json.dumps(report, indent=2))
PYANALYZE
