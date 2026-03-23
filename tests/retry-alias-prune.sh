#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs/queue-retries" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects"

printf '1\n' >"$TEST_ROOT/codex-logs/queue-retries/codex-agent-system__legacy_retry_alias.retry"
printf '2\n' >"$TEST_ROOT/codex-logs/queue-retries/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.retry"

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  ensure_runtime_dirs
)

test ! -e "$TEST_ROOT/codex-logs/queue-retries/codex-agent-system__legacy_retry_alias.retry"
grep -qx '2' "$TEST_ROOT/codex-logs/queue-retries/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.retry"

echo "retry alias prune test passed"
