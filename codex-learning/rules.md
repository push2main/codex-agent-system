# Learned Rules

- Inspect the relevant existing code and data paths before making any edit.
- Prefer reusing existing persisted data and structures; introduce new schema only when clearly necessary.
- Keep each task to one small, isolated change; avoid combining multiple subsystems in one update.
- Load only the minimal project context needed for the targeted change.
- Verify the change with a lightweight check focused on intended behavior and unrelated regressions.

