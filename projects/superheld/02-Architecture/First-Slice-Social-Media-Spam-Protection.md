# First Slice: Social Media, Fake Profile, and Authenticity Protection

## Why This Slice

This is the strongest first slice because it maps directly to the family and child safety problem:

- easy to explain to parents and children
- valuable without deep endpoint integration
- cross-platform enough for a family product
- naturally connected to learning and approvals

## Scope

The first slice should cover:

1. detect or intake a suspicious social message, fake profile, fake account warning, or bounded authenticity-risk signal
2. normalize it into a small event schema
3. create a single incident in the cloud
4. explain the incident in family-safe language
5. recommend a relevant learning module
6. require approval before any risky follow-up action is suggested or executed
7. verify the full loop with tests

## In-Scope Signals

- suspicious direct messages
- scam or spam contact attempts
- impersonation-suspected messages
- fake profiles and platform-support impersonation
- risky links in a social or messaging context
- user-reported manipulated image, video, audio, or call scenarios
- unknown-contact risk escalations reported by the household

## Out-of-Scope Signals

- deep control over third-party social platforms
- universal or automatic deepfake truth detection
- broad malware classification
- autonomous account or device remediation
- full endpoint telemetry as a requirement for MVP value

## End-to-End Flow

1. companion app or user-share flow emits a social-risk or authenticity-risk event
2. event is normalized into a shared schema
3. rules engine evaluates evidence and assigns severity
4. incident is created or updated
5. user receives one clear explanation and one recommended next action
6. a relevant learning module is attached
7. approval gate blocks risky follow-up action until explicitly allowed

## Minimal Data Shape

- `household_id`
- `member_id`
- `platform`
- `channel`
- `event_type`
- `signal_kind`
- `subject_type`
- `content_ref_hash`
- `sender_reputation`
- `risk_tags`

## First Playbook

Playbook name:

- `social_message_risk_review`

Playbook steps:

1. collect minimal evidence about the message or contact
2. classify confidence using deterministic rules for message, profile, and fake-warning scenarios
3. create one user-facing incident summary
4. offer safe guidance and family notifications
5. attach a relevant learning recommendation
6. record outcome

## UX Goal

The user should understand:

- what is suspicious
- why it may be risky
- what to do next
- what the system will not do without permission
- what they can learn to avoid the same risk next time

## Verification Bar

- schema validation for normalized events
- deterministic rule tests for known social-message, fake-profile, and fake-warning cases
- incident creation test for one positive case
- incident deduplication test
- learning recommendation test
- approval gate test for risky follow-up action
- one end-to-end happy-path test

## Follow-On Slice

Once this slice is stable, the next best additions are media authenticity review depth and account recovery after credential risk.
