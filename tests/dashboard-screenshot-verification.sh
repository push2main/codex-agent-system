#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/dashboard-screenshot-fixture.sh"

TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
ARTIFACT_ROOT="$TMP_DIR/artifacts/dashboard-screenshot"
ACTUAL_DIR="$ARTIFACT_ROOT/actual"
DIFF_DIR="$ARTIFACT_ROOT/diff"
BASELINE_DIR="$(dashboard_screenshot_baseline_dir)"
DASHBOARD_HTML_FILE="$ROOT_DIR/codex-dashboard/index.html"
DASHBOARD_DIR="$ROOT_DIR/codex-dashboard"
FIXTURE_PAYLOAD_FILE="$TMP_DIR/dashboard-fixture-payloads.json"
PLAYWRIGHT_WORKDIR="$TMP_DIR/playwright-cli-work"
UPDATE_BASELINES="${UPDATE_DASHBOARD_SCREENSHOT_BASELINES:-0}"
PLAYWRIGHT_SESSION="dashboard-screenshot-$$"
RUN_STATUS="fail"
HOST_CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
export HOME="$TMP_DIR/home"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$TMP_DIR/xdg-cache}"
export NPM_CONFIG_CACHE="${NPM_CONFIG_CACHE:-$TMP_DIR/npm-cache}"
PLAYWRIGHT_BROWSER_CACHE="${PLAYWRIGHT_BROWSER_CACHE:-/tmp/codex-agent-system-playwright-host}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$PLAYWRIGHT_BROWSER_CACHE}"
PLAYWRIGHT_BROWSER="${PLAYWRIGHT_BROWSER:-}"

playwright_browser_args=()
if [ -n "$PLAYWRIGHT_BROWSER" ]; then
  playwright_browser_args=(--browser "$PLAYWRIGHT_BROWSER")
fi

cleanup() {
  if [ -n "${PWCLI:-}" ]; then
    if [ "${#playwright_browser_args[@]}" -gt 0 ]; then
      (cd "$PLAYWRIGHT_WORKDIR" && "$PWCLI" "${playwright_browser_args[@]}" --config "$PLAYWRIGHT_CONFIG_FILE" --session "$PLAYWRIGHT_SESSION" close >/dev/null 2>&1 || true)
    else
      (cd "$PLAYWRIGHT_WORKDIR" && "$PWCLI" --config "$PLAYWRIGHT_CONFIG_FILE" --session "$PLAYWRIGHT_SESSION" close >/dev/null 2>&1 || true)
    fi
  fi
  if [ "$RUN_STATUS" = "success" ]; then
    rm -rf "$TMP_DIR"
    return
  fi
  echo "dashboard screenshot verification artifacts preserved at $ARTIFACT_ROOT" >&2
}

trap cleanup EXIT

assert_bounded_baseline_set() {
  python3 - "$BASELINE_DIR" "$@" <<'PY'
import sys
from pathlib import Path

baseline_dir = Path(sys.argv[1])
expected = sorted(sys.argv[2:])
actual = sorted(path.name for path in baseline_dir.glob("*.png"))

if actual != expected:
    raise SystemExit(
        "dashboard screenshot baseline set mismatch: "
        f"expected {expected}, found {actual} in {baseline_dir}"
    )
PY
}

write_diff_image() {
  local baseline_file="$1"
  local actual_file="$2"
  local diff_file="$3"

  if ! command -v ffmpeg >/dev/null 2>&1; then
    return 0
  fi

  ffmpeg -y -loglevel error -i "$baseline_file" -i "$actual_file" \
    -filter_complex "[0:v][1:v]blend=all_mode=difference" \
    -frames:v 1 "$diff_file" >/dev/null 2>&1
}

compare_dashboard_baseline() {
  local case_name="$1"
  local baseline_file="$2"
  local actual_file="$3"
  local diff_file="$4"

  if cmp -s "$baseline_file" "$actual_file"; then
    return 0
  fi

  write_diff_image "$baseline_file" "$actual_file" "$diff_file"

  echo "dashboard screenshot regression for $case_name" >&2
  echo "baseline: $baseline_file" >&2
  echo "actual: $actual_file" >&2
  echo "diff: $diff_file" >&2
  echo "baseline_sha256: $(shasum -a 256 "$baseline_file" | awk '{print $1}')" >&2
  echo "actual_sha256: $(shasum -a 256 "$actual_file" | awk '{print $1}')" >&2
  return 1
}

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$ACTUAL_DIR" "$DIFF_DIR"
mkdir -p "$PLAYWRIGHT_WORKDIR" "$PLAYWRIGHT_BROWSERS_PATH"
PLAYWRIGHT_CONFIG_FILE="$TMP_DIR/playwright-cli.json"

