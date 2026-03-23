# Prompt Rules

- Split file work into separate tasks: first inspect and record exact selectors, then edit, then verify.
- When a task says "edit only" a narrow area, restate the allowed selectors and forbid any markup, script, or selector-name changes.
- Quote the exact file path and literal selector strings from the file before changing CSS so the edit stays anchored to existing code.
- Keep verification minimal and deterministic: check the diff is limited to the named selectors and run one direct smoke test only if requested.
- Prefer one small CSS adjustment per attempt instead of combining layout redesign, responsive changes, and validation in the same prompt.

