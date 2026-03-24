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
mkdir -p "$TEST_ROOT/projects/codex-agent-system"

cat >"$TEST_ROOT/projects/codex-agent-system/project.json" <<'EOF'
{
  "project": "codex-agent-system",
  "workspace": "/tmp/repo"
}
EOF

cat >"$TEST_ROOT/projects/codex-agent-system/spec.md" <<'EOF'
# Project Spec

Goal: Make planner and coder use project steering and source metadata.
EOF

cat >"$TEST_ROOT/projects/codex-agent-system/policy.json" <<'EOF'
{
  "project": "codex-agent-system",
  "risk_profile": "standard",
  "rules": ["small changes only"]
}
EOF

cat >"$TEST_ROOT/projects/codex-agent-system/sources.json" <<'EOF'
{
  "project": "codex-agent-system",
  "sources": [
    {
      "path": "projects/codex-agent-system/spec.md",
      "type": "reference",
      "relevance": "high",
      "trust": "high"
    }
  ]
}
EOF

CONTEXT_OUTPUT="$(
  cd "$TEST_ROOT"
  bash -lc 'source scripts/lib.sh; build_prompt_source_context "improve planner context" "respect project policy" "codex-agent-system"'
)"

printf '%s\n' "$CONTEXT_OUTPUT" | grep -F 'FILE projects/codex-agent-system/spec.md' >/dev/null
printf '%s\n' "$CONTEXT_OUTPUT" | grep -F 'FILE projects/codex-agent-system/policy.json' >/dev/null
printf '%s\n' "$CONTEXT_OUTPUT" | grep -F 'FILE projects/codex-agent-system/sources.json' >/dev/null

echo "project source context test passed"