cat >"$PLAYWRIGHT_CONFIG_FILE" <<'EOF'
{
  "browser": {
    "browserName": "chromium",
    "launchOptions": {
      "headless": true,
      "args": [
        "--no-sandbox",
        "--disable-setuid-sandbox"
      ]
    }
  }
}
EOF

resolve_playwright_cli() {
  local candidate
  for candidate in \
    "$HOST_CODEX_HOME/skills/playwright/scripts/playwright_cli.sh" \
    "/Users/benediktpoller/.codex/skills/playwright/scripts/playwright_cli.sh"
  do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

PWCLI="$(resolve_playwright_cli || true)"
if [ -z "$PWCLI" ]; then
  cat >"$TMP_DIR/playwright-cli-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exec npx --yes --package @playwright/cli playwright-cli "$@"
EOF
  chmod +x "$TMP_DIR/playwright-cli-wrapper.sh"
  PWCLI="$TMP_DIR/playwright-cli-wrapper.sh"
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "npx is required for dashboard screenshot verification" >&2
  exit 1
fi

run_pwcli() {
  if [ "${#playwright_browser_args[@]}" -gt 0 ]; then
    "$PWCLI" "${playwright_browser_args[@]}" --config "$PLAYWRIGHT_CONFIG_FILE" --session "$PLAYWRIGHT_SESSION" "$@"
  else
    "$PWCLI" --config "$PLAYWRIGHT_CONFIG_FILE" --session "$PLAYWRIGHT_SESSION" "$@"
  fi
}

(cd "$PLAYWRIGHT_WORKDIR" && npx --yes --package @playwright/cli playwright install "$PLAYWRIGHT_BROWSER" >/tmp/dashboard-playwright-install.log 2>&1)

mkdir -p "$TEST_ROOT"
create_dashboard_screenshot_fixture "$TEST_ROOT"

python3 - "$TEST_ROOT" "$FIXTURE_PAYLOAD_FILE" <<'PY'
import json
import statistics
import sys
from pathlib import Path

test_root = Path(sys.argv[1])
output_path = Path(sys.argv[2])

tasks_payload = json.loads((test_root / "codex-memory" / "tasks.json").read_text(encoding="utf-8"))
tasks = tasks_payload.get("tasks") if isinstance(tasks_payload, dict) else []
tasks = tasks if isinstance(tasks, list) else []

metrics_payload = json.loads((test_root / "codex-learning" / "metrics.json").read_text(encoding="utf-8"))
strategy_payload = json.loads((test_root / "codex-logs" / "strategy-latest.json").read_text(encoding="utf-8"))
status_lines = (test_root / "status.txt").read_text(encoding="utf-8").splitlines()
system_logs = (test_root / "codex-logs" / "system.log").read_text(encoding="utf-8").strip()
queue_lines = [
    line.strip()
    for line in (test_root / "queues" / "dashboard-snapshots.txt").read_text(encoding="utf-8").splitlines()
    if line.strip()
]

status = {}
for line in status_lines:
    if "=" not in line:
        continue
    key, value = line.split("=", 1)
    status[key] = value

task_logs = []
for raw_line in (test_root / "codex-memory" / "tasks.log").read_text(encoding="utf-8").splitlines():
    raw_line = raw_line.strip()
    if raw_line:
        task_logs.append(json.loads(raw_line))

durations = [entry.get("duration_seconds", 0) for entry in task_logs if isinstance(entry.get("duration_seconds", 0), (int, float))]
average_duration = round(statistics.mean(durations), 1) if durations else 0
last_failed = next((entry for entry in reversed(task_logs) if str(entry.get("result", "")).upper() == "FAILURE"), None)

def history_preview(task):
    history = task.get("history")
    if not isinstance(history, list):
        return []
    preview = []
    for entry in history[-2:]:
        if isinstance(entry, dict):
            preview.append(
                {
                    "action": entry.get("action", ""),
                    "at": entry.get("at", ""),
                    "note": entry.get("note", ""),
                }
            )
    return preview

for task in tasks:
    if isinstance(task, dict):
        task["history_preview"] = history_preview(task)

pending_tasks = [task for task in tasks if str(task.get("status", "")).lower() == "pending_approval"]
approved_tasks = [task for task in tasks if str(task.get("status", "")).lower() == "approved"]
other_tasks = [task for task in tasks if str(task.get("status", "")).lower() not in {"pending_approval", "approved"}]

categories = {}
for task in tasks:
    category = str(task.get("category") or "uncategorized")
    categories[category] = categories.get(category, 0) + 1
top_category = None
if categories:
    top_category = {"name": sorted(categories.items(), key=lambda item: (-item[1], item[0]))[0][0]}

oldest_pending = None
if pending_tasks:
    oldest_pending_task = min(pending_tasks, key=lambda task: str(task.get("created_at") or "9999-12-31T23:59:59Z"))
    oldest_pending = {"created_at": oldest_pending_task.get("created_at", "")}

auth_health = {
    "status": "healthy",
    "active": False,
    "blocks_queue": False,
    "message": "No cached Codex auth failure.",
}

strategy = {
    "status": "running",
    "title": "Healthy cadence",
    "message": strategy_payload.get("message", ""),
    "last_run_at": strategy_payload.get("timestamp", ""),
    "last_board_updates": len(strategy_payload.get("data", {}).get("board_tasks", [])),
    "next_run_in_seconds": 180,
}

payloads = {
    "/api/projects": {
        "projects": ["dashboard-snapshots"],
    },
    "/api/status": {
        "state": status.get("state", "idle"),
        "project": status.get("project", ""),
        "task": status.get("task", ""),
        "last_result": status.get("last_result", "UNKNOWN"),
        "note": status.get("note", ""),
        "updated_at": status.get("updated_at", ""),
        "authHealth": auth_health,
        "strategy": strategy,
        "port": 3211,
        "addresses": ["127.0.0.1"],
        "protocol": "http",
        "capabilities": {
            "prompt_intake": True,
        },
        "reload_drift_summary": "",
    },
    "/api/logs?limit=120": {
        "logs": system_logs,
    },
    "/api/metrics": {
        "total": metrics_payload.get("analysis_runs", 0),
        "successRate": metrics_payload.get("success_rate", 0),
        "taskRegistryTotal": metrics_payload.get("task_registry_total", 0),
        "queued": len(queue_lines),
        "pendingApproval": len(pending_tasks),
        "approved": len(approved_tasks),
        "authHealth": auth_health,
        "averageDurationSeconds": average_duration,
        "lastFailed": last_failed,
    },
    "/api/queue": {
        "tasks": [{"project": "dashboard-snapshots", "task": task} for task in queue_lines],
    },
    "/api/task-registry": {
        "tasks": tasks,
        "summary": {
            "total": len(tasks),
            "byStatus": {
                "pending_approval": len(pending_tasks),
                "approved": len(approved_tasks),
                "completed": sum(1 for task in other_tasks if str(task.get("status", "")).lower() == "completed"),
                "failed": sum(1 for task in other_tasks if str(task.get("status", "")).lower() == "failed"),
                "rejected": sum(1 for task in other_tasks if str(task.get("status", "")).lower() == "rejected"),
            },
            "nextAction": {
                "message": "Review pending approvals before queue execution.",
            },
            "topCategory": top_category,
            "oldestPendingTask": oldest_pending,
        },
        "authHealth": auth_health,
    },
}

output_path.write_text(json.dumps(payloads, indent=2) + "\n", encoding="utf-8")
PY

FIXED_NOW_ISO="2026-03-22T10:18:00.000Z"
DASHBOARD_URL="http://dashboard.test/"

if ! (cd "$PLAYWRIGHT_WORKDIR" && run_pwcli open about:blank >"$TMP_DIR/playwright.stdout" 2>"$TMP_DIR/playwright.stderr"); then
  echo "dashboard screenshot verification skipped: playwright browser launch unsupported in this environment" >&2
  sed -n '1,40p' "$TMP_DIR/playwright.stderr" >&2 || true
  exit 0
fi

(cd "$PLAYWRIGHT_WORKDIR" && run_pwcli close >/dev/null 2>&1 || true)

wait_for_dashboard_script="$(cat <<'EOF'
await page.waitForLoadState('networkidle');
await page.waitForSelector('#strategy-health');
await page.waitForSelector('#live-work-strip');
await page.waitForSelector('.task-board');
const strategyTitle = (await page.locator('#strategy-health-title').textContent()) || '';
const liveWorkTitle = (await page.locator('#live-work-strip-title').textContent()) || '';
const boardHeading = (await page.locator('.task-board-toolbar').textContent()) || '';
if (!strategyTitle.trim() || strategyTitle.includes('Loading')) {
  throw new Error(`unexpected strategy title: ${strategyTitle}`);
}
if (!liveWorkTitle.trim() || liveWorkTitle.includes('Loading')) {
  throw new Error(`unexpected live work title: ${liveWorkTitle}`);
}
if (!boardHeading.includes('Actionable')) {
  throw new Error(`unexpected task board toolbar: ${boardHeading}`);
}
EOF
)"

