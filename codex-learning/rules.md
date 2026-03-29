# Learned Rules

- Reject edit plans that only confirm an existing state instead of making the requested change; classify these as non-retriable no-op mismatches.
- Require each plan step to be concrete, bounded, and focused on a single file or action; split overly dense steps before execution.
- Classify "already exists", "no changes needed", and similar outcomes as deterministic non-retriable failures rather than retry candidates.
- Validate referenced files and anchors before dispatch; fail planning immediately when the source or quoted anchor cannot be found.
- Do not requeue an unchanged plan after reviewer-output/schema failures; classify the review result explicitly and require a changed approach.

