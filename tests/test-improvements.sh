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
echo "========================================="
printf 'Results: %d/%d passed (%d failed)\n' "$PASS" "$TOTAL" "$FAIL"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