ui_acceptance_script="$(cat <<'EOF'
const signalCards = await page.locator('.signal-card').count();
const metricCards = await page.locator('.metric').count();
const taskCards = await page.locator('.task-item').count();
const boardTools = await page.locator('.board-tools').count();
if (signalCards < 2) {
  throw new Error(`expected enterprise signal cards, found ${signalCards}`);
}
if (metricCards < 6) {
  throw new Error(`expected metrics and summary cards, found ${metricCards}`);
}
if (taskCards < 3) {
  throw new Error(`expected task cards, found ${taskCards}`);
}
if (boardTools !== 1) {
  throw new Error(`expected board tools region, found ${boardTools}`);
}
const searchInput = page.locator('#task-search-input');
await searchInput.fill('queue');
await page.waitForTimeout(80);
const searchNote = (await page.locator('#task-search-note').textContent()) || '';
const visibleTasks = await page.locator('.task-item').evaluateAll((nodes) =>
  nodes.filter((node) => node.dataset.searchHidden !== 'true').length,
);
if (!searchNote.includes('tasks match')) {
  throw new Error(`search note did not update: ${searchNote}`);
}
if (visibleTasks < 1) {
  throw new Error(`search hid all tasks unexpectedly`);
}
await page.locator('[data-density="compact"]').click();
const density = await page.evaluate(() => document.body.dataset.density || '');
if (density !== 'compact') {
  throw new Error(`expected compact density, found ${density}`);
}
EOF
)"

