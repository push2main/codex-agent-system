#!/usr/bin/env bash
set -Eeuo pipefail

readonly DASHBOARD_SCREENSHOT_FIXED_MTIME="202603221018.00"

dashboard_screenshot_fixture_root() {
  local script_dir root_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root_dir="$(cd "$script_dir/../.." && pwd)"
  printf '%s\n' "$root_dir/tests/fixtures/dashboard-screenshot"
}

copy_dashboard_screenshot_fixture_file() {
  local source_file target_file
  source_file="${1:?source file is required}"
  target_file="${2:?target file is required}"

  cp "$source_file" "$target_file"
  touch -t "$DASHBOARD_SCREENSHOT_FIXED_MTIME" "$target_file"
}

create_dashboard_screenshot_fixture() {
  local fixture_dir target_root
  fixture_dir="$(dashboard_screenshot_fixture_root)"
  target_root="${1:?target root is required}"

  mkdir -p \
    "$target_root/projects/dashboard-snapshots" \
    "$target_root/queues" \
    "$target_root/codex-memory" \
    "$target_root/codex-logs" \
    "$target_root/codex-learning"

  copy_dashboard_screenshot_fixture_file "$fixture_dir/tasks.json" "$target_root/codex-memory/tasks.json"
  copy_dashboard_screenshot_fixture_file "$fixture_dir/dashboard-settings.json" "$target_root/codex-memory/dashboard-settings.json"
  copy_dashboard_screenshot_fixture_file "$fixture_dir/priority.json" "$target_root/codex-memory/priority.json"
  copy_dashboard_screenshot_fixture_file "$fixture_dir/tasks.log" "$target_root/codex-memory/tasks.log"
  copy_dashboard_screenshot_fixture_file "$fixture_dir/system.log" "$target_root/codex-logs/system.log"
  copy_dashboard_screenshot_fixture_file "$fixture_dir/strategy-latest.json" "$target_root/codex-logs/strategy-latest.json"
  copy_dashboard_screenshot_fixture_file "$fixture_dir/metrics.json" "$target_root/codex-learning/metrics.json"
  copy_dashboard_screenshot_fixture_file "$fixture_dir/status.txt" "$target_root/status.txt"
  copy_dashboard_screenshot_fixture_file "$fixture_dir/queues/dashboard-snapshots.txt" "$target_root/queues/dashboard-snapshots.txt"
}

dashboard_screenshot_viewports_file() {
  local fixture_dir
  fixture_dir="$(dashboard_screenshot_fixture_root)"
  printf '%s\n' "$fixture_dir/viewports.json"
}

dashboard_screenshot_baseline_dir() {
  local fixture_dir
  fixture_dir="$(dashboard_screenshot_fixture_root)"
  printf '%s\n' "$fixture_dir/baselines"
}
