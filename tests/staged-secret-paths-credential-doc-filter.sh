#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/scripts/." "$TEST_ROOT/scripts"

git -C "$TEST_ROOT" init -q
git -C "$TEST_ROOT" checkout -q -b main
git -C "$TEST_ROOT" config user.name 'Test User'
git -C "$TEST_ROOT" config user.email 'test@example.com'
echo "fixture" >"$TEST_ROOT/README.md"
git -C "$TEST_ROOT" add README.md
git -C "$TEST_ROOT" commit -q -m 'initial'

ROOT_DIR="$TEST_ROOT" bash -lc '
  set -Eeuo pipefail
  source "$ROOT_DIR/scripts/lib.sh"

  mkdir -p "$ROOT_DIR/codex-memory"
  cat >"$ROOT_DIR/codex-memory/self-improve-inventory-add-credential-recovery-trigger-coverage-to-telemetry-event-sche.md" <<'\''EOF'\''
# Inventory
EOF
  git -C "$ROOT_DIR" add codex-memory/self-improve-inventory-add-credential-recovery-trigger-coverage-to-telemetry-event-sche.md
  inventory_matches="$(staged_secret_paths "$ROOT_DIR")"
  if [ -n "$inventory_matches" ]; then
    echo "inventory artifact was incorrectly flagged as sensitive: $inventory_matches" >&2
    exit 1
  fi

  git -C "$ROOT_DIR" reset -q HEAD -- codex-memory/self-improve-inventory-add-credential-recovery-trigger-coverage-to-telemetry-event-sche.md
  rm -f "$ROOT_DIR/codex-memory/self-improve-inventory-add-credential-recovery-trigger-coverage-to-telemetry-event-sche.md"

  mkdir -p "$ROOT_DIR/config"
  printf "{}\n" >"$ROOT_DIR/config/credentials.json"
  git -C "$ROOT_DIR" add config/credentials.json
  credentials_matches="$(staged_secret_paths "$ROOT_DIR")"
  printf "%s" "$credentials_matches" | grep -Fq "config/credentials.json"
'

echo "staged secret path credential doc filter test passed"
