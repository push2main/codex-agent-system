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

ensure_runtime_dirs

FAKE_BIN_DIR="$TMP_DIR/bin"
PROJECT_DIR="$TMP_DIR/project"
OUTPUT_FILE="$TMP_DIR/output.json"
RAW_LOG_FILE="${OUTPUT_FILE}.codex.log"
ENV_CAPTURE_FILE="$TMP_DIR/codex-home.txt"
SYSTEM_LOG_SNAPSHOT="$TMP_DIR/system.log.after"
NOISE_LINE="readonly-db-noise-for-test"

mkdir -p "$FAKE_BIN_DIR" "$PROJECT_DIR"

cat >"$FAKE_BIN_DIR/codex" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

output_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\n' "${CODEX_HOME:-}" >"$ENV_CAPTURE_FILE"
printf '%s\n' "readonly-db-noise-for-test" >&2
printf '{"status":"success","message":"ok","data":{}}\n' >"$output_file"
EOF
chmod +x "$FAKE_BIN_DIR/codex"

SYSTEM_LOG_LINE_COUNT="$(wc -l <"$SYSTEM_LOG" 2>/dev/null || printf '0')"

PATH="$FAKE_BIN_DIR:$PATH" ENV_CAPTURE_FILE="$ENV_CAPTURE_FILE" run_codex_exec test-role "$PROJECT_DIR" "test prompt" "$OUTPUT_FILE"

tail -n +"$((SYSTEM_LOG_LINE_COUNT + 1))" "$SYSTEM_LOG" >"$SYSTEM_LOG_SNAPSHOT" 2>/dev/null || true

[ -s "$OUTPUT_FILE" ]
[ -s "$RAW_LOG_FILE" ]
grep -q "$NOISE_LINE" "$RAW_LOG_FILE"
! grep -q "$NOISE_LINE" "$SYSTEM_LOG_SNAPSHOT"

[ "$(cat "$ENV_CAPTURE_FILE")" = "$CODEX_RUNTIME_HOME" ]

echo "codex exec logging test passed"
