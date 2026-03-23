# Prompt Rules

- Restate the exact file, the allowed CSS-only scope, and the forbidden changes before making any edit.
- Read the existing selectors and media-query block first, then change only CSS values inside those confirmed selectors.
- Do not add, remove, or rename selectors, markup, scripts, or bindings when the task says to keep structure unchanged.
- Keep verification simple and deterministic: inspect the diff and confirm it contains only the intended CSS value changes.
- When a task includes truncation or ambiguity, stop and ask for the missing constraint instead of guessing.

