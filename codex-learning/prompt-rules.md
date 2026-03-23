# Prompt Rules

- For UI tasks, name the exact file, selectors, and media-query ranges to edit, and forbid changes outside those scopes.
- Make each step do one small action only: inspect, then edit, then verify, instead of mixing read, design, and implementation in one prompt.
- Require the agent to restate the current values or lines it found before editing, so retries stay grounded in the actual file.
- Add one deterministic acceptance check tied to the task, such as verifying only the targeted CSS blocks changed and the file still parses cleanly.
- After a retry-triggered failure, shrink the next prompt further to one mobile layout adjustment and one pass/fail verification.

