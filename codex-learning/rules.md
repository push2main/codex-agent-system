# Learned Rules

- Treat inspect or inventory tasks as read-only unless the step explicitly requires a code or config change.
- Follow the step literally and complete only the named action with minimal deterministic output.
- Start with the exact files, commands, and checks specified in the task before broader exploration.
- If a change is required, make the smallest localized patch and avoid unrelated structural or naming changes.
- Run only the requested verification and report the exact result, including failures.

