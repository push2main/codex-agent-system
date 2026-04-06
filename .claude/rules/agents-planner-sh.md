---
paths: agents/planner.sh
---

- Reject self-improve tasks whose title exceeds 220 characters
- Cap planning phase to 60s before first step execution
- Maximum 6 steps per plan, last step must be verification
