# Prompt Rules

- Separate read-only inspection from patching, and do not start editing until the exact source-of-truth lines and target file are confirmed.
- When a task names one file to patch, edit only that file and preserve existing keys, formats, and surrounding behavior.
- After every patch, run the single required verification command immediately and use its exact failure output to drive the next fix.
- If a command is mandatory for success, execute it directly instead of describing it or stopping at a summary.
- Favor one small deterministic change per step; avoid extra cleanup, refactors, or broadened scope that increase timeout and retry risk.

