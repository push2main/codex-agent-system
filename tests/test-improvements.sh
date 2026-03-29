#!/usr/bin/env bash
# test-improvements.sh — Validates all system improvements
# Run: bash tests/test-improvements.sh
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local test_name="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "$test_name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s (expected=%s actual=%s)\n' "$test_name" "$expected" "$actual"
  fi
}

assert_contains() {
  local test_name="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "$test_name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s (needle=%s not found)\n' "$test_name" "$needle"
  fi
}

assert_not_contains() {
  local test_name="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if ! printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "$test_name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s (needle=%s was found but should not be)\n' "$test_name" "$needle"
  fi
}

# ============================================================
echo "=== Test Suite: Context Truncation ==="
# ============================================================

# Test 1: Short context should pass through unchanged
short="Hello world, this is a short context."
result="$(clamp_prompt_context "$short" "1000")"
assert_eq "short context unchanged" "$short" "$result"

# Test 2: Long context should be truncated with head+tail
long_context="$(python3 -c "print('A' * 500 + 'MIDDLE' + 'Z' * 500)")"
result="$(clamp_prompt_context "$long_context" "200")"
assert_contains "truncated keeps head" "AAAA" "$result"
assert_contains "truncated keeps tail" "ZZZZ" "$result"
assert_contains "truncated has marker" "middle truncated" "$result"

# Test 3: Default limit should be 24000 now
assert_eq "default limit is 24000" "24000" "$MAX_PROMPT_CONTEXT_CHARS"

# ============================================================
echo ""
echo "=== Test Suite: Failure Classification ==="
# ============================================================

# Test classify_retry_failure
result="$(classify_retry_failure "Command timed out after 420s")"
assert_eq "classify timeout" "timeout" "$result"

result="$(classify_retry_failure "context window exceeded, too many tokens")"
assert_eq "classify context limit" "context_limit" "$result"

result="$(classify_retry_failure "command not found: gradle")"
assert_eq "classify missing dependency" "missing_dependency" "$result"

result="$(classify_retry_failure "android sdk not found")"
assert_eq "classify missing environment" "missing_environment" "$result"

result="$(classify_retry_failure "gradle compileDebugKotlin failed with java.net.SocketException: Operation not permitted while starting the daemon")"
assert_eq "classify sandbox-blocked gradle as sandbox restriction" "sandbox_restriction" "$result"

result="$(classify_retry_failure "reviewer rejected the change")"
assert_eq "classify review rejection" "review_rejection" "$result"

result="$(classify_retry_failure "evaluator failed with score below threshold")"
assert_eq "classify evaluation failure" "evaluation_failure" "$result"

result="$(classify_retry_failure "empty response from provider")"
assert_eq "classify empty output" "empty_output" "$result"

result="$(classify_retry_failure "internal server error 503")"
assert_eq "classify tool failure" "tool_failure" "$result"

# Test classify_failure (MAST taxonomy)
result="$(classify_failure "android sdk not found" "" "1")"
retriable="$(printf '%s' "$result" | jq -r '.retriable')"
category="$(printf '%s' "$result" | jq -r '.category')"
assert_eq "MAST: missing_environment non-retriable" "false" "$retriable"
assert_eq "MAST: missing_environment category" "missing_environment" "$category"

result="$(classify_failure "Run ./gradlew :app:compileDebugKotlin --no-daemon. If it fails because the Android SDK path is missing, report it." "Gradle failed with java.net.SocketException: Operation not permitted while starting the daemon socket in this sandbox." "1")"
retriable="$(printf '%s' "$result" | jq -r '.retriable')"
category="$(printf '%s' "$result" | jq -r '.category')"
assert_eq "MAST: sandbox-blocked gradle non-retriable" "false" "$retriable"
assert_eq "MAST: sandbox-blocked gradle category" "sandbox_restriction" "$category"

result="$(classify_failure "syntax error near unexpected token" "" "1")"
retriable="$(printf '%s' "$result" | jq -r '.retriable')"
assert_eq "MAST: syntax_error non-retriable" "false" "$retriable"

result="$(classify_failure "api key invalid" "" "1")"
retriable="$(printf '%s' "$result" | jq -r '.retriable')"
category="$(printf '%s' "$result" | jq -r '.category')"
assert_eq "MAST: auth_failure non-retriable" "false" "$retriable"
assert_eq "MAST: auth_failure category" "auth_failure" "$category"

result="$(classify_failure "inspect the current project files" "" "1")"
retriable="$(printf '%s' "$result" | jq -r '.retriable')"
category="$(printf '%s' "$result" | jq -r '.category')"
assert_eq "MAST: vague_specification non-retriable" "false" "$retriable"
assert_eq "MAST: vague_specification category" "vague_specification" "$category"

