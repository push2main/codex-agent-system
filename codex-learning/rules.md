# Learned Rules

- Reject tasks as non-retriable when the requested state already exists in the referenced file or the target anchor does not match.
- Keep plans simple and bounded: split overloaded instructions into smaller deterministic steps, and keep verification last.
- Block retries when a task fails repeatedly with substantially the same plan and no clear change in approach.
- Use broad deterministic failure classes for no-op, anchor-mismatch, and missing-source cases, and make no-op failures non-retriable.
- Require referenced files or example anchors to exist before planning work that depends on them.

