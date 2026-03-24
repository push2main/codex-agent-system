# Prompt Rules

- Start by copying the exact logic, filters, thresholds, and file scope named in the step before considering any alternative implementation.
- Prefer the smallest localized change in an existing codepath; do not restructure, rename fields, or add extra behavior unless the step explicitly asks for it.
- Treat inspect, inventory, and report steps as read-only unless the task explicitly requires a patch.
- Run only the required verification command, and report the exact pass/fail outcome without adding extra checks.
- If the task is broad, reduce it to one deterministic subproblem tied to the specified files and persisted data, because broad exploration correlates with retries and timeouts.

