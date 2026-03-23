#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
BIN_DIR="$TMP_DIR/bin"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT" "$BIN_DIR"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects"

cat >"$BIN_DIR/codex" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
sleep 3
EOF
chmod +x "$BIN_DIR/codex"

(
  cd "$TEST_ROOT"
  PATH="$BIN_DIR:$PATH"
  AGENT_EXEC_TIMEOUT_SECONDS=1
  source "$TEST_ROOT/scripts/lib.sh"

  output_file="$TEST_ROOT/codex-logs/timeout-agent.json"
  if run_codex_exec "timeout-test" "$TEST_ROOT" "return json" "$output_file"; then
    echo "run_codex_exec unexpectedly succeeded for timeout fixture" >&2
    exit 1
  fi

  test ! -s "$output_file"
  grep -q '^TIMEOUT after 1 seconds:' "$output_file.codex.log"
  grep -q 'codex exec timed out after 1s; using fallback logic' "$TEST_ROOT/codex-logs/system.log"
)

echo "agent exec timeout test passed"