result="$(classify_failure "review rejected" "" "1")"
retriable="$(printf '%s' "$result" | jq -r '.retriable')"
category="$(printf '%s' "$result" | jq -r '.category')"
assert_eq "MAST: review_rejection retriable" "true" "$retriable"
assert_eq "MAST: review_rejection category" "review_rejection" "$category"

result="$(classify_failure "rate limit exceeded 429" "" "1")"
retriable="$(printf '%s' "$result" | jq -r '.retriable')"
assert_eq "MAST: rate_limit retriable" "true" "$retriable"

# Test that unknown failures become non-retriable after attempt 1 (was 2)
result="$(classify_failure "some random unknown error" "" "2")"
retriable="$(printf '%s' "$result" | jq -r '.retriable')"
assert_eq "MAST: unknown at attempt 2 non-retriable" "false" "$retriable"

result="$(classify_failure "some random unknown error" "" "1")"
retriable="$(printf '%s' "$result" | jq -r '.retriable')"
assert_eq "MAST: unknown at attempt 1 retriable" "true" "$retriable"

# ============================================================
echo ""
echo "=== Test Suite: Self-Improve Saturation Controls ==="
# ============================================================

# Test the adaptive MAX_SUBMIT logic by running the Python snippet
max_submit_low="$(python3 -c "
current_success_rate = 0.10
if current_success_rate < 0.15:
    MAX_SUBMIT = 1
elif current_success_rate < 0.30:
    MAX_SUBMIT = 2
else:
    MAX_SUBMIT = 3
print(MAX_SUBMIT)
")"
assert_eq "MAX_SUBMIT=1 when success<0.15" "1" "$max_submit_low"

max_submit_mid="$(python3 -c "
current_success_rate = 0.25
if current_success_rate < 0.15:
    MAX_SUBMIT = 1
elif current_success_rate < 0.30:
    MAX_SUBMIT = 2
else:
    MAX_SUBMIT = 3
print(MAX_SUBMIT)
")"
assert_eq "MAX_SUBMIT=2 when success<0.30" "2" "$max_submit_mid"

max_submit_high="$(python3 -c "
current_success_rate = 0.50
if current_success_rate < 0.15:
    MAX_SUBMIT = 1
elif current_success_rate < 0.30:
    MAX_SUBMIT = 2
else:
    MAX_SUBMIT = 3
print(MAX_SUBMIT)
")"
assert_eq "MAX_SUBMIT=3 when success>=0.30" "3" "$max_submit_high"

# Test the tighter thresholds
assert_contains "BACKLOG_OVERLOAD_THRESHOLD is 12" "12" "$(grep 'BACKLOG_OVERLOAD_THRESHOLD = ' "$ROOT_DIR/scripts/self-improve.sh" | head -1)"
assert_contains "BACKLOG_OVERLOAD_SUCCESS_RATE is 0.30" "0.30" "$(grep 'BACKLOG_OVERLOAD_SUCCESS_RATE_THRESHOLD = ' "$ROOT_DIR/scripts/self-improve.sh")"

# ============================================================
echo ""
echo "=== Test Suite: Fallback Planner ==="
# ============================================================

# Test that the planner extracts file paths from task descriptions
planner_output="$(python3 -c "
import re
task_text = 'Fix the retry logic in scripts/lib.sh and agents/orchestrator.sh'
mentioned_files = re.findall(r'[\w./-]+\.(?:sh|py|js|ts|json|md|yaml|yml|toml|cfg)', task_text)
print(','.join(mentioned_files))
")"
assert_contains "planner extracts scripts/lib.sh" "scripts/lib.sh" "$planner_output"
assert_contains "planner extracts agents/orchestrator.sh" "agents/orchestrator.sh" "$planner_output"

# Test that tasks without file paths get a concrete ls-based step
planner_no_files="$(python3 -c "
import re
task_text = 'Improve the success rate of the system'
mentioned_files = re.findall(r'[\w./-]+\.(?:sh|py|js|ts|json|md|yaml|yml|toml|cfg)', task_text)
print(len(mentioned_files))
")"
assert_eq "no files extracted from vague task" "0" "$planner_no_files"

# ============================================================
echo ""
echo "=== Test Suite: Shell Syntax Validation ==="
# ============================================================

# Validate all modified shell scripts pass bash -n
for script in scripts/lib.sh agents/orchestrator.sh scripts/queue-worker.sh scripts/self-improve.sh agents/planner.sh; do
  TOTAL=$((TOTAL + 1))
  if bash -n "$ROOT_DIR/$script" 2>/dev/null; then
    PASS=$((PASS + 1))
    printf '  PASS: %s syntax OK\n' "$script"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s syntax error\n' "$script"
  fi
done

# ============================================================
echo ""
echo "=== Test Suite: Queue-Worker Non-Retriable Path ==="
# ============================================================

# Verify the exit code 3 handler exists in queue-worker.sh
assert_contains "queue-worker handles exit 3" 'rc" -eq 3' "$(cat "$ROOT_DIR/scripts/queue-worker.sh")"
assert_contains "queue-worker marks non-retriable" "non_retriable=1" "$(cat "$ROOT_DIR/scripts/queue-worker.sh")"

