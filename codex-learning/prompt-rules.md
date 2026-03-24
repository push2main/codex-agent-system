# Prompt Rules

- Inspect the exact files, queue lease data, and registry state first, then name the single reconciliation path before proposing changes.
- Keep the task to one deterministic fix in the existing lease or planning codepath; avoid broad inventory-plus-implementation prompts.
- State the exact success condition in the prompt: clear stale `running` state only when no live matching lease exists, and preserve active leased work.
- Require one concrete verification command tied to queue/lease behavior and ask for the exact pass/fail result.
- If the agent cannot safely patch after inspection, return the specific file and field inventory instead of retrying with a broader change.

