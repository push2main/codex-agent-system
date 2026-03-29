# Telemetry Schema Sketch

## Purpose

This schema is the minimum starting point for the first Superheld slice. It is intentionally small, privacy-minimized, and focused on suspicious social-message, spam, and scam-risk events.

## Event Envelope

Every normalized event should include:

- `event_id`
- `schema_version`
- `observed_at`
- `household_id`
- `member_id`
- `platform`
- `event_type`
- `source`
- `privacy_tier`

## Slice-Specific Social Risk Fields

- `channel`
- `signal_kind`
- `content_ref_hash`
- `sender_reputation`
- `link_present`
- `risk_tags`
- `report_origin`
- `confidence_inputs`

## Data Minimization Rules

- do not store raw message content by default
- send hashes or derived attributes before raw payloads where possible
- avoid collecting full account histories or social graphs
- minimize child-related data aggressively
- treat diagnostic expansion as explicit and time-boxed

## Example Normalized Event

```json
{
  "event_id": "evt_001",
  "schema_version": "v1",
  "observed_at": "2026-03-29T12:00:00Z",
  "household_id": "hh_123",
  "member_id": "member_child_01",
  "platform": "ios",
  "event_type": "social_message_risk_detected",
  "source": "mobile_companion",
  "privacy_tier": "standard",
  "channel": "instagram",
  "signal_kind": "spam_or_scam_message",
  "content_ref_hash": "sha256:message",
  "sender_reputation": "unknown",
  "link_present": true,
  "risk_tags": [
    "social_message",
    "unknown_sender",
    "link_present"
  ],
  "report_origin": "user_shared_message",
  "confidence_inputs": {
    "unknown_sender": true,
    "link_to_untrusted_domain": true
  }
}
```

## Validation Rules

1. reject events without `member_id`, `platform`, `event_type`, or `observed_at`
2. reject unsupported `schema_version`
3. reject events with raw payload fields outside the allowed schema
4. require `platform` to be one of the supported companion surfaces for the first slice
5. require at least one social-risk evidence field for social-risk events
6. verify every accepted event against contract tests

## Near-Term Extensions

- guardian notification routing
- learning-module recommendation hints
- incident correlation keys
- limited diagnostic references
