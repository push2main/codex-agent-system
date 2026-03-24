# Prompt Rules

- Read the exact target files named in the task first, and mention the specific helper, endpoint, or UI section you will touch before editing.
- Make one bounded change that matches the requested output fields or layout exactly; do not add new schema, refactors, or extra behavior unless the task explicitly requires it.
- Reuse existing loaders, normalizers, and persistence paths whenever possible instead of inventing parallel code paths.
- If the task names exact selectors, media queries, fields, or insertion points, follow them literally and avoid modifying nearby unrelated code.
- Finish with one lightweight verification tied to the changed path, and report the concrete result or failure point.

