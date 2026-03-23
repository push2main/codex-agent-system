# Prompt Rules

- Restate the exact file, allowed edit scope, and forbidden changes before making any modification.
- Split the work into two prompts: first inspect and list the exact existing selectors to touch, then edit only those selectors.
- When a task says "existing CSS rules only," forbid adding selectors, media queries, markup, or script changes.
- Make verification a separate read-only step that checks literal diff constraints and reports a clear pass/fail result.
- If the task text is truncated or ambiguous, stop and ask for the missing requirement instead of inferring it.

