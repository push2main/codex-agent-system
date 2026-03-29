# Codex Dashboard — UI Integration Test & Evaluation Report

**Date:** 2026-03-25
**Dashboard URL:** http://localhost:3211
**System State:** Running / Retrying (4 active workers)

---

## Test Results by Page

### Overview Page — PASS (with caveats)
- System Status card renders correctly: state badge, current project, active task title, worker count, last update timestamp
- Codex Auth health indicator works
- Bounded Experiment status displays correctly
- Health & Throughput metric cards all render with live data
- "Retry Last Failed Task" button present
- **Bug:** Metrics are always global — project switcher has no effect on Overview numbers

### Task Board — PASS (with caveats)
- Task cards render with title, project, category, status badge, "View details" expander
- Comfort/Compact layout toggle works
- Search bar present with helpful hint text
- Pending Approval column with Bulk Approve/Reject buttons
- Ready To Execute column shows correct task count per project
- Task list correctly filters when switching projects
- **Bug:** Tab counts (Actionable 79, Pending 0, Approved 79, Other 52, All 131) are always global — they don't update when a project is selected

### Queue Page — PASS
- Lists queued tasks with QUEUED status badge and project label
- Correctly filters by project when switcher changes
- Clean, scannable layout

### Add Task Page — PASS (with caveats)
- Form fields: Task, Context/Why, Success Criteria, Constraints, Affected Files/Areas, Depends On
- "Add To Board" button with note about approval backlog
- Prompt Intake section for natural-language task decomposition
- **Bug:** Stale "Failed to fetch" error persists from a previous failed submission (no auto-clear)
- **Bug:** Prompt Intake shows "Reload drift detected" and is unavailable (needs system restart)

### Analytics Page — PASS (with caveats)
- Execution timeline chart (Total/Success/Failure over time)
- Success Rate Over Time chart
- Average Duration Over Time chart
- Breakdown By Provider donut chart (codex, claude, unknown)
- Result Distribution donut (FAILURE vs SUCCESS)
- Avg Attempts By Provider bar chart
- Recent Execution Records table with all columns
- **Bug:** "Breakdown By Project" bar chart has Y-axis max of 1.0 — bars are barely visible, likely a normalization or data format issue

### Logs Page — PASS
- Raw runtime output with timestamps and subsystem labels
- Shows real-time entries from all components (orchestrator, queue-worker, memory-sync, safety, learner, evaluator, reviewer)
- Monospace font, dark background — good readability

### Project Switcher — PARTIAL PASS
- Dropdown correctly lists: All Projects, codex-agent-system, superheld
- Task Board task list: **filters correctly**
- Queue page: **filters correctly**
- Overview Health & Throughput: **does NOT filter** (always global)
- Task Board tab counts: **do NOT filter** (always global)
- Analytics charts: **do NOT filter** (always global)
- System Status section: always shows the currently running task's project regardless of selection

---

## Bugs Found

| # | Severity | Page | Description |
|---|----------|------|-------------|
| 1 | Medium | Overview | Health & Throughput metrics ignore project filter — always show global aggregates |
| 2 | Medium | Task Board | Tab counts (Actionable/Pending/Approved/Other/All) ignore project filter |
| 3 | Low | Add Task | Stale "Failed to fetch" error not cleared on page revisit |
| 4 | Low | Add Task | Prompt Intake unavailable due to reload drift (runtime hash mismatch) |
| 5 | Low | Analytics | "Breakdown By Project" bar chart Y-axis scaling is wrong (max 1.0) |

### Root Cause Analysis (Bugs 1 & 2)

The `/api/dashboard`, `/api/metrics`, and `/api/task-registry` endpoints return pre-computed global summaries. They don't accept a `?project=` query parameter. The `summarizeTaskRegistry()` function always operates on the full task array. The frontend receives global counts and has no way to filter them per project.

**Fix approach:** Either:
- (A) Server-side: Accept `?project=` on `/api/task-registry` and `/api/metrics`, filter tasks before computing summary stats
- (B) Client-side: The frontend already receives the full task list from `/api/task-registry` — compute tab counts and metric cards client-side from the filtered subset

Option (B) is simpler and avoids API changes, but option (A) is more correct for large registries.

---

## Improvement Recommendations

### High Priority

1. **Project-aware metrics**: Implement project filtering for Overview metrics and Task Board tab counts. This is the main usability gap — the project switcher creates a false expectation that all data is scoped.

2. **Clear error state on Add Task page**: Reset the "Failed to fetch" message when navigating to the page or after a timeout.

3. **Fix Breakdown By Project chart**: The Y-axis normalization is broken. Should show absolute task counts per project, not a 0-1 scale.

### Medium Priority

4. **Auto-refresh indicator**: The Overview page updates in real-time but there's no visual indicator of when data was last refreshed. Add a "Last updated X seconds ago" timestamp.

5. **Task detail expansion**: The "View details" links on Task Board cards should show plan steps, execution context, and failure history inline.

6. **Logs page filtering**: Add log level filtering (INFO/WARN/ERROR) and text search. Currently it's raw output with no interactivity.

7. **Analytics time range selector**: Allow filtering analytics by time window (last hour, last 24h, last 7d) instead of showing all data.

### Low Priority

8. **Empty state for Pending Approval**: The "No pending approval tasks" text could be more helpful — suggest what would cause tasks to appear there.

9. **Mobile responsiveness**: The dashboard has a mobile-first rule in `.claude/rules` but the current layout would benefit from testing at 375px.

10. **Prompt Intake reliability**: The reload drift detection should either auto-recover or provide a one-click restart button instead of just showing "Unavailable".

11. **Task Board search**: The search placeholder says "Search title, project, category, notes" but it's unclear if it searches across all tabs or only the active one.
