Treat stale-pipeline work as queue and execution recovery, not broad feature work.

- Start with the narrowest queue, worker, or gating path that can unblock fresh completions.
- Prefer existing health checks, queue reconciliation, and strategy gating paths over adding new recovery loops.
- Keep the task bounded to one recovery mechanism before seeding more work.
- Validation should prove the blocking gate is cleared or one deterministic recovery signal is restored.
