# Project Memory

project: superheld
workspace: /Users/benediktpoller/code/codex-agent-system/projects/superheld/repo
repo_url: https://github.com/push2main/superheld

# Context
Superheld is planned as a personal security platform for households: device security, identity protection, and guided incident response in one product.

## Current State

- On 2026-03-29, the remote GitHub repository returned no refs via `git ls-remote`, so the hosted repo initially appeared empty.
- On 2026-03-29, a fresh clone of the remote repository was created at `/Users/benediktpoller/code/codex-agent-system/projects/superheld/repo`.
- On 2026-03-29, the legacy local workspace at `/Users/benediktpoller/code/push2main.io/superheld` was audited as source material rather than as the public baseline.
- Primary planning source: `/Users/benediktpoller/Downloads/deep-research-report (19).md`

## Working Assumptions

- MVP focus is family and child safety around social media, fake profiles, deepfakes, scams, and guided learning.
- Detection and response stay deterministic and auditable; LLMs explain, triage, and suggest.
- High-risk actions require human approval.
- Telemetry must be privacy-minimized and tiered by consent.

## Recommended MVP Protection Cases

- suspicious social messages and contact risk
- fake account warnings and scam link response
- fake profiles, impersonation, and deepfake review support
- infostealer-style account recovery guidance
- household notifications, approval flows, and learning-center recommendations tied to incidents

## Immediate Priorities

1. Lock the 3-5 mandatory MVP protection cases.
2. Grow the fresh public repo baseline from contracts and playbooks.
3. Selectively migrate useful code from the legacy workspace.
4. Implement the first end-to-end social-message, fake-profile, and authenticity-risk slice.

## Agent Readiness Summary

- The project is ready for narrowly scoped agent work on schemas, playbooks, cloud runtime scaffolding, web scaffolding, and verification.
- The project is not yet ready for unconstrained parallel feature work because task registry entries, auth choice, channel priority, and evidence-retention policy are still missing.
- On 2026-03-29, the first five board-ready tasks were seeded into `/Users/benediktpoller/code/codex-agent-system/projects/superheld/repo/.codex-agent/tasks.json`.
