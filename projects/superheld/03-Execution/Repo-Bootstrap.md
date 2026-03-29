# Repo Bootstrap

## Current Reality

- The public GitHub repo looked empty on 2026-03-29 before bootstrap.
- A fresh clone now exists at `/Users/benediktpoller/code/codex-agent-system/projects/superheld/repo`.
- The legacy local workspace still contains substantial code and project scaffolding.
- The local workspace audit recommends selective migration into the fresh public baseline instead of publishing the legacy tree as-is.

This means the first implementation decision is not "what do we code first?" but "what becomes the public source of truth?"

## Recommended Bootstrap Path

1. inventory the local workspace and decide which parts are production-lean enough to keep
2. define the public repo structure before the first push
3. move only the intentional baseline into the public repo
4. keep experiments and historical clutter out of the first public history

Reference:

- [[03-Execution/Existing-Workspace-Audit]]

## Bootstrap Status

Completed:

- fresh remote clone created
- minimal public repo structure created
- initial docs added
- first schemas added
- first playbook definitions added

Remaining:

- migrate selected legacy code into the new structure
- implement the first runnable slice
- add deterministic tests in the new repo

## Suggested Initial Public Structure

- `docs/` for product, architecture, and threat model
- `apps/web/` for the consumer surface
- `apps/cloud-brain/` for ingest, normalization, and incident logic
- `packages/schema/` for shared contracts
- `packages/playbooks/` for deterministic response definitions

## First Public Repo Goal

The first pushed baseline should prove one full slice end to end:

- receive one trusted signal
- create one incident
- explain one user-safe action
- verify the result with tests
