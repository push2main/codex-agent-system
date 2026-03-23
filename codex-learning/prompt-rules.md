# Prompt Rules

- State the exact file, constant, and condition to change, and forbid unrelated edits.
- Prefer small infrastructure tasks with bounded logic over broad UI or cross-system requests.
- Require one inspect-first step to confirm current counters, guards, or thresholds before patching.
- Require one deterministic verification that proves the target edge case with clear pass/fail output.
- Enforce strict structured output for every role so review and evaluation cannot fail on schema drift.

