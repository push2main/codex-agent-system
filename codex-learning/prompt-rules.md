# Prompt Rules

- Start with the exact task path: inspect the named gate or file first, then act only on that verified path.
- If the task is a bounded patch, make the smallest deterministic code change and stop after verifying that specific behavior.
- When a provider or auth issue blocks execution, report it plainly and do not substitute unrelated findings as task progress.
- For timeout-prone tasks, avoid broad exploration and finish one concrete inspect-or-patch step within the first attempt.
- Reuse verified facts from prior failed runs, but still confirm the exact target files and helpers before changing code.

