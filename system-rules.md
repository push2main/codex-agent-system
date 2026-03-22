# System Rules

## Priorities
1. Stability
2. Determinism
3. Observability
4. UI
5. Performance
6. Enterprise readiness backlog continuity

## Architecture
- JSON communication
- State driven
- Keep a small, continuously replenished backlog of enterprise-readiness tasks when actionable work drops too low
- Respect the persisted dashboard approval mode: `manual` keeps tasks in `pending_approval`, `auto` moves newly created tasks straight toward queue execution
