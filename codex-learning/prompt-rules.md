# Prompt Rules

- Keep the change to one named file and one named guard or constant when the task is an infra behavior tweak.
- Require a quick inspect-first step that lists the current counters, thresholds, and exact condition before editing.
- Ask for one deterministic verification command, and if it fails, require reporting the failing line or error instead of retrying blindly.
- Prefer a small threshold or condition adjustment over new logic, schema changes, or routing changes.
- When recent runs show timeouts or retry churn, bias the prompt toward shorter edits and faster verification.

