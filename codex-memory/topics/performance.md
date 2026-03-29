# Performance Learnings
- 2026-03-24T21:00:00Z | IMPROVEMENT | Planner scope limited to ONE deliverable per plan (Anthropic pattern: "one feature per session maximum").
  Rules: Focus each plan on a single discrete deliverable. A focused 3-step plan beats a broad 6-step plan. Every step must name target file, exact change, and expected outcome.
- 2026-03-24T21:00:00Z | IMPROVEMENT | Coder mandatory validation after every file change.
  Rules: Shell scripts must pass bash -n, Python must pass ast.parse, JSON must pass json.tool. Never return success with broken code. Return specific error messages on failure.
