# Project Plan

## Mission

Build Superheld into a family-focused security platform that helps parents, children, and households notice real digital risk quickly, understand it clearly, and take safe next actions without needing enterprise security knowledge.

## 90-Day Outcome

Within the first 90 days, Superheld should prove one narrow but real product loop:

1. ingest a high-signal security event
2. create a trustworthy incident
3. explain the incident in clear consumer language
4. guide the user through one safe response flow
5. verify the outcome

## Who We Build For First

Default planning assumption:

- primary: families and households with children
- secondary: individual users with high exposure to scams, spam, and account compromise

## MVP Product Promise

Superheld should not try to do everything. The MVP promise should be:

"When a child or family member encounters a suspicious message, fake profile, deepfake, link, or account situation, Superheld explains the risk, suggests safe next steps, and helps the household learn from it."

## Planning Priorities

- narrow the first protection cases to a small set with strong user value
- choose a repo baseline that is intentionally clean
- define deterministic playbooks before broad feature work
- keep privacy, approval boundaries, and verification in scope from day one

## Workstreams

### 1. Product and Positioning

- lock target audience
- lock mandatory MVP protection cases
- define beta promise and launch language

### 2. Detection and Endpoint Signals

- choose the first family-relevant signal slice around suspicious messages, fake profiles, and media authenticity risk
- define telemetry boundaries and schemas
- define evidence requirements for incidents

### 3. Cloud Brain and Playbooks

- normalize events into shared schema
- deduplicate and aggregate incidents
- define deterministic action plans and approval boundaries

### 4. Companion Experience

- design family alert flows, approvals, guided recovery, and parent-child communication
- keep mobile and web scope focused on incident response, family oversight, and learning center delivery

### 5. Security, Privacy, and Compliance

- threat model the first slice
- minimize telemetry by default
- document consent and diagnostic tiers
- treat child and household data minimization as a hard product requirement

## Suggested Beta Success Metrics

- at least 3 validated family fraud or authenticity protection flows
- one end-to-end incident loop verified in tests
- parents or guardians can understand the recommended next action in under 5 minutes
- at least one relevant learning module can be recommended from a core incident
- risky actions always require approval
- telemetry defaults stay intentionally minimized

## Non-Goals for the First Cycle

- deep Linux coverage
- broad antivirus parity
- autonomous high-risk remediation
- B2B SOC workflows
- ML-heavy detection as a first dependency
