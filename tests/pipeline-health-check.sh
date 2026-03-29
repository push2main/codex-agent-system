#!/usr/bin/env bash
# Pipeline Health Check — verifies the full task execution pipeline is functional.
# Run: bash tests/pipeline-health-check.sh
# Exit 0 = all checks pass, Exit 1 = one or more checks failed.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
WARN=0

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  [PASS] $label"
    ((PASS++))
  else
    echo "  [FAIL] $label"
    ((FAIL++))
  fi
}

warn_check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  [PASS] $label"
    ((PASS++))
  else
    echo "  [WARN] $label"
    ((WARN++))
  fi
}

echo "=== 1. Script Syntax Checks ==="
for script in "$ROOT_DIR"/scripts/*.sh; do
  check "Syntax: $(basename "$script")" bash -n "$script"
done

echo ""
echo "=== 2. Required Files Exist ==="
check "tasks.json exists"        test -f "$ROOT_DIR/codex-memory/tasks.json"
check "tasks-archive.json exists" test -f "$ROOT_DIR/codex-memory/tasks-archive.json"
check "server.js exists"         test -f "$ROOT_DIR/codex-dashboard/server.js"
check "lib.sh exists"            test -f "$ROOT_DIR/scripts/lib.sh"
check "multi-queue.sh exists"    test -f "$ROOT_DIR/scripts/multi-queue.sh"
check "queue-worker.sh exists"   test -f "$ROOT_DIR/scripts/queue-worker.sh"
check "dual-provider.sh exists"  test -f "$ROOT_DIR/scripts/dual-provider.sh"
check "agentctl.sh exists"       test -f "$ROOT_DIR/scripts/agentctl.sh"
check "Queue dir exists"         test -d "$ROOT_DIR/queues"

echo ""
echo "=== 3. server.js Syntax Check ==="
check "server.js Node syntax" node --check "$ROOT_DIR/codex-dashboard/server.js"

echo ""
echo "=== 4. Task Registry Integrity ==="
check "tasks.json valid JSON" python3 -c "import json; json.loads(open('$ROOT_DIR/codex-memory/tasks.json').read())"
check "tasks.json has tasks array" python3 -c "
import json
d = json.loads(open('$ROOT_DIR/codex-memory/tasks.json').read())
assert isinstance(d.get('tasks'), list), 'tasks is not a list'
"
check "tasks-archive.json valid JSON" python3 -c "import json; json.loads(open('$ROOT_DIR/codex-memory/tasks-archive.json').read())"

echo ""
echo "=== 5. Registry Pressure ==="
python3 -c "
import os
size = os.path.getsize('$ROOT_DIR/codex-memory/tasks.json')
print(f'  Registry size: {size}B (threshold: 400000B)')
exit(0 if size < 400000 else 1)
" && ((PASS++)) || { echo "  [WARN] Registry exceeds pressure threshold"; ((WARN++)); }

echo ""
echo "=== 6. Task Status Distribution ==="
python3 -c "
import json
from collections import Counter
tasks = json.loads(open('$ROOT_DIR/codex-memory/tasks.json').read()).get('tasks', [])
c = Counter((t.get('status','').strip().lower()) for t in tasks)
for s, n in c.most_common():
    print(f'  {s}: {n}')
total = len(tasks)
approved = c.get('approved', 0)
running = c.get('running', 0)
print(f'  total: {total}')
print(f'  actionable (approved+running): {approved + running}')
"

echo ""
echo "=== 7. Queue State ==="
for qf in "$ROOT_DIR"/queues/*.txt; do
  count=$(wc -l < "$qf" 2>/dev/null | tr -d ' ')
  echo "  $(basename "$qf"): $count entries"
done

echo ""
echo "=== 8. Bash 3 Compatibility (macOS) ==="
# Check for bash 4+ features that break on macOS default bash
for script in "$ROOT_DIR"/scripts/*.sh; do
  if grep -qE ';&|;;&|\|&|mapfile|readarray|declare -A|coproc ' "$script" 2>/dev/null; then
    echo "  [FAIL] $(basename "$script") uses bash 4+ features"
    ((FAIL++))
  else
    echo "  [PASS] $(basename "$script") bash 3 compatible"
    ((PASS++))
  fi
done

echo ""
echo "=== 9. Root Failure Demotion Active ==="
check "Demotion constant in server.js" grep -q "ROOT_FAILURE_DEMOTION_THRESHOLD" "$ROOT_DIR/codex-dashboard/server.js"
check "shouldDemoteRoot function exists" grep -q "function shouldDemoteRoot" "$ROOT_DIR/codex-dashboard/server.js"
check "countRootFailures function exists" grep -q "function countRootFailures" "$ROOT_DIR/codex-dashboard/server.js"

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "=========================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
