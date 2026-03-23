# Prompt Rules

- Keep the prompt pinned to one small change in one named file, and state the exact guard or threshold to edit.
- For tasks that already succeeded once, prefer the same provider and approach unless the failure shows a clear code defect.
- If the task involves queue drain or low-completion behavior, require an inspect-first step that names the current counters and seeding guard before any edit.
- Require deterministic JSON output from every role, and explicitly forbid schema drift or free-form review text.
- Ask for one narrow verification that proves the target edge case without broad refactors, routing changes, or retry-policy changes.

