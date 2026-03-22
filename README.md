# Codex Agent System

Autonomous local multi-agent coding workflow for macOS with deterministic JSON agent outputs, queue-based task execution, lightweight memory context, system logging, and a mobile-friendly dashboard.

## Requirements

- `bash`
- `jq`
- `node`
- `python3`
- `tmux`
- `codex` CLI for live agent execution, or `CODEX_DISABLE=1` to force deterministic fallbacks

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

## Control

```bash
bash scripts/agentctl.sh status
bash scripts/agentctl.sh logs
bash scripts/agentctl.sh stop
```

## Example task submission

```bash
curl -s http://localhost:3000/api/task \
  -H 'Content-Type: application/json' \
  -d '{"project":"test-app","task":"create hello world script in python"}'
```

## Notes

- Queue limit defaults to `20` tasks. Task timeout defaults to `300` seconds.
- Agent outputs are JSON-only and the orchestrator parses them with `jq`.
- Memory context is the last 20 lines of `codex-memory/decisions.md`.
- Git automation stages with `git add -A`, skips runtime artifacts, and refuses to commit obvious secrets.
- Remote push / PR creation is disabled by default. Set `AUTO_PUSH_PR=1` to enable it.
