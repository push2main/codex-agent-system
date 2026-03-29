#!/usr/bin/env bash
# Test suite for system improvement changes (2026-03-25)
# Tests: classify_failure patterns, environment pre-check, strategy gate, orchestrator exit codes
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
    printf '  ✓ %s\n' "$test_name"
  else
    FAIL=$((FAIL + 1))
    printf '  ✗ %s — expected "%s", got "%s"\n' "$test_name" "$expected" "$actual" >&2
  fi
}

assert_contains() {
  local test_name="$1" expected_substr="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$actual" | grep -qF "$expected_substr"; then
    PASS=$((PASS + 1))
    printf '  ✓ %s\n' "$test_name"
  else
    FAIL=$((FAIL + 1))
    printf '  ✗ %s — expected to contain "%s", got "%s"\n' "$test_name" "$expected_substr" "$actual" >&2
  fi
}

# ================================================================
# TEST GROUP 1: classify_retry_failure — expanded environment patterns
# ================================================================
printf '\n=== Test Group 1: classify_retry_failure patterns ===\n'

result="$(classify_retry_failure "Plugin [id: 'com.android.application'] was not found")"
assert_eq "Gradle plugin not found → missing_environment" "missing_environment" "$result"

result="$(classify_retry_failure "gradle plugin com.android.library could not resolve")"
assert_eq "Gradle plugin resolve failure → missing_environment" "missing_environment" "$result"

result="$(classify_retry_failure "gradlew not found in PATH")"
assert_eq "gradlew not found → missing_environment" "missing_environment" "$result"

result="$(classify_retry_failure "Could not determine Android SDK from compileSdk")"
assert_eq "Android SDK reference → missing_environment" "missing_environment" "$result"

result="$(classify_retry_failure "JAVA_HOME is not set")"
assert_eq "JAVA_HOME not set → missing_environment" "missing_environment" "$result"

# Note: "command not found" matches missing_dependency first in classify_retry_failure
# The finer-grained classify_failure handles missing_build_tool separately
result="$(classify_retry_failure "xcodebuild: command not found")"
assert_eq "xcodebuild missing → missing_dependency (coarse bucket)" "missing_dependency" "$result"

result="$(classify_retry_failure "flutter: command not found")"
assert_eq "flutter missing → missing_dependency (coarse bucket)" "missing_dependency" "$result"

result="$(classify_retry_failure "connection timed out after 30s")"
assert_eq "Timeout → timeout" "timeout" "$result"

result="$(classify_retry_failure "just a normal coding task with no errors")"
assert_eq "Normal text → unknown" "unknown" "$result"

result="$(classify_retry_failure "Coder reported failure; retry required.")"
assert_eq "Fallback coder failure → coder_blocked" "coder_blocked" "$result"

result="$(classify_retry_failure "Verification step lacks evidence; retry required.")"
assert_eq "Fallback verification evidence gap → review_rejection" "review_rejection" "$result"

result="$(classify_retry_failure "Implementation artifact is missing or incomplete.")"
assert_eq "Fallback missing artifact → coder_blocked" "coder_blocked" "$result"

result="$(classify_retry_failure "Step evaluation failed. Review requested another attempt for this step.")"
assert_eq "Fallback evaluator retry request → evaluation_failure" "evaluation_failure" "$result"

result="$(classify_retry_failure "Docusaurus scaffold exists but node_modules is missing — dependencies were not installed.")"
assert_eq "Missing node_modules install → missing_dependency" "missing_dependency" "$result"

result="$(classify_retry_failure "android gradle plugin version 8.2.2 not available")"
assert_eq "android gradle plugin → missing_environment" "missing_environment" "$result"

result="$(classify_retry_failure "kotlin android extensions plugin deprecated")"
assert_eq "kotlin android → missing_environment" "missing_environment" "$result"

result="$(classify_retry_failure "gradle compileDebugKotlin failed with java.net.SocketException: Operation not permitted while starting the daemon")"
assert_eq "sandbox-blocked gradle → sandbox_restriction" "sandbox_restriction" "$result"

