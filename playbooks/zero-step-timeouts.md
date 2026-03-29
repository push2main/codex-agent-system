Focus on pre-step timeout prevention, not broad timeout tuning.

- Prefer prompt-size reduction, planning-budget caps, and fail-fast handoff over raising global timeouts.
- Keep edits bounded to planner, orchestrator, or queue-worker paths directly involved before step 1 starts.
- Reuse existing timeout-family guards and deterministic fallback behavior instead of creating parallel timeout flows.
- Validation should prove work advances past planning or emits a bounded successor instead of another planning-only stall.
