# Learned Rules

- State the exact change target and forbid reusing deprecated names before editing.
- Keep the patch limited to the relevant existing code path and named files.
- Reuse existing persisted fields; do not add new storage or branching.
- Make one small deterministic change to the seeded follow-up text/template only.
- Verify the updated flow produces the new bounded experiment name and removes old-name references.