# ================================================================
# TEST GROUP 2: classify_failure — non-retriable detection
# ================================================================
printf '\n=== Test Group 2: classify_failure non-retriable detection ===\n'

result="$(classify_failure "gradle plugin com.android.application was not found" "" 1)"
is_retriable="$(printf '%s' "$result" | jq -r '.retriable')"
category="$(printf '%s' "$result" | jq -r '.category')"
assert_eq "Gradle plugin failure → non-retriable" "false" "$is_retriable"
assert_eq "Gradle plugin failure → missing_environment" "missing_environment" "$category"

result="$(classify_failure "android sdk location not configured" "" 1)"
is_retriable="$(printf '%s' "$result" | jq -r '.retriable')"
assert_eq "Android SDK missing → non-retriable" "false" "$is_retriable"

result="$(classify_failure "rate limit exceeded" "" 1)"
is_retriable="$(printf '%s' "$result" | jq -r '.retriable')"
assert_eq "Rate limit → retriable" "true" "$is_retriable"

# Pattern requires "sandbox" + "perm" or "blocked by" + "policy"
result="$(classify_failure "blocked by sandbox policy: npm install not permitted" "" 1)"
is_retriable="$(printf '%s' "$result" | jq -r '.retriable')"
category="$(printf '%s' "$result" | jq -r '.category')"
assert_eq "Sandbox restriction → non-retriable" "false" "$is_retriable"
assert_eq "Sandbox restriction → sandbox_restriction" "sandbox_restriction" "$category"

result="$(classify_failure "Run ./gradlew :app:compileDebugKotlin --no-daemon. If it fails because the Android SDK path is missing, report it." "Gradle failed with java.net.SocketException: Operation not permitted while starting the daemon socket in this sandbox." 1)"
is_retriable="$(printf '%s' "$result" | jq -r '.retriable')"
category="$(printf '%s' "$result" | jq -r '.category')"
assert_eq "Sandbox-blocked gradle → non-retriable" "false" "$is_retriable"
assert_eq "Sandbox-blocked gradle → sandbox_restriction" "sandbox_restriction" "$category"

result="$(classify_failure "something completely unknown happened" "" 2)"
is_retriable="$(printf '%s' "$result" | jq -r '.retriable')"
assert_eq "Unknown after attempt 2 → non-retriable" "false" "$is_retriable"

result="$(classify_failure "something completely unknown happened" "" 1)"
is_retriable="$(printf '%s' "$result" | jq -r '.retriable')"
assert_eq "Unknown after attempt 1 → retriable (one chance)" "true" "$is_retriable"

# ================================================================
# TEST GROUP 3: check_task_environment_requirements
# ================================================================
printf '\n=== Test Group 3: Environment pre-check ===\n'

result="$(check_task_environment_requirements "Build Android dashboard screen with Jetpack Compose" "superheld")"
blocked="$(printf '%s' "$result" | jq -r '.blocked')"
blocker="$(printf '%s' "$result" | jq -r '.blocker')"
assert_eq "Android task without SDK → blocked" "true" "$blocked"
assert_eq "Android task blocker name" "android_environment" "$blocker"

result="$(check_task_environment_requirements "Migrate Android app from XML layouts to Jetpack Compose" "superheld")"
blocked="$(printf '%s' "$result" | jq -r '.blocked')"
assert_eq "Jetpack Compose migration → blocked" "true" "$blocked"

result="$(check_task_environment_requirements "Set up Kotlin Multiplatform KMP project with Android target" "superheld")"
blocked="$(printf '%s' "$result" | jq -r '.blocked')"
assert_eq "KMP Android task → blocked" "true" "$blocked"

result="$(check_task_environment_requirements "Improve retry logic in orchestrator.sh" "codex-agent-system")"
blocked="$(printf '%s' "$result" | jq -r '.blocked')"
assert_eq "Shell script task → not blocked" "false" "$blocked"

