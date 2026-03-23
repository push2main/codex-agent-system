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

`agentctl` now keeps the last successful dashboard port and scheme, so restarts stay on the same URL unless you explicitly override `DASHBOARD_PORT` or `DASHBOARD_HTTPS`.

If that selected port is already in use, startup fails instead of switching to a different port.

To start the dashboard over HTTPS with a local self-signed certificate:

```bash
DASHBOARD_HTTPS=1 bash scripts/agentctl.sh start
```

The certificate and key are generated automatically in `codex-logs/dashboard-tls/` the first time HTTPS is requested.

To intentionally move the dashboard to a different fixed port:

```bash
DASHBOARD_PORT=3211 bash scripts/agentctl.sh start
```

To see the live URL for the current session at any time:

```bash
bash scripts/agentctl.sh status
```

`agentctl.sh status` now also reports whether the running tmux queue session is using stale helper scripts and needs a restart to pick up runtime changes.

The strategy loop now also keeps a small enterprise-readiness backlog alive when actionable work drops too low, instead of waiting only for failed-task follow-ups.

## Control

```bash
bash scripts/agentctl.sh status
bash scripts/agentctl.sh logs
bash scripts/agentctl.sh stop
```

## Validation

```bash
bash tests/system-smoke.sh
```

## Dashboard approval mode

The dashboard persists an approval mode in `codex-memory/dashboard-settings.json`.

- `manual`: newly derived tasks stop at `pending_approval`
- `auto`: newly derived tasks are approved immediately and queued

You can switch this from the dashboard UI without restarting the session.

## Example task submission

```bash
curl -s http://localhost:3000/api/task-registry \
  -H 'Content-Type: application/json' \
  -d '{"project":"test-app","task":"create hello world script in python"}'
```

Replace `3000` with the value from `dashboard_url` if the dashboard started on a different port.
When HTTPS is enabled with the generated self-signed certificate, use `curl -k`.

## Notes

- Queue limit defaults to `20` tasks. Task timeout defaults to `300` seconds.
- Agent outputs are JSON-only and the orchestrator parses them with `jq`.
- Memory context is the last 20 lines of `codex-memory/decisions.md`.
- After a detected Codex `401 Unauthorized` failure, the queue pauses instead of draining approved tasks into deterministic fallbacks until the cooldown expires.
- Prompt improvements are written to `codex-learning/prompt-rules.md`, then validated into `codex-learning/rules.md`.
- External research runs through a Docker worker via `scripts/run-research-docker.sh`. When `codex-learning/external-signal-sources.json` has `"auto_refresh": true`, the strategy loop refreshes bounded web/media signals into `codex-learning/external-signals.json` and turns fresh items into review tasks instead of applying them directly.
- The research worker supports feed sources, bounded web-search result ingestion, and transcript-based media sources such as YouTube subtitle extraction or direct podcast/media transcript files.
- Git automation stages with `git add -A`, skips runtime artifacts, and refuses to commit obvious secrets.
- Remote push / PR creation is disabled by default. Set `AUTO_PUSH_PR=1` to enable it.
- The dashboard exposes queue state, logs, execution metrics, and a retry action for the most recent failed task.
