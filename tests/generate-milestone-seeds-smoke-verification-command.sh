#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"
EXTERNAL_WORKSPACE="$TMP_DIR/superheld-repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p \
  "$REPO_ROOT/scripts" \
  "$REPO_ROOT/projects/superheld" \
  "$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts" \
  "$EXTERNAL_WORKSPACE/apps/cloud-brain/src" \
  "$EXTERNAL_WORKSPACE/packages/playbooks"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/projects/superheld/spec.md" <<'EOF'
# Project Spec

project: superheld

## First Milestones

9. Verify trigger-aware credential recovery routing in the smoke flow.
EOF

cat >"$REPO_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_WORKSPACE",
  "repo_url": "https://example.invalid/superheld",
  "spec_file": "$REPO_ROOT/projects/superheld/spec.md"
}
EOF

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts/smoke.mjs" <<'EOF'
console.log("smoke")
EOF

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/src/incident-flow.mjs" <<'EOF'
export function runIncidentFlow() {
  return "ok";
}

function resolveIncidentPlaybook(playbooks, incidentType, eventType) {
  return playbooks.find((playbook) => playbook.incident_type === incidentType && playbook.trigger_event_types.includes(eventType));
}
EOF

cat >"$EXTERNAL_WORKSPACE/packages/playbooks/account_recovery_after_credential_risk.json" <<'EOF'
{
  "incident_type": "account_recovery_after_credential_risk",
  "trigger_event_types": ["credential_recovery_trigger"]
}
EOF

generator_output="$(
  python3 "$REPO_ROOT/scripts/generate-milestone-seeds.py" --root "$REPO_ROOT" superheld
)"

printf '%s\n' "$generator_output" | jq -e '
  .status == "success" and
  .data.seed_count == 1 and
  .data.seeds[0].verification_command == "node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing" and
  (.data.seeds[0].success_signals | length) >= 2
' >/dev/null

echo "generate milestone seeds smoke verification command test passed"
