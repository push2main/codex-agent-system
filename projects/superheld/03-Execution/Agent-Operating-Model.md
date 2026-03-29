# Agent Operating Model

## Readiness Verdict

Superheld is ready for bounded agent work.

Superheld is not yet ready for unconstrained multi-agent implementation where several agents independently expand product scope.

## What Agents Already Have

- a clear product direction for families and households with children
- a locked first slice around suspicious messages, fake profiles, fake account warnings, and bounded authenticity risk
- deterministic schemas and playbooks in the public repo baseline
- a research-backed scenario map from official Austrian sources
- a high-risk project policy with manual review defaults

## What Is Still Missing

These gaps do not block narrow tasks, but they do block broad autonomous execution:

- the task registry is now seeded, but most entries are still `pending_approval`
- MVP channels are not yet prioritized
- auth and household-role provider choice is not locked
- evidence retention policy is not locked
- learning-center age segmentation is not locked
- the migration boundary from the legacy local workspace is still open

## Recommended Agent Set

### 1. Contracts Agent

Owns:

- `packages/schema/`
- `packages/playbooks/`

Mission:

- keep event and incident contracts stable
- add deterministic fixtures
- define validation rules and contract tests

Can start now:

- yes

Should not own:

- UI code
- runtime persistence

## 2. Cloud Brain Agent

Owns:

- `apps/cloud-brain/`

Mission:

- implement normalized event intake
- validate schema compliance
- map events to incidents and playbooks
- enforce approval boundaries

Can start now:

- yes, but only against the existing schema and playbook contracts

Should not own:

- contract redefinition
- family UX copy

## 3. Web Experience Agent

Owns:

- `apps/web/`

Mission:

- build family-safe incident views
- build approval surfaces
- attach learning recommendations
- keep parent and child presentation separate where needed

Can start now:

- yes, but should stay on mock data until incident payloads are stable in the runtime

Should not own:

- backend incident logic
- auth model changes

## 4. Quality Agent

Owns:

- `scripts/`
- future `.github/workflows/`
- future test fixtures under repo-owned test paths

Mission:

- add contract validation checks
- add CI verification
- add scenario fixtures for fake profiles, fake warnings, scams, and manipulated media

Can start now:

- yes

Should not own:

- product scope changes

## 5. Learning and Safety Content Agent

Owns:

- planning notes for learning modules
- future structured learning content package or docs path

Mission:

- derive short parent and child learning modules from the scenario map
- keep safety guidance concrete and age-appropriate
- map each module to incident types and playbooks

Can start now:

- partially

Blocked by:

- final age-band decision
- final channel priority

## Recommended Execution Order

1. contracts agent
2. quality agent
3. cloud brain agent
4. web experience agent
5. learning and safety content agent

## First Safe Agent Backlog

1. add contract fixtures and example payloads for `packages/schema/telemetry-event.schema.json`
2. add incident fixtures and mapping cases for `packages/schema/incident.schema.json`
3. add runtime scaffold in `apps/cloud-brain/` that validates and routes events without expanding scope
4. add mock incident and approval views in `apps/web/`
5. add CI checks and baseline test jobs for schemas and playbooks

## Seeded Registry Tasks

- `task-001-telemetry-schema-examples` -> contracts agent, completed on 2026-03-29
- `task-002-incident-schema-examples` -> contracts agent
- `task-003-cloud-brain-readme-blueprint` -> cloud brain agent
- `task-004-web-readme-blueprint` -> web experience agent
- `task-005-verify-baseline-coverage` -> quality agent

Current registry path:

- `/Users/benediktpoller/code/codex-agent-system/projects/superheld/repo/.codex-agent/tasks.json`

## Rules For Parallel Work

- every agent gets an explicit write scope
- contracts change first, runtime second, UI third
- quality can work in parallel as long as it only consumes existing contracts
- no agent should touch the legacy local workspace unless migration work is explicitly assigned
- no agent should introduce LLM-driven action decisions into the core response path

## Recommendation

The project has enough information for the first implementation wave if tasks stay narrow and file ownership stays explicit.

Before broad multi-agent execution, use the seeded registry entries and lock four decisions:

1. MVP channels
2. auth provider
3. evidence retention window
4. learning-center age bands

The first task registry entries now exist.