result="$(check_task_environment_requirements "Add error handling to the dashboard Node.js server" "codex-agent-system")"
blocked="$(printf '%s' "$result" | jq -r '.blocked')"
assert_eq "Node.js task → not blocked" "false" "$blocked"

result="$(check_task_environment_requirements "Create GDPR compliance documentation" "codex-agent-system")"
blocked="$(printf '%s' "$result" | jq -r '.blocked')"
assert_eq "Documentation task → not blocked" "false" "$blocked"

result="$(check_task_environment_requirements "Build iOS app with SwiftUI" "superheld")"
blocked="$(printf '%s' "$result" | jq -r '.blocked')"
blocker="$(printf '%s' "$result" | jq -r '.blocker')"
assert_eq "iOS task without Xcode → blocked" "true" "$blocked"
assert_eq "iOS task blocker name" "ios_environment" "$blocker"

result="$(check_task_environment_requirements "Create flutter mobile app" "superheld")"
blocked="$(printf '%s' "$result" | jq -r '.blocked')"
assert_eq "Flutter task without SDK → blocked" "true" "$blocked"

# ================================================================
# TEST GROUP 4: Strategy gate logic (unit test via python)
# ================================================================
printf '\n=== Test Group 4: Strategy queue gate logic ===\n'

gate_check() {
  local sr="$1" qs="$2" pressure="$3" saturation="$4"
  python3 -c "
import sys
sr = float(sys.argv[1])
qs = int(sys.argv[2])
pressure = sys.argv[3] == 'true'
saturation = sys.argv[4] == 'true'
block = (sr < 0.25 and qs >= 5) or (sr < 0.15) or pressure or saturation
print('blocked' if block else 'open')
" "$sr" "$qs" "$pressure" "$saturation"
}

result="$(gate_check 0.12 77 true true)"
assert_eq "12% success, 77 queue, pressure+saturation → blocked" "blocked" "$result"

result="$(gate_check 0.10 0 false false)"
assert_eq "10% success, 0 queue → blocked (< 15% always blocks)" "blocked" "$result"

result="$(gate_check 0.20 8 false false)"
assert_eq "20% success, 8 queue → blocked (< 25% and >= 5)" "blocked" "$result"

result="$(gate_check 0.30 3 false false)"
assert_eq "30% success, 3 queue → open" "open" "$result"

result="$(gate_check 0.50 20 false false)"
assert_eq "50% success, 20 queue → open" "open" "$result"

result="$(gate_check 0.50 20 true false)"
assert_eq "50% success but pressure → blocked" "blocked" "$result"

result="$(gate_check 0.50 2 false true)"
assert_eq "50% success but saturation → blocked" "blocked" "$result"

result="$(gate_check 0.26 4 false false)"
assert_eq "26% success, 4 queue → open (above both thresholds)" "open" "$result"

# ================================================================
# TEST GROUP 5: Bash syntax validation of modified files
# ================================================================
printf '\n=== Test Group 5: Bash syntax validation ===\n'

for script in \
  "$ROOT_DIR/scripts/lib.sh" \
  "$ROOT_DIR/agents/orchestrator.sh" \
  "$ROOT_DIR/scripts/strategy-loop.sh" \
  "$ROOT_DIR/scripts/queue-worker.sh" \
  "$ROOT_DIR/agents/planner.sh"; do
  TOTAL=$((TOTAL + 1))
  if bash -n "$script" 2>/dev/null; then
    PASS=$((PASS + 1))
    printf '  ✓ %s syntax OK\n' "$(basename "$script")"
  else
    FAIL=$((FAIL + 1))
    printf '  ✗ %s has syntax errors\n' "$(basename "$script")" >&2
  fi
done

# ================================================================
# SUMMARY
# ================================================================
printf '\n======================================\n'
printf 'RESULTS: %d/%d passed, %d failed\n' "$PASS" "$TOTAL" "$FAIL"
printf '======================================\n'

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
