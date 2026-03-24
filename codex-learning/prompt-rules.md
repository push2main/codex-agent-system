# Prompt Rules

- Prefer one explicit, localized change in the named file and keep all other behavior untouched.
- For metric fixes, derive counts and booleans only from the exact persisted success records required by the task.
- Treat inspect, inventory, and report steps as strictly read-only unless the task explicitly asks for a patch.
- Run the requested verification step exactly as specified and report the precise pass/fail outcome.
- If a retry happens because verification failed, keep the implementation unchanged and fix only the verification-path issue.

