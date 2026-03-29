# Learned Rules

- Validate referenced files or templates before dispatch; if a required path is missing, fail early as `missing_source_file`.
- Detect unchanged-state tasks before editing; if the requested text or outcome already exists, classify as `no_change_produced` instead of retrying.
- Keep plan steps short, concrete, and single-intent; split any step that combines inspection, editing, and verification.
- Reclassify deterministic reviewer outcomes like missing anchors or already-applied changes out of `review_rejection` and into explicit non-retry categories.
- Do not start a step unless enough time budget remains to finish it and run required verification.

