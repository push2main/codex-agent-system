---
paths: scripts/multi-queue.sh
paths: scripts/queue-worker.sh
---

- Queue operations must be atomic — use temp file + rename
- Always respect TASK_TIMEOUT_SECONDS
- Hot reload must debounce to prevent data loss
