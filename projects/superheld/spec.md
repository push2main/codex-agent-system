# Project Spec

project: superheld

## Goal

Build Superheld as a family-focused security platform that detects meaningful social, messaging, identity, and household risk, then guides users through safe next actions and learning.

## Product Shape

- Consumer-first UX: one incident, one clear action
- Family-first UX: parents and children both need understandable guidance
- Companion flows on iOS, Android, and web
- Cloud brain that correlates device, identity, household, and incident state

## Constraints

- Keep the initial scope narrow enough to ship and verify
- Use deterministic rules and audited playbooks for detection and response
- Require human approval for high-risk remediations
- Minimize telemetry by default and treat privacy as a product constraint
- Reconcile the local workspace with the empty public repo before broad feature work

## First Milestones

1. Confirm mandatory MVP protection cases.
2. Decide the repo bootstrap path and source of truth.
3. Define telemetry schema, incident model, and first playbooks.
4. Define the initial learning-center scope tied to incidents.
5. Bootstrap the first production-lean code slice in the repo.
6. Add verification gates for every initial component.