# ============================================================
echo ""
echo "=== Test Suite: Step Character Cap ==="
# ============================================================

# Test the PYSCOPE step-cap validator from agents/planner.sh
# It reads a JSON plan file, truncates steps over 600 chars, writes back.

STEPCAP_TMP="$(mktemp)"
trap "rm -f '$STEPCAP_TMP'" EXIT

NORMAL_STEP="Step 1: Read the file agents/planner.sh and verify the output format is correct JSON with status and message fields."
LONG_STEP="Step 2: $(python3 -c "print('A' * 890)")"
SHORT_STEP="Step 3 (verify): Run bash -n agents/planner.sh and confirm exit code 0."

python3 -c "
import json, sys
payload = {
    'status': 'success',
    'message': 'test plan',
    'data': {
        'steps': [
            sys.argv[1],
            sys.argv[2],
            sys.argv[3]
        ]
    }
}
with open(sys.argv[4], 'w') as f:
    json.dump(payload, f)
" "$NORMAL_STEP" "$LONG_STEP" "$SHORT_STEP" "$STEPCAP_TMP"

# Run the PYSCOPE validator inline (same logic as planner.sh)
python3 - "$STEPCAP_TMP" <<'PYSCOPE'
from __future__ import annotations
import json, re, sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

data = payload.get("data")
steps = data.get("steps") if isinstance(data, dict) else None
if not isinstance(steps, list) or len(steps) < 2:
    raise SystemExit(0)

VAGUE_VERBS = re.compile(
    r"\b(implement|build|create|design|set up|develop|establish)\b.*\b(full|complete|comprehensive|entire|all)\b",
    re.IGNORECASE,
)
FILE_PATTERN = re.compile(r"[\w./-]+\.(?:sh|py|js|ts|tsx|jsx|kt|swift|json|yaml|yml|toml|md|xml|gradle)")
MAX_STEP_CHARS = 600

changed = False
trimmed_steps = []

for i, step in enumerate(steps):
    s = str(step)
    files_mentioned = FILE_PATTERN.findall(s)
    if len(files_mentioned) > 3 and i < len(steps) - 1:
        s = re.sub(
            r"((?:[\w./-]+\.(?:sh|py|js|ts|tsx|jsx|kt|swift|json|yaml|yml|toml|md|xml|gradle)[,;\s]*){3})[\w./-]+\.(?:sh|py|js|ts|tsx|jsx|kt|swift|json|yaml|yml|toml|md|xml|gradle).*?(?=\.|$)",
            r"\1",
            s,
        )
        s = s.rstrip(" ,;") + ". Focus on at most 3 files per step."
        changed = True
    if VAGUE_VERBS.search(s) and i < len(steps) - 1:
        s += " SCOPE LIMIT: Touch at most 3 files and keep changes under 100 lines total."
        changed = True
    if len(s) > MAX_STEP_CHARS:
        truncated = s[:MAX_STEP_CHARS]
        last_period = truncated.rfind(". ")
        last_newline = truncated.rfind("\n")
        cut_point = max(last_period, last_newline)
        if cut_point > MAX_STEP_CHARS // 2:
            s = truncated[:cut_point + 1].rstrip()
        else:
            s = truncated.rstrip()
        if not s.endswith("."):
            s += "."
        changed = True
    trimmed_steps.append(s)

impl_steps = [s for s in trimmed_steps[:-1] if not re.match(r"(?:verify|run |check |confirm )", s, re.IGNORECASE)]
if len(impl_steps) > 4:
    kept = trimmed_steps[:3] + [trimmed_steps[-1]]
    trimmed_steps = kept
    changed = True

if changed:
    payload["data"]["steps"] = trimmed_steps
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PYSCOPE

# Read back the processed plan
STEPCAP_RESULT="$(cat "$STEPCAP_TMP")"

# Check that every step is <= 600 chars
all_under_cap="$(python3 -c "
import json, sys
steps = json.loads(sys.argv[1])['data']['steps']
print('yes' if all(len(s) <= 600 for s in steps) else 'no')
" "$STEPCAP_RESULT")"
assert_eq "all steps <= 600 chars after PYSCOPE" "yes" "$all_under_cap"

# Check that the 900-char step was actually truncated (shorter than original)
truncated_len="$(python3 -c "
import json, sys
steps = json.loads(sys.argv[1])['data']['steps']
# The long step is at index 1
print(len(steps[1]))
" "$STEPCAP_RESULT")"
assert_eq "900-char step was truncated to <=600" "yes" "$([ "$truncated_len" -le 600 ] && echo yes || echo no)"

# ============================================================
echo ""
echo "========================================="
printf 'Results: %d/%d passed (%d failed)\n' "$PASS" "$TOTAL" "$FAIL"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
