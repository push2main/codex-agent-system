# Codex Agent System

Autonomous local multi-agent coding workflow for macOS using Codex CLI, queue-based task execution, memory retrieval, a mobile-friendly dashboard, notifications, and git automation.

## Start

```bash
bash scripts/agentctl.sh start
```

Dashboard:

```text
http://localhost:3000
```

If port `3000` is already in use locally:

```bash
DASHBOARD_PORT=3001 bash scripts/agentctl.sh start
```

Example task submission:

```bash
curl -s http://localhost:3000/api/task \
  -H 'Content-Type: application/json' \
  -d '{"project":"test-app","task":"create simple hello world script"}'
```

## Notes

- `NTFY_TOPIC` optionally enables ntfy notifications. `NTFY_URL` defaults to `https://ntfy.sh`.
- The memory layer bootstraps a local Python virtualenv and installs `sentence-transformers` on first use.
- Git automation creates `codex/<timestamp>-<random>` branches and never commits directly to `main`.
