#!/usr/bin/env bash
# ============================================================================
# Codex Agent System — Stability Test Suite
# ============================================================================
# Validates that the entire task execution pipeline is in a healthy,
# launchable state. Designed to run on macOS (Bash 3.2+) and Linux.
#
# Usage:  bash tests/stability-tests.sh
# Exit:   0 if all tests pass, 1 otherwise
# ============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PASS=0
FAIL=0
WARN=0
ERRORS=""

pass() { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  ✗ $1"; printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { WARN=$((WARN + 1)); printf '  \033[33m⚠\033[0m %s\n' "$1"; }
section() { printf '\n\033[1m── %s ──\033[0m\n' "$1"; }

# ============================================================================
section "1. Script Syntax (Bash)"
# ============================================================================
for script in \
  scripts/agentctl.sh \
  scripts/multi-queue.sh \
  scripts/strategy-loop.sh \
  scripts/dual-provider.sh \
  scripts/queue-worker.sh \
  scripts/lib.sh \
  scripts/compact-registry.sh \
  scripts/memory-sync.sh \
  scripts/self-improve.sh; do
  if [ -f "$script" ]; then
    if bash -n "$script" 2>/dev/null; then
      pass "$script syntax OK"
    else
      fail "$script has syntax errors"
    fi
  else
    warn "$script not found (skipped)"
  fi
done

# ============================================================================
section "2. Node.js Syntax (Dashboard)"
# ============================================================================
if command -v node >/dev/null 2>&1; then
  if node -c codex-dashboard/server.js 2>/dev/null; then
    pass "server.js syntax OK"
  else
    fail "server.js has syntax errors"
  fi

  # Verify dashboard HTML is valid enough to load
  if [ -f codex-dashboard/index.html ]; then
    if grep -q 'applyStatusPayload' codex-dashboard/index.html 2>/dev/null; then
      pass "index.html contains status rendering function"
    else
      fail "index.html missing applyStatusPayload — UI won't render status"
    fi
  else
    fail "codex-dashboard/index.html missing"
  fi
else
  warn "node not available — skipping server.js check"
fi

# ============================================================================
section "3. Bash 3 Compatibility"
# ============================================================================
# ;& is Bash 4+ fall-through syntax — macOS ships Bash 3.2
if grep -rn ';&' scripts/*.sh 2>/dev/null | grep -v '#' | grep -v '";&"' | grep -v "';&'" | grep -q .; then
  fail "Found ;& (Bash 4+ only) in scripts — breaks on macOS"
else
  pass "No ;& fall-through syntax found"
fi

# ;;& is also Bash 4+
if grep -rn ';&' scripts/*.sh 2>/dev/null | grep -v '#' | grep -v '";&"' | grep -v "';&'" | grep -q ';;[&]'; then
  fail "Found ;;& (Bash 4+ only) in scripts"
else
  pass "No ;;& pattern-resume syntax found"
fi

# associative arrays (declare -A) require Bash 4+
if grep -rn 'declare -A' scripts/*.sh 2>/dev/null | grep -v '#' | grep -q .; then
  fail "Found declare -A (Bash 4+ only) in scripts"
else
  pass "No associative arrays (declare -A) found"
fi

# ============================================================================
section "4. ERR Trap Safety"
# ============================================================================
# Scripts with set -e / set -E + ERR trap: any bare rm -f can crash the process
for script in scripts/strategy-loop.sh scripts/multi-queue.sh scripts/agentctl.sh scripts/queue-worker.sh; do
  if [ ! -f "$script" ]; then continue; fi
  unsafe=$(grep -n 'rm -[rf]' "$script" 2>/dev/null | grep -v '|| true' | grep -v '2>/dev/null || true' | grep -v '2>/dev/null;' | grep -v '#' || true)
  if [ -n "$unsafe" ]; then
    fail "$script has unguarded rm commands (ERR trap risk): $(echo "$unsafe" | head -1)"
  else
    pass "$script: all rm commands are trap-safe"
  fi
done

# ============================================================================
section "5. Required Files & Directories"
# ============================================================================
for f in \
  codex-memory/tasks.json \
  codex-dashboard/server.js \
  codex-dashboard/index.html \
  scripts/agentctl.sh \
  scripts/multi-queue.sh \
  scripts/queue-worker.sh \
  scripts/strategy-loop.sh \
  scripts/dual-provider.sh \
  scripts/lib.sh \
  scripts/run-with-timeout.py; do
  if [ -f "$f" ]; then
    pass "$f exists"
  else
    fail "$f missing"
  fi
done

for d in queues codex-logs codex-memory codex-dashboard projects; do
  if [ -d "$d" ]; then
    pass "$d/ directory exists"
  else
    fail "$d/ directory missing"
  fi
done

# ============================================================================
section "6. Registry Integrity"
# ============================================================================
python3 - <<'PY'
import json, sys

try:
    data = json.loads(open("codex-memory/tasks.json").read())
except Exception as e:
    print(f"  \033[31m✗\033[0m Registry JSON parse error: {e}")
    sys.exit(1)

tasks = data.get("tasks", [])
if not isinstance(tasks, list):
    print("  \033[31m✗\033[0m Registry 'tasks' is not a list")
    sys.exit(1)

valid = {"pending_approval", "approved", "running", "completed", "failed", "shelved", "cancelled"}
errors = []
ids_seen = set()

for i, t in enumerate(tasks):
    tid = t.get("id", f"index-{i}")
    if not t.get("id"):
        errors.append(f"Task at index {i} has no id")
    if tid in ids_seen:
        errors.append(f"Duplicate id: {tid}")
    ids_seen.add(tid)
    s = t.get("status", "")
    if s not in valid:
        errors.append(f"{tid}: invalid status '{s}' (valid: {valid})")
    # Verify no task has status 'queued' (not accepted by claim_task_lease)
    if s == "queued":
        errors.append(f"{tid}: status 'queued' is not valid — claim_task_lease only accepts approved/running")

if errors:
    for e in errors:
        print(f"  \033[31m✗\033[0m {e}")
    sys.exit(1)
else:
    from collections import Counter
    c = Counter(t.get("status") for t in tasks)
    dist = ", ".join(f"{s}={n}" for s, n in sorted(c.items()))
    print(f"  \033[32m✓\033[0m Registry valid: {len(tasks)} tasks ({dist})")
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# Registry size check
size=$(wc -c < codex-memory/tasks.json)
if [ "$size" -gt 524288 ]; then
  fail "Registry is ${size} bytes (> 512KB threshold) — needs compaction"
elif [ "$size" -gt 409600 ]; then
  warn "Registry is ${size} bytes (> 400KB) — consider compaction soon"
else
  pass "Registry size OK ($(( size / 1024 ))KB)"
fi

# ============================================================================
section "7. Queue-Registry Alignment"
# ============================================================================
python3 - <<'PY'
import json, sys

data = json.loads(open("codex-memory/tasks.json").read())
approved = [t for t in data["tasks"] if t.get("status") == "approved"]
errors = 0

if not approved:
    print("  \033[33m⚠\033[0m No approved tasks in registry (nothing to execute)")
    sys.exit(0)

for t in approved:
    proj = t.get("project", "codex-agent-system")
    txt = t.get("execution_task", t.get("task", t.get("title", "")))
    qfile = f"queues/{proj}.txt"
    try:
        lines = open(qfile).read().strip().split("\n")
        found = txt in lines
    except FileNotFoundError:
        found = False
    if found:
        print(f"  \033[32m✓\033[0m {t['id'][:45]} in {proj} queue")
    else:
        print(f"  \033[31m✗\033[0m {t['id'][:45]} MISSING from {proj} queue")
        errors += 1

sys.exit(1 if errors else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# ============================================================================
section "8. Lease Status Acceptance"
# ============================================================================
if grep -q 'current_status not in {"approved", "running"}' scripts/lib.sh 2>/dev/null; then
  pass "claim_task_lease accepts approved+running statuses"
else
  fail "claim_task_lease status filter may have changed — check scripts/lib.sh"
fi

# ============================================================================
section "9. Root Failure Demotion"
# ============================================================================
if grep -q 'ROOT_FAILURE_DEMOTION_THRESHOLD' codex-dashboard/server.js 2>/dev/null; then
  pass "Root failure demotion threshold is defined in server.js"
else
  fail "Root failure demotion threshold missing from server.js"
fi

if grep -q 'countRootFailures' codex-dashboard/server.js 2>/dev/null; then
  pass "countRootFailures helper exists in server.js"
else
  fail "countRootFailures helper missing from server.js"
fi

# ============================================================================
section "10. Provider Routing (dual-provider.sh)"
# ============================================================================
if grep -q 'Claude Code not available, falling back to codex' scripts/dual-provider.sh 2>/dev/null; then
  if grep -A3 'falling back to codex' scripts/dual-provider.sh | grep -q 'if \['; then
    pass "dual-provider.sh has Bash 3 compatible fallback"
  else
    fail "dual-provider.sh fallback may use ;& syntax"
  fi
else
  warn "dual-provider.sh fallback message not found (may have changed)"
fi

# ============================================================================
section "11. agentctl Startup Retry & Auto-Recovery"
# ============================================================================
if grep -q '_retries' scripts/agentctl.sh 2>/dev/null; then
  pass "agentctl.sh has startup retry loop"
else
  fail "agentctl.sh missing startup retry loop — tmux windows may fail health check"
fi

# Verify auto-recovery of missing tmux windows
if grep -q 'Dashboard window missing' scripts/agentctl.sh 2>/dev/null; then
  pass "agentctl.sh auto-recovers missing dashboard window"
else
  fail "agentctl.sh missing dashboard window auto-recovery"
fi

if grep -q 'Strategy window missing' scripts/agentctl.sh 2>/dev/null; then
  pass "agentctl.sh auto-recovers missing strategy window"
else
  fail "agentctl.sh missing strategy window auto-recovery"
fi

# ============================================================================
section "12. Project Registry Scanning"
# ============================================================================
if grep -q 'project_json\|project\.json' scripts/lib.sh 2>/dev/null; then
  pass "lib.sh reads project-specific registries"
else
  fail "lib.sh missing project registry scanning — superheld tasks won't be found"
fi

# Verify project config exists for known projects
for proj_dir in projects/*/; do
  proj_name="$(basename "$proj_dir")"
  if [ -f "${proj_dir}project.json" ]; then
    pass "projects/$proj_name/project.json exists"
  else
    fail "projects/$proj_name/project.json missing"
  fi
done

# ============================================================================
section "13. Queue Directory Structure"
# ============================================================================
queue_dir="queues"
if [ -d "$queue_dir" ]; then
  txt_count=$(ls "$queue_dir"/*.txt 2>/dev/null | wc -l)
  if [ "$txt_count" -gt 0 ]; then
    pass "Queue dir has $txt_count project queue files"
  else
    fail "Queue dir exists but has no .txt files"
  fi
else
  fail "Queue directory 'queues/' missing"
fi

if grep -q 'QUEUE_DIR="$ROOT_DIR/queues"' scripts/lib.sh 2>/dev/null; then
  pass "QUEUE_DIR correctly set to \$ROOT_DIR/queues"
else
  fail "QUEUE_DIR may point to wrong directory"
fi

# ============================================================================
section "14. Strategy Loop Cooldown"
# ============================================================================
if grep -q 'TIMEOUT_COOLDOWN_FILE.*|| true' scripts/strategy-loop.sh 2>/dev/null || \
   grep -q 'STRATEGY_HOT_RELOAD_STATE_FILE.*|| true' scripts/strategy-loop.sh 2>/dev/null; then
  pass "strategy-loop.sh has trap-safe cooldown file handling"
else
  fail "strategy-loop.sh cooldown file ops may crash under ERR trap"
fi

# ============================================================================
section "15. Dashboard Crash Protection"
# ============================================================================
# server.js must have uncaughtException handler to prevent silent crashes
if grep -q 'uncaughtException' codex-dashboard/server.js 2>/dev/null; then
  pass "server.js has uncaughtException handler"
else
  fail "server.js missing uncaughtException handler — crashes will be silent"
fi

if grep -q 'unhandledRejection' codex-dashboard/server.js 2>/dev/null; then
  pass "server.js has unhandledRejection handler"
else
  fail "server.js missing unhandledRejection handler — async crashes will be silent"
fi

# Crash log path should be defined
if grep -q 'dashboard-crash.log' codex-dashboard/server.js 2>/dev/null; then
  pass "server.js writes crash diagnostics to dashboard-crash.log"
else
  fail "server.js missing crash log output"
fi

# ============================================================================
section "16. Null-Safety in server.js"
# ============================================================================
# typeof null === "object" is true in JS, so checks like
# `typeof x === "object" ? x : {}` will pass null through.
# The pattern must be `x && typeof x === "object"` to exclude null.
python3 - <<'PY'
import re, sys

with open("codex-dashboard/server.js") as f:
    lines = f.readlines()

# Pattern: typeof <something> === "object" WITHOUT a preceding truthiness check
# Bad:  task && typeof task.foo === "object" ? task.foo : {}
# Good: task && task.foo && typeof task.foo === "object" ? task.foo : {}
# We check lines where .execution_context or .failure_context is accessed
unsafe = []
for i, line in enumerate(lines, 1):
    # Look for patterns like: typeof EXPR === "object" where EXPR contains a dot
    # and there's no preceding truthiness check for EXPR itself
    for field in ["execution_context", "failure_context", "execution"]:
        pattern = rf'typeof\s+\w+\.{field}\s*===\s*"object"'
        if re.search(pattern, line):
            # Check if there's a truthiness guard: EXPR &&
            guard = rf'\.\s*{field}\s+&&\s+typeof'
            if not re.search(guard, line):
                unsafe.append(f"  Line {i}: missing null guard for .{field}")

if unsafe:
    for u in unsafe:
        print(f"  \033[31m✗\033[0m {u}")
    print(f"  \033[31m✗\033[0m Found {len(unsafe)} null-unsafe typeof checks — will crash on null values")
    sys.exit(1)
else:
    print(f"  \033[32m✓\033[0m All typeof 'object' checks are null-safe")
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# ============================================================================
section "17. Claude Provider Auth"
# ============================================================================
# run_claude_exec must NOT override HOME (breaks auth with user's real credentials)
# Extract the claude exec function and check for HOME= (not CODEX_HOME=)
claude_func_home=$(awk '/^run_claude_exec\(\)/,/^[a-z_]*\(\)|^}/' scripts/lib.sh 2>/dev/null | grep -E '^\s+.*HOME="' | grep -v 'CODEX_HOME' || true)
if [ -n "$claude_func_home" ]; then
  fail "run_claude_exec overrides HOME — claude CLI will use stale tokens"
else
  pass "run_claude_exec preserves real user HOME for auth"
fi

# Verify claude CLI is available (warn only, not fail — codex fallback works)
if command -v claude >/dev/null 2>&1; then
  pass "claude CLI is installed"
else
  warn "claude CLI not found — tasks will only use codex provider"
fi

# ============================================================================
section "18. Dashboard API Smoke Test"
# ============================================================================
# If server is running, verify the API responds without crashing
if command -v curl >/dev/null 2>&1; then
  dashboard_response=$(curl -s --connect-timeout 2 --max-time 5 http://localhost:3211/api/status 2>/dev/null || true)
  if [ -n "$dashboard_response" ]; then
    # Verify it's valid JSON
    if echo "$dashboard_response" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
      pass "Dashboard /api/status responds with valid JSON"
      # Check that status fields exist
      state=$(echo "$dashboard_response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || true)
      if [ -n "$state" ]; then
        pass "Dashboard reports state=$state"
      else
        warn "Dashboard /api/status has no 'state' field"
      fi
    else
      fail "Dashboard /api/status returns invalid JSON"
    fi
  else
    warn "Dashboard not reachable on port 3211 (not running or port differs)"
  fi

  # Test /api/dashboard endpoint (this was the crashing endpoint)
  dashboard_full=$(curl -s --connect-timeout 2 --max-time 5 http://localhost:3211/api/dashboard 2>/dev/null || true)
  if [ -n "$dashboard_full" ]; then
    if echo "$dashboard_full" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'status' in d" 2>/dev/null; then
      pass "Dashboard /api/dashboard responds without crashing"
    else
      fail "Dashboard /api/dashboard response missing 'status' key"
    fi
  else
    warn "Dashboard /api/dashboard not reachable"
  fi
else
  warn "curl not available — skipping API smoke test"
fi

# ============================================================================
section "19. Runtime Environment"
# ============================================================================
# Check agentctl runtime env file
if [ -f codex-logs/agentctl-runtime.env ]; then
  pass "agentctl-runtime.env exists"

  runtime_port=$(awk -F= '$1=="dashboard_port" { print $2 }' codex-logs/agentctl-runtime.env 2>/dev/null || true)
  if [ -n "$runtime_port" ]; then
    pass "Runtime port configured: $runtime_port"
  else
    fail "Runtime port not configured in agentctl-runtime.env"
  fi

  runtime_scheme=$(awk -F= '$1=="dashboard_scheme" { print $2 }' codex-logs/agentctl-runtime.env 2>/dev/null || true)
  if [ "$runtime_scheme" = "http" ] || [ "$runtime_scheme" = "https" ]; then
    pass "Runtime scheme configured: $runtime_scheme"
  else
    warn "Runtime scheme not set (defaults to http)"
  fi
else
  warn "agentctl-runtime.env not found (system may not have been started yet)"
fi

# ============================================================================
section "20. Python Dependencies"
# ============================================================================
if command -v python3 >/dev/null 2>&1; then
  pass "python3 is available"
  # Check that embedded Python in lib.sh can parse
  if python3 -c "import json, sys, os, re, hashlib, tempfile, time; from datetime import datetime, timedelta, timezone; from pathlib import Path; from collections import Counter" 2>/dev/null; then
    pass "All required Python stdlib modules available"
  else
    fail "Some Python stdlib modules missing"
  fi
else
  fail "python3 not found — many scripts will fail"
fi

# ============================================================================
section "21. Multi-Queue Worker Config"
# ============================================================================
# Verify queue worker count is sane
if grep -q 'QUEUE_WORKERS.*4' scripts/agentctl.sh 2>/dev/null || \
   grep -q 'QUEUE_WORKERS_DEFAULT.*4' scripts/multi-queue.sh 2>/dev/null; then
  pass "Default queue workers set to 4"
else
  warn "Queue workers default may differ from expected 4"
fi

# Verify poll interval
if grep -q 'QUEUE_POLL_SECONDS.*1' scripts/agentctl.sh 2>/dev/null; then
  pass "Queue poll interval defaults to 1s"
else
  warn "Queue poll interval may differ from expected 1s"
fi

# ============================================================================
section "22. Status File"
# ============================================================================
if [ -f status.txt ]; then
  pass "status.txt exists"
  # Verify it has expected fields
  for field in state project task updated_at; do
    if grep -q "^${field}=" status.txt 2>/dev/null; then
      pass "status.txt has $field field"
    else
      warn "status.txt missing $field field"
    fi
  done
else
  warn "status.txt not found (no task has run yet)"
fi

# ============================================================================
section "23. Registry Compaction Config"
# ============================================================================
if [ -f scripts/compact-registry.sh ]; then
  # Verify retention is bounded (was reduced from 30 to 10)
  if grep -q 'keep_terminal.*=.*terminal\[:1[0-9]\]' scripts/compact-registry.sh 2>/dev/null; then
    pass "Registry compaction retains bounded terminal tasks"
  else
    warn "Registry compaction retention limit not verified"
  fi
else
  warn "compact-registry.sh not found"
fi

# ============================================================================
# Summary
# ============================================================================
printf '\n\033[1m══ Summary ══\033[0m\n'
printf '  \033[32m✓ Passed: %d\033[0m\n' "$PASS"
if [ "$WARN" -gt 0 ]; then
  printf '  \033[33m⚠ Warnings: %d\033[0m\n' "$WARN"
fi
if [ "$FAIL" -gt 0 ]; then
  printf '  \033[31m✗ Failed: %d\033[0m\n' "$FAIL"
  printf '\n\033[31mFailing tests:%s\033[0m\n' "$ERRORS"
  exit 1
else
  printf '\n  \033[32mAll tests passed — system is in a stable execution state.\033[0m\n'
  exit 0
fi
