# Prompt Rules

- Inspect the relevant repository files before editing, and identify the single source of truth for the feature first.
- Reuse existing schemas, storage paths, and UI patterns instead of adding parallel flows.
- Keep each change small and end-to-end; avoid bundling multiple new behaviors in one pass.
- Verify the exact changed path after editing with at least one direct repo-local check.
- If permissions or external state block the task, say so immediately and limit work to safe local changes.
