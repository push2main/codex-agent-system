# Learned Rules

- Confirm the command, paths, and working directory before execution.
- Keep scope narrow: for run-only tasks, run the requested command first and avoid unrelated fixes.
- If a blocking auth, provider, or environment error appears, state it clearly and stop.
- Keep actions sequential and outcome-focused: verify prerequisites, run the command, then report the first blocker.
- Reuse a previously successful command only when the task and context are the same.

