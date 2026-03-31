#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/projects/.removed"
cp -R "$ROOT_DIR/scripts/." "$TEST_ROOT/scripts"

echo "removed_at=2026-03-30" >"$TEST_ROOT/projects/.removed/repo"

ROOT_DIR="$TEST_ROOT" PROJECTS_DIR="$TEST_ROOT/projects" bash -lc '
  set -Eeuo pipefail
  source "$ROOT_DIR/scripts/lib.sh"

  ensure_project_state "repo"
  if [ -e "$ROOT_DIR/projects/repo/project.json" ]; then
    echo "removed project metadata was recreated" >&2
    exit 1
  fi

  if resolve_project_workspace "repo" >/dev/null 2>&1; then
    echo "removed project unexpectedly resolved a workspace" >&2
    exit 1
  fi

  ensure_project_state "codex-agent-system"
  [ -f "$ROOT_DIR/projects/codex-agent-system/project.json" ]
'

echo "project removal tombstone test passed"