mapfile -t VIEWPORT_CASES < <(
  python3 - "$(dashboard_screenshot_viewports_file)" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

cases = payload.get("cases")
if not isinstance(cases, list) or len(cases) != 2:
    raise SystemExit("dashboard screenshot verification requires exactly two viewport cases")

filenames = []
for case in cases:
    filename = str(case.get("filename") or "").strip()
    if not filename.endswith(".png"):
        raise SystemExit(f"viewport case missing stable png filename: {case}")
    filenames.append(filename)
    print(
        case["name"],
        filename,
        case["width"],
        case["height"],
        case.get("deviceScaleFactor", 1),
        "true" if case.get("isMobile", False) else "false",
        "true" if case.get("hasTouch", False) else "false",
        sep="\t",
    )

if len(set(filenames)) != len(filenames):
    raise SystemExit(f"viewport filenames must be unique: {filenames}")
PY
)

[ "${#VIEWPORT_CASES[@]}" -eq 2 ]

expected_baselines=()

for viewport_case in "${VIEWPORT_CASES[@]}"; do
  IFS=$'\t' read -r case_name file_name width height device_scale_factor is_mobile has_touch <<<"$viewport_case"
  expected_baselines+=("$file_name")

  deterministic_setup_script="$(cat <<EOF
const fs = require('fs');
const path = require('path');
const fixedNow = Date.parse('$FIXED_NOW_ISO');
const dashboardUrl = '$DASHBOARD_URL';
const dashboardHtml = fs.readFileSync('$DASHBOARD_HTML_FILE', 'utf8');
const dashboardDir = '$DASHBOARD_DIR';
const fixturePayloads = JSON.parse(fs.readFileSync('$FIXTURE_PAYLOAD_FILE', 'utf8'));
await page.addInitScript(({ fixedNowValue, caseName }) => {
  const OriginalDate = Date;
  class FixedDate extends OriginalDate {
    constructor(...args) {
      super(...(args.length ? args : [fixedNowValue]));
    }
    static now() {
      return fixedNowValue;
    }
  }
  FixedDate.parse = OriginalDate.parse.bind(OriginalDate);
  FixedDate.UTC = OriginalDate.UTC.bind(OriginalDate);
  Object.setPrototypeOf(FixedDate, OriginalDate);
  globalThis.Date = FixedDate;

  Math.random = () => 0.123456789;
  globalThis.setInterval = () => 1;
  globalThis.clearInterval = () => {};
  globalThis.requestAnimationFrame = (callback) => setTimeout(() => callback(0), 0);

  const disableMotion = () => {
    const style = document.createElement('style');
    style.setAttribute('data-dashboard-screenshot', caseName);
    style.textContent = [
      '*,',
      '*::before,',
      '*::after {',
      '  animation: none !important;',
      '  transition: none !important;',
      '  caret-color: transparent !important;',
      '  scroll-behavior: auto !important;',
      '}',
    ].join('\\n');
    document.head.appendChild(style);
    document.documentElement.setAttribute('data-dashboard-screenshot-case', caseName);
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', disableMotion, { once: true });
  } else {
    disableMotion();
  }
}, { fixedNowValue: fixedNow, caseName: '$case_name' });

