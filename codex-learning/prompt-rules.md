# Prompt Rules

- Confirm the exact command, script paths, and working directory before running anything.
- For run-only tasks, do not widen scope to fixes or unrelated inspection unless the command fails.
- If a provider or auth issue appears, state it plainly and stop instead of padding with unrelated findings.
- Keep each step tied to one concrete outcome: inspect prerequisites, run the command, or extract the first blocking error.
- Reuse known-good commands that recently succeeded when the task is identical.

