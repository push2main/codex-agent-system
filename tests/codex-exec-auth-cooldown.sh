#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

source "$ROOT_DIR/scripts/lib.sh"

LOG_DIR="$TMP_DIR/logs"
RUNS_DIR="$TMP_DIR/runs"
SYSTEM_LOG="$LOG_DIR/system.log"
CODEX_RUNTIME_HOME="$TMP_DIR/codex-home"
CODEX_SHARED_HOME="$TMP_DIR/shared-home"

ensure_runtime_dirs

FAKE_BIN_DIR="$TMP_DIR/bin"
PROJECT_DIR="$TMP_DIR/project"
OUTPUT_FILE="$TMP_DIR/output.json"
RAW_LOG_FILE="${OUTPUT_FILE}.codex.log"
AUTH_FAILURE_FILE="$(codex_auth_failure_file)"
CALL_COUNT_FILE="$TMP_DIR/codex-call-count.txt"

mkdir -p "$FAKE_BIN_DIR" "$PROJECT_DIR"

cat >"$FAKE_BIN_DIR/codex" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

count_file="${CODEX_CALL_COUNT_FILE:?}"
count=0
if [ -f "$count_file" ]; then
  count="$(cat "$count_file")"
fi
count="$((count + 1))"
printf '%s\n' "$count" >"$count_file"

printf '%s\n' 'ERROR: unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: https://api.openai.com/v1/responses' >&2
exit 1
EOF
chmod +x "$FAKE_BIN_DIR/codex"

set +e
PATH="$FAKE_BIN_DIR:$PATH" CODEX_CALL_COUNT_FILE="$CALL_COUNT_FILE" CODEX_AUTH_FAILURE_COOLDOWN_SECONDS=3600 CODEX_SHARED_HOME="$CODEX_SHARED_HOME" run_codex_exec test-role "$PROJECT_DIR" "test prompt" "$OUTPUT_FILE"
first_rc=$?
PATH="$FAKE_BIN_DIR:$PATH" CODEX_CALL_COUNT_FILE="$CALL_COUNT_FILE" CODEX_AUTH_FAILURE_COOLDOWN_SECONDS=3600 CODEX_SHARED_HOME="$CODEX_SHARED_HOME" run_codex_exec test-role "$PROJECT_DIR" "test prompt" "$OUTPUT_FILE"
second_rc=$?
set -e

[ "$first_rc" -ne 0 ]
[ "$second_rc" -ne 0 ]
[ "$(cat "$CALL_COUNT_FILE")" = "1" ]
[ -f "$AUTH_FAILURE_FILE" ]
grep -q '401 Unauthorized' "$RAW_LOG_FILE"
grep -q 'Skipping codex exec because an authentication failure was detected recently' "$SYSTEM_LOG"

echo "codex exec auth cooldown test passed"