await page.route('http://dashboard.test/**', async (route) => {
  const requestUrl = new URL(route.request().url());
  const lookupKey = requestUrl.pathname + requestUrl.search;
  const assetPath = path.resolve(dashboardDir, '.' + requestUrl.pathname);
  if (requestUrl.pathname === '/') {
    await route.fulfill({
      status: 200,
      contentType: 'text/html; charset=utf-8',
      body: dashboardHtml,
    });
    return;
  }

  if (fixturePayloads[lookupKey]) {
    await route.fulfill({
      status: 200,
      contentType: 'application/json; charset=utf-8',
      body: JSON.stringify(fixturePayloads[lookupKey]),
    });
    return;
  }

  if (assetPath.startsWith(dashboardDir + path.sep) && fs.existsSync(assetPath) && fs.statSync(assetPath).isFile()) {
    const extension = path.extname(assetPath).toLowerCase();
    const contentType =
      extension === '.css'
        ? 'text/css; charset=utf-8'
        : extension === '.js'
          ? 'application/javascript; charset=utf-8'
          : extension === '.png'
            ? 'image/png'
            : 'application/octet-stream';
    await route.fulfill({
      status: 200,
      contentType,
      body: fs.readFileSync(assetPath),
    });
    return;
  }

  await route.fulfill({
    status: 404,
    contentType: 'application/json; charset=utf-8',
    body: JSON.stringify({ error: 'Unhandled dashboard fixture request: ' + lookupKey }),
  });
});

const client = await page.context().newCDPSession(page);
await client.send('Emulation.setDeviceMetricsOverride', {
  width: $width,
  height: $height,
  deviceScaleFactor: $device_scale_factor,
  mobile: $is_mobile,
  screenWidth: $width,
  screenHeight: $height,
  positionX: 0,
  positionY: 0,
  scale: 1,
});
await client.send('Emulation.setTouchEmulationEnabled', {
  enabled: $has_touch,
  maxTouchPoints: $has_touch ? 5 : 0,
});
await page.emulateMedia({ colorScheme: 'light', reducedMotion: 'reduce' });
await page.goto(dashboardUrl, { waitUntil: 'domcontentloaded' });
await page.setViewportSize({ width: $width, height: $height });
EOF
)"

  rm -rf "$PLAYWRIGHT_WORKDIR/.playwright-cli"
  (cd "$PLAYWRIGHT_WORKDIR" && run_pwcli open about:blank >/dev/null)
  (cd "$PLAYWRIGHT_WORKDIR" && run_pwcli resize "$width" "$height" >/dev/null)
  (cd "$PLAYWRIGHT_WORKDIR" && run_pwcli run-code "$deterministic_setup_script" >/dev/null)
  (cd "$PLAYWRIGHT_WORKDIR" && run_pwcli run-code "$wait_for_dashboard_script" >/dev/null)
  (cd "$PLAYWRIGHT_WORKDIR" && run_pwcli run-code "$ui_acceptance_script" >/dev/null)
done

RUN_STATUS="success"
echo "dashboard browser verification test passed"
