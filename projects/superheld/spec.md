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
7. Align credential recovery playbook trigger coverage with the telemetry contract.
8. Enforce trigger-aware playbook routing in the cloud-brain runtime.
9. Verify trigger-aware credential recovery routing in the smoke flow.
10. Define the first incident-state contract for the web dashboard.
11. Add verification gates for the repo bootstrap, contract map, and dashboard state markers.
12. Align incident status enum with the dashboard contract.
13. Align incident approval states with the dashboard contract.
14. Add dashboard incident payload fields to the incident schema.
15. Project dashboard contract fields from the cloud-brain runtime.
16. Verify dashboard incident payload coverage in the smoke flow.
17. Add verification gates so `bash scripts/verify-baseline.sh` guards the dashboard status, payload, and approval-state schema fields.

## Milestone Seeds
```json
{
  "seeds": [
    {
      "milestone": "Confirm mandatory MVP protection cases.",
      "title": "Document mandatory MVP protection cases in first slice",
      "category": "learning",
      "target_file": "docs/architecture/first-slice.md",
      "anchor": "## Scope",
      "done_markers": [
        "## Mandatory MVP Protection Cases"
      ],
      "reference_globs": [
        "packages/playbooks/*.json"
      ],
      "reference_min_count": 1,
      "reference_limit": 4,
      "reason_template": "Start with `{target_file}` after `{anchor}`. `{spec_ref}` lists milestone `{milestone}`, but the first-slice architecture doc does not yet define a dedicated `## Mandatory MVP Protection Cases` section. Add one deterministic section that enumerates the currently supported first-slice protection cases backed by {reference_paths}.",
      "priority": "medium",
      "impact": 5,
      "effort": 2,
      "confidence": 0.84
    },
    {
      "milestone": "Decide the repo bootstrap path and source of truth.",
      "title": "Document repo bootstrap decision and source of truth",
      "category": "learning",
      "target_file": "docs/overview.md",
      "anchor": "## Public Baseline Goal",
      "done_markers": [
        "## Repo Bootstrap Decision"
      ],
      "reference_files": [
        "packages/schema/README.md",
        "packages/playbooks/README.md",
        "apps/cloud-brain/README.md"
      ],
      "reference_limit": 3,
      "reason_template": "Start with `{target_file}` after `{anchor}`. `{spec_ref}` lists milestone `{milestone}`, but the overview does not yet define a dedicated `## Repo Bootstrap Decision` section. Add one deterministic section that names the initial repo bootstrap path, the current source-of-truth files, and the narrow rule for which repo contracts drive the first implementation across {reference_paths}.",
      "priority": "medium",
      "impact": 5,
      "effort": 2,
      "confidence": 0.84
    },
    {
      "milestone": "Define telemetry schema, incident model, and first playbooks.",
      "title": "Document baseline contract map for telemetry incidents and playbooks",
      "category": "learning",
      "target_file": "packages/schema/README.md",
      "anchor": "Current contracts:",
      "done_markers": [
        "## Baseline Contract Map"
      ],
      "required_markers": [
        {
          "file": "docs/overview.md",
          "marker": "## Repo Bootstrap Decision"
        }
      ],
      "reference_files": [
        "packages/schema/telemetry-event.schema.json",
        "packages/schema/incident.schema.json",
        "packages/playbooks/README.md"
      ],
      "reference_limit": 3,
      "reason_template": "Start with `{target_file}` after `{anchor}`. `{spec_ref}` lists milestone `{milestone}`, but the schema package does not yet define a dedicated `## Baseline Contract Map` section. Add one deterministic section that maps the telemetry schema, incident model, and first playbook package coverage across {reference_paths}, and state the single source of truth for each contract boundary.",
      "priority": "medium",
      "impact": 4,
      "effort": 2,
      "confidence": 0.83
    },
    {
      "milestone": "Define the initial learning-center scope tied to incidents.",
      "title": "Define incident-linked learning scope in overview",
      "category": "learning",
      "target_file": "docs/overview.md",
      "anchor": "## Current Focus",
      "done_markers": [
        "## Incident-Linked Learning Scope"
      ],
      "reason_template": "Start with `{target_file}` after `{anchor}`. `{spec_ref}` lists milestone `{milestone}`, but the overview does not yet define a dedicated `## Incident-Linked Learning Scope` section. Add one deterministic section that ties the first learning-center scope to the current incident families, their matching learning themes, and the narrow v1 boundaries for when learning is attached.",
      "priority": "medium",
      "impact": 4,
      "effort": 2,
      "confidence": 0.82
    },
    {
      "milestone": "Bootstrap the first production-lean code slice in the repo.",
      "title": "Document first production-lean cloud-brain slice",
      "category": "learning",
      "target_file": "apps/cloud-brain/README.md",
      "anchor": "## Decision Table",
      "done_markers": [
        "## First Production-Lean Slice"
      ],
      "reference_files": [
        "apps/cloud-brain/src/incident-flow.mjs",
        "apps/cloud-brain/scripts/smoke.mjs",
        "packages/schema/incident.schema.json",
        "packages/playbooks/account_recovery_after_credential_risk.json"
      ],
      "reference_limit": 4,
      "reason_template": "Start with `{target_file}` after `{anchor}`. `{spec_ref}` lists milestone `{milestone}`, but the cloud-brain blueprint does not yet define a dedicated `## First Production-Lean Slice` section. Add one deterministic section that names the minimal first-slice code path and its concrete runtime anchors in {reference_paths}.",
      "priority": "medium",
      "impact": 5,
      "effort": 2,
      "confidence": 0.83
    },
    {
      "milestone": "Add verification gates for every initial component.",
      "title": "Extend baseline verification for initial learning and slice markers",
      "category": "stability",
      "target_file": "scripts/verify-baseline.sh",
      "anchor": "the top-level path constants and the existing `require_pattern` block after the README checks",
      "done_markers": [
        "## Incident-Linked Learning Scope",
        "## First Production-Lean Slice"
      ],
      "required_markers": [
        {
          "file": "docs/overview.md",
          "marker": "## Incident-Linked Learning Scope"
        },
        {
          "file": "apps/cloud-brain/README.md",
          "marker": "## First Production-Lean Slice"
        }
      ],
      "reason_template": "Start with `{target_file}` near the top-level path constants and the existing `require_pattern` block after the README checks. `{spec_ref}` lists milestone `{milestone}`, but baseline verification still does not require `docs/overview.md` to keep `## Incident-Linked Learning Scope` or `apps/cloud-brain/README.md` to keep `## First Production-Lean Slice`. Add the missing deterministic file constant plus `require_file`/`require_pattern` checks so the initial component markers stay guarded.",
      "priority": "medium",
      "impact": 5,
      "effort": 2,
      "confidence": 0.84,
      "success_signals": [
        "`bash scripts/verify-baseline.sh` exits 0.",
        "Baseline verification checks the initial learning and slice markers."
      ],
      "verification_command": "bash scripts/verify-baseline.sh"
    },
    {
      "milestone": "Align credential recovery playbook trigger coverage with the telemetry contract.",
      "title": "Align credential recovery trigger coverage in account recovery playbook",
      "category": "code",
      "target_file": "packages/playbooks/account_recovery_after_credential_risk.json",
      "anchor": "trigger_event_types",
      "done_markers": [
        "credential_recovery_trigger"
      ],
      "required_markers": [
        {
          "file": "packages/schema/README.md",
          "marker": "## Baseline Contract Map"
        }
      ],
      "reference_files": [
        "packages/schema/telemetry-event.schema.json",
        "apps/cloud-brain/src/incident-flow.mjs"
      ],
      "reference_limit": 2,
      "reason_template": "Start with `{target_file}` in `trigger_event_types`. `{spec_ref}` lists milestone `{milestone}`, but the account recovery playbook still does not declare `credential_recovery_trigger` even though the telemetry contract and cloud-brain runtime already recognize that event family. Add the missing deterministic trigger entry so the playbook contract matches the current credential recovery event path described in {reference_paths}.",
      "priority": "medium",
      "impact": 5,
      "effort": 2,
      "confidence": 0.86,
      "success_signals": [
        "The account recovery playbook declares `credential_recovery_trigger` in `trigger_event_types`.",
        "`node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing` exits 0."
      ],
      "verification_command": "node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing"
    },
    {
      "milestone": "Enforce trigger-aware playbook routing in the cloud-brain runtime.",
      "title": "Enforce trigger-aware playbook routing in incident flow",
      "category": "code",
      "target_file": "apps/cloud-brain/src/incident-flow.mjs",
      "anchor": "resolveIncidentPlaybook",
      "done_markers": [
        "trigger_event_types.includes(eventType)",
        "resolveIncidentPlaybook(playbooks, incidentType, event.event_type)"
      ],
      "required_markers": [
        {
          "file": "packages/playbooks/account_recovery_after_credential_risk.json",
          "marker": "credential_recovery_trigger"
        }
      ],
      "reference_files": [
        "packages/playbooks/account_recovery_after_credential_risk.json",
        "apps/cloud-brain/scripts/smoke.mjs"
      ],
      "reference_limit": 2,
      "reason_template": "Start with `{target_file}` at `resolveIncidentPlaybook`. `{spec_ref}` lists milestone `{milestone}`, but the runtime still resolves playbooks only by `incident_type` and ignores whether the playbook actually declares the live event type. Narrow the resolver so it also requires a matching `trigger_event_types` entry and pass `event.event_type` from `runIncidentFlow`, keeping the current deterministic single-match behavior described in {reference_paths}.",
      "priority": "high",
      "impact": 6,
      "effort": 2,
      "confidence": 0.87,
      "success_signals": [
        "The incident-flow resolver requires `trigger_event_types.includes(eventType)`.",
        "`node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing` exits 0."
      ],
      "verification_command": "node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing"
    },
    {
      "milestone": "Verify trigger-aware credential recovery routing in the smoke flow.",
      "title": "Verify trigger-aware credential recovery routing in smoke flow",
      "category": "stability",
      "target_file": "apps/cloud-brain/scripts/smoke.mjs",
      "anchor": "credentialRecoveryRun",
      "done_markers": [
        "trigger_event_types",
        "credential_recovery_trigger"
      ],
      "required_markers": [
        {
          "file": "apps/cloud-brain/src/incident-flow.mjs",
          "marker": "trigger_event_types.includes(eventType)"
        }
      ],
      "reference_files": [
        "packages/playbooks/account_recovery_after_credential_risk.json",
        "apps/cloud-brain/src/incident-flow.mjs"
      ],
      "reference_limit": 2,
      "reason_template": "Start with `{target_file}` around `credentialRecoveryRun`. `{spec_ref}` lists milestone `{milestone}`, but the smoke flow still does not assert that the resolved credential recovery playbook explicitly advertises `credential_recovery_trigger`. Add one deterministic assertion tied to {reference_paths} so the smoke path proves the runtime and playbook contracts stay aligned.",
      "priority": "medium",
      "impact": 5,
      "effort": 2,
      "confidence": 0.85,
      "success_signals": [
        "The smoke flow asserts that the resolved credential recovery playbook includes `credential_recovery_trigger`.",
        "`node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing` exits 0."
      ],
      "verification_command": "node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing"
    },
    {
      "milestone": "Define the first incident-state contract for the web dashboard.",
      "title": "Define incident state contract in web dashboard blueprint",
      "category": "learning",
      "target_file": "apps/web/README.md",
      "anchor": "## Core Cards",
      "done_markers": [
        "## Incident State Contract"
      ],
      "reference_files": [
        "docs/overview.md",
        "apps/cloud-brain/README.md"
      ],
      "reference_limit": 2,
      "reason_template": "Start with `{target_file}` after `{anchor}`. `{spec_ref}` lists milestone `{milestone}`, but the web dashboard blueprint does not yet define a dedicated `## Incident State Contract` section. Add one deterministic section that names the minimal incident payload fields, approval state, and learning linkage the first dashboard must receive from the cloud-brain path described in {reference_paths}.",
      "priority": "medium",
      "impact": 4,
      "effort": 2,
      "confidence": 0.82
    },
    {
      "milestone": "Add verification gates for the repo bootstrap, contract map, and dashboard state markers.",
      "title": "Extend baseline verification for bootstrap contract and dashboard markers",
      "category": "stability",
      "target_file": "scripts/verify-baseline.sh",
      "anchor": "require_pattern",
      "done_markers": [
        "## Repo Bootstrap Decision",
        "## Baseline Contract Map",
        "## Incident State Contract"
      ],
      "required_markers": [
        {
          "file": "docs/overview.md",
          "marker": "## Repo Bootstrap Decision"
        },
        {
          "file": "packages/schema/README.md",
          "marker": "## Baseline Contract Map"
        },
        {
          "file": "apps/web/README.md",
          "marker": "## Incident State Contract"
        }
      ],
      "reason_template": "Start with `{target_file}` in the `require_pattern` section after the existing docs and README checks. `{spec_ref}` lists milestone `{milestone}`, but baseline verification still does not guard the `## Repo Bootstrap Decision`, `## Baseline Contract Map`, and `## Incident State Contract` markers that now define the autonomous roadmap. Add deterministic `require_pattern` checks so those control-plane contracts cannot silently regress.",
      "priority": "medium",
      "impact": 5,
      "effort": 2,
      "confidence": 0.84,
      "success_signals": [
        "`bash scripts/verify-baseline.sh` exits 0.",
        "Baseline verification guards the repo bootstrap, contract map, and dashboard markers."
      ],
      "verification_command": "bash scripts/verify-baseline.sh"
    },
    {
      "milestone": "Align incident status enum with the dashboard contract.",
      "title": "Align incident status enum with dashboard contract",
      "category": "code",
      "target_file": "packages/schema/incident.schema.json",
      "anchor": "\"status\"",
      "done_markers": [
        "pending_approval"
      ],
      "reference_files": [
        "apps/web/README.md",
        "apps/cloud-brain/src/incident-flow.mjs"
      ],
      "reference_limit": 2,
      "reason_template": "Start with `{target_file}` at the `status` enum. `{spec_ref}` lists milestone `{milestone}`, but the dashboard contract in `apps/web/README.md` uses `pending_approval` while the incident schema still only exposes the runtime-only approval status naming. Add the dashboard-facing `pending_approval` status entry and align the schema examples with the intended web handoff described in {reference_paths}.",
      "priority": "high",
      "impact": 6,
      "effort": 2,
      "confidence": 0.85
    },
    {
      "milestone": "Align incident approval states with the dashboard contract.",
      "title": "Align incident approval states with dashboard contract",
      "category": "code",
      "target_file": "packages/schema/incident.schema.json",
      "anchor": "\"approval_state\"",
      "done_markers": [
        "postponed"
      ],
      "required_markers": [
        {
          "file": "packages/schema/incident.schema.json",
          "marker": "pending_approval"
        }
      ],
      "reference_files": [
        "apps/web/README.md"
      ],
      "reference_limit": 1,
      "reason_template": "Start with `{target_file}` at the `approval_state` enum. `{spec_ref}` lists milestone `{milestone}`, but the dashboard contract already documents a `postponed` approval outcome and the incident schema still omits it. Add the missing deterministic enum value and update the relevant examples so the schema matches the web approval flow described in {reference_paths}.",
      "priority": "high",
      "impact": 5,
      "effort": 2,
      "confidence": 0.84
    },
    {
      "milestone": "Add dashboard incident payload fields to the incident schema.",
      "title": "Add dashboard incident payload fields to incident schema",
      "category": "code",
      "target_file": "packages/schema/incident.schema.json",
      "anchor": "\"properties\"",
      "done_markers": [
        "\"incident_key\"",
        "\"headline\"",
        "\"evidence_summary\"",
        "\"safe_next_step\"",
        "\"learning_theme\"",
        "\"learning_recommendation_id\"",
        "\"learning_path\""
      ],
      "required_markers": [
        {
          "file": "packages/schema/incident.schema.json",
          "marker": "pending_approval"
        },
        {
          "file": "packages/schema/incident.schema.json",
          "marker": "postponed"
        },
        {
          "file": "apps/web/README.md",
          "marker": "## Incident State Contract"
        }
      ],
      "reference_files": [
        "apps/web/README.md",
        "apps/cloud-brain/src/incident-flow.mjs"
      ],
      "reference_limit": 2,
      "reason_template": "Start with `{target_file}` in the root `properties` block and the examples section. `{spec_ref}` lists milestone `{milestone}`, but the dashboard contract now expects fields like `incident_key`, `headline`, `evidence_summary`, `safe_next_step`, and learning linkage fields that the incident schema still does not publish. Add the missing deterministic properties plus example coverage so the public incident schema matches the dashboard payload described in {reference_paths}.",
      "priority": "high",
      "impact": 6,
      "effort": 3,
      "confidence": 0.85
    },
    {
      "milestone": "Project dashboard contract fields from the cloud-brain runtime.",
      "title": "Project dashboard contract fields from incident flow",
      "category": "code",
      "target_file": "apps/cloud-brain/src/incident-flow.mjs",
      "anchor": "const incident = {",
      "done_markers": [
        "incident_key: incidentKey",
        "headline:",
        "evidence_summary:",
        "safe_next_step:",
        "learning_theme:",
        "learning_recommendation_id:",
        "learning_path:",
        "pending_approval"
      ],
      "required_markers": [
        {
          "file": "packages/schema/incident.schema.json",
          "marker": "\"learning_path\""
        }
      ],
      "reference_files": [
        "packages/schema/incident.schema.json",
        "apps/web/README.md"
      ],
      "reference_limit": 2,
      "reason_template": "Start with `{target_file}` where `runIncidentFlow` builds the incident payload. `{spec_ref}` lists milestone `{milestone}`, but the runtime still returns only the older minimal incident shape and does not project the dashboard contract fields or dashboard-facing approval status naming. Add those deterministic fields directly from the current incident/playbook context so the emitted payload matches the schema and web contract in {reference_paths}.",
      "priority": "high",
      "impact": 7,
      "effort": 3,
      "confidence": 0.86
    },
    {
      "milestone": "Verify dashboard incident payload coverage in the smoke flow.",
      "title": "Verify dashboard incident payload coverage in smoke flow",
      "category": "stability",
      "target_file": "apps/cloud-brain/scripts/smoke.mjs",
      "anchor": "credentialRecoveryRun",
      "done_markers": [
        "credential recovery incident payload must match the exact schema-backed dashboard projection from apps/cloud-brain/src/incident-flow.mjs"
      ],
      "required_markers": [
        {
          "file": "apps/cloud-brain/src/incident-flow.mjs",
          "marker": "learning_path:"
        }
      ],
      "reference_files": [
        "packages/schema/incident.schema.json",
        "apps/cloud-brain/src/incident-flow.mjs"
      ],
      "reference_limit": 2,
      "reason_template": "Start with `{target_file}` around `credentialRecoveryRun`. `{spec_ref}` lists milestone `{milestone}`, but the smoke path still does not pin one exact emitted dashboard payload object against the schema-backed projection from {reference_paths}. Add one deterministic equality assertion for the emitted credential recovery dashboard payload, including the dashboard-facing `pending_approval` status and `pending` approval_state, so the smoke run fails immediately when that payload drifts.",
      "priority": "high",
      "impact": 6,
      "effort": 2,
      "confidence": 0.86,
      "success_signals": [
        "The smoke flow asserts one exact credential recovery dashboard payload object against the schema-backed projection.",
        "`node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing` exits 0."
      ],
      "verification_command": "node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing"
    },
    {
      "milestone": "Add verification gates so `bash scripts/verify-baseline.sh` guards the dashboard status, payload, and approval-state schema fields.",
      "title": "Add baseline verification for dashboard payload contract fields",
      "category": "stability",
      "target_file": "scripts/verify-baseline.sh",
      "anchor": "require_query",
      "done_markers": [
        "dashboard incident status contract is missing",
        "dashboard incident approval-state contract is missing",
        "dashboard incident payload contract check is missing",
        "dashboard incident payload fields are missing or not required"
      ],
      "required_markers": [
        {
          "file": "packages/schema/incident.schema.json",
          "marker": "\"learning_path\""
        }
      ],
      "reason_template": "Start with `{target_file}` in the existing `require_query` block for `packages/schema/incident.schema.json`. `{spec_ref}` lists milestone `{milestone}`, but baseline verification still does not contain one deterministic jq assertion family that guards the dashboard-facing incident status, postponed approval state, and required payload fields. Add deterministic jq checks so these public contract fields cannot silently regress.",
      "priority": "high",
      "impact": 6,
      "effort": 2,
      "confidence": 0.85,
      "success_signals": [
        "`bash scripts/verify-baseline.sh` exits 0.",
        "Baseline verification guards dashboard status, approval-state, and payload contract fields."
      ],
      "verification_command": "bash scripts/verify-baseline.sh"
    }
  ]
}
```
