---
paths: agents/*.sh
---

- Every agent must return JSON with status, message, data fields
- Maximum 6 steps per plan, last step must be verification
- Use run_codex_exec for LLM calls, never call codex CLI directly
