# Playbook Set v1

## Purpose

These are the first four deterministic playbooks recommended for the MVP planning baseline.

## 1. Social Message Risk Review

Playbook id:

- `social_message_risk_review`

Trigger:

- normalized social-message or spam-risk event with high-risk evidence

Deterministic steps:

1. validate event contract
2. score the evidence with rule set v1
3. create or update the incident
4. generate family-safe summary
5. recommend household-safe next actions
6. recommend a relevant learning module
7. verify incident state and audit trail

Auto-allowed actions:

- create incident
- notify user
- show guidance
- recommend learning content

Approval-required actions:

- request deeper diagnostics
- enforce a family policy or device-state change

## 2. Phishing and Scam Link Response

Playbook id:

- `phishing_link_response`

Trigger:

- risky link classification or suspicious link-open event

Deterministic steps:

1. validate link-risk signal
2. create low- or medium-severity incident
3. show immediate safe next actions
4. check if identity recovery follow-up is needed
5. verify outcome and close or escalate

Auto-allowed actions:

- warn user
- open safe guidance
- recommend credential review
- recommend learning content

Approval-required actions:

- any device-side setting changes
- any data collection outside standard tier

## 3. Account Recovery After Credential Risk

Playbook id:

- `account_recovery_after_credential_risk`

Trigger:

- infostealer suspicion, phishing escalation, or user-reported credential exposure

Deterministic steps:

1. classify recovery scenario
2. build checklist-driven response plan
3. guide session review, password reset, and MFA checks
4. record completion status per step
5. verify recovery outcome

Auto-allowed actions:

- show checklist
- send notifications
- track user-completed steps
- recommend learning content

Approval-required actions:

- any remote action against endpoint state
- any expanded evidence collection

## 4. Media Authenticity Risk Review

Playbook id:

- `media_authenticity_risk_review`

Trigger:

- user-reported suspicious image, video, audio, call, or profile authenticity scenario

Deterministic steps:

1. validate event contract
2. classify the authenticity scenario with rule set v1
3. create or update the incident
4. generate child-safe and parent-safe guidance
5. recommend evidence preservation and reporting steps
6. recommend a relevant learning module
7. verify incident state and audit trail

Auto-allowed actions:

- create incident
- show authenticity checklist
- show reporting guidance
- recommend evidence preservation
- recommend learning content

Approval-required actions:

- any expanded diagnostic collection
- any platform contact or guardian escalation outside the default household policy

## Common Playbook Rules

- all playbooks must map to deterministic triggers
- all risky actions must be explicitly approval-gated
- all state transitions must be auditable
- all playbooks must have contract and end-to-end tests
- learning recommendations may be attached automatically when they are deterministic and low risk
- LLMs may explain or rephrase, but they do not decide action eligibility
