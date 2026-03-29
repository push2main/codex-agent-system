# Phase 1 Backlog

## Goal

Build the first end-to-end Superheld slice around suspicious social messages, fake profiles, fake account warnings, and bounded authenticity-risk handling for families.

## Work Items

1. lock the event schema for message, link, profile, and authenticity-risk signals
2. define the incident model and deduplication rules
3. write the first deterministic rule set for fake account warnings, fake profiles, prize scams, and manipulated media reports
4. define the first playbooks, family-alert behavior, and approval boundaries
5. design the first user explanation, parent-facing copy, child-facing copy, and learning recommendation logic
6. verify the slice with contract, rule, and end-to-end tests

## Deliverables

- one schema note or package contract
- one incident model note
- two initial playbook definitions for social-risk and authenticity-risk review
- one first learning-module recommendation rule set
- one verification checklist
- one first implementation recommendation for the repo

## Dependencies

- MVP cases must stay locked
- first slice choice must stay locked
- repo baseline decision must not expand scope

## Kill Criteria

Re-scope Phase 1 if any of these happen:

- the first slice requires broad cross-platform support to be useful
- the signal quality is too weak to explain clearly
- the user flow cannot be made safe without broad manual operations

## Definition of Done

- one high-signal incident flow works end to end
- one authenticity-risk flow works end to end with safe guidance
- parent and child messaging is understandable where applicable
- risky actions are approval-gated
- tests prove the core loop
