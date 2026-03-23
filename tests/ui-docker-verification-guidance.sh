#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

ui_guidance="$(build_verification_guidance \
  "Refine the mobile dashboard for iPhone and iPad widths" \
  "Run screenshot verification for the updated dashboard layout")"

printf '%s' "$ui_guidance" | grep -q 'bash scripts/run-playwright-docker.sh bash tests/dashboard-screenshot-verification.sh'
printf '%s' "$ui_guidance" | grep -q 'UPDATE_DASHBOARD_SCREENSHOT_BASELINES=1'

generic_guidance="$(build_verification_guidance "Persist approval-time execution brief snapshots" "")"
printf '%s' "$generic_guidance" | grep -q 'Use one deterministic verification command'

echo "ui docker verification guidance test passed"
