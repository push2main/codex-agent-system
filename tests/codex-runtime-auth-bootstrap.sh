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
RUNTIME_AUTH_FILE="$CODEX_RUNTIME_HOME/auth.json"
SHARED_AUTH_FILE="$CODEX_SHARED_HOME/auth.json"

mkdir -p "$FAKE_BIN_DIR" "$PROJECT_DIR" "$CODEX_SHARED_HOME"
cat >"$SHARED_AUTH_FILE" <<'EOF'
{"auth_mode":"chatgpt","tokens":{"id_token":"placeholder"}}
EOF
chmod 600 "$SHARED_AUTH_FILE"

cat >"$FAKE_BIN_DIR/codex" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

[ -f "${CODEX_HOME:?}/auth.json" ] || exit 91
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

printf '{"status":"success","message":"ok","data":{}}\n' >"$output_file"
EOF
chmod +x "$FAKE_BIN_DIR/codex"

PATH="$FAKE_BIN_DIR:$PATH" run_codex_exec test-role "$PROJECT_DIR" "test prompt" "$OUTPUT_FILE"

[ -f "$RUNTIME_AUTH_FILE" ]
cmp -s "$SHARED_AUTH_FILE" "$RUNTIME_AUTH_FILE"
[ "$(stat -f '%Lp' "$RUNTIME_AUTH_FILE")" = "600" ]
[ -s "$OUTPUT_FILE" ]

echo "codex runtime auth bootstrap test passed"
