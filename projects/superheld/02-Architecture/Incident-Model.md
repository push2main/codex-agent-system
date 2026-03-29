# Incident Model

## Purpose

The incident model turns one or more normalized events into a user-facing security situation with clear state, evidence, and next actions.

## Core Fields

- `incident_id`
- `incident_type`
- `household_id`
- `member_id`
- `severity`
- `status`
- `summary`
- `evidence_refs`
- `playbook_id`
- `approval_state`
- `recommended_learning_modules`
- `created_at`
- `updated_at`

## Suggested Status Values

- `open`
- `triaged`
- `awaiting_approval`
- `in_progress`
- `resolved`
- `dismissed`

## Suggested Severity Values

- `low`
- `medium`
- `high`
- `critical`

## Deduplication Basis

For the first slice, incidents should deduplicate on:

- `household_id`
- `member_id`
- `incident_type`
- `content_ref_hash`
- short time window

## Approval Model

Allowed without approval:

- incident creation
- explanation generation from deterministic incident fields
- low-risk guidance
- notifications
- learning-center recommendations

Requires approval:

- any action that changes family policy or endpoint state
- any collection beyond standard privacy tier
- any remote action request to block, isolate, or enforce a setting change

Blocked in MVP:

- automatic destructive actions
- silent remediation
- unbounded evidence collection

## Example Incident Shape

```json
{
  "incident_id": "inc_001",
  "incident_type": "social_message_risk",
  "household_id": "hh_123",
  "member_id": "member_child_01",
  "severity": "medium",
  "status": "triaged",
  "summary": "A suspicious message from an unknown sender included a risky link.",
  "evidence_refs": [
    "evt_001"
  ],
  "playbook_id": "social_message_risk_review",
  "approval_state": "not_required",
  "recommended_learning_modules": [
    "spotting-social-scams-basics"
  ],
  "created_at": "2026-03-29T12:00:05Z",
  "updated_at": "2026-03-29T12:00:05Z"
}
```

## Verification Rules

1. every incident must reference at least one normalized event
2. every incident must map to one playbook
3. risky actions cannot start when `approval_state` is not approved
4. deduplication must be deterministic and test-covered
5. incident summaries must be explainable without hidden evidence
