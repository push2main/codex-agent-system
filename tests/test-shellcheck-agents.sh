#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Phase 1: bash -n syntax validation (always available, no external deps)
syntax_fail=0
syntax_count=0
for f in "$ROOT_DIR"/agents/*.sh "$ROOT_DIR"/scripts/*.sh; do
  [[ -f "$f" ]] || continue
  ((syntax_count++)) || true
  if ! bash -n "$f" 2>/dev/null; then
    echo "SYNTAX FAIL: $f"
    bash -n "$f" 2>&1 || true
    ((syntax_fail++)) || true
  fi
done

if [[ "$syntax_fail" -gt 0 ]]; then
  echo "FAIL: $syntax_fail of $syntax_count file(s) have syntax errors"
  exit 1
fi
echo "OK: $syntax_count files pass bash -n syntax check"

# Phase 2: shellcheck lint (skip gracefully if not installed)
if ! command -v shellcheck &>/dev/null; then
  echo "SKIP: shellcheck not installed — syntax-only validation passed"
  exit 0
fi

lint_fail=0
for f in "$ROOT_DIR"/agents/*.sh "$ROOT_DIR"/scripts/*.sh; do
  [[ -f "$f" ]] || continue
  if shellcheck -S warning "$f" >/dev/null 2>&1; then
    echo "PASS: $f"
  else
    echo "LINT FAIL: $f"
    shellcheck -S warning "$f" || true
    ((lint_fail++)) || true
  fi
done

if [[ "$lint_fail" -gt 0 ]]; then
  echo "FAIL: $lint_fail file(s) have shellcheck warnings"
  exit 1
fi

echo "OK: all $syntax_count files pass shellcheck lint"
