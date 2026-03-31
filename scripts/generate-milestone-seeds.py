#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path
from typing import Any


SEED_SECTION_HEADING = "## Milestone Seeds"


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=path.parent, encoding="utf-8") as handle:
        handle.write(content)
        temp_path = Path(handle.name)
    temp_path.replace(path)


def load_project_metadata(root_dir: Path, project_name: str) -> dict[str, Any]:
    metadata_path = root_dir / "projects" / project_name / "project.json"
    if not metadata_path.is_file():
        return {}
    try:
        payload = json.loads(read_text(metadata_path))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def extract_first_milestones(spec_text: str) -> list[str]:
    match = re.search(r"(?ms)^## First Milestones\s*\n(.*?)(?=^## |\Z)", spec_text)
    if not match:
        return []
    milestones: list[str] = []
    for line in str(match.group(1) or "").splitlines():
        numbered = re.match(r"^\s*\d+\.\s+(.*\S)\s*$", line)
        if numbered:
            milestones.append(numbered.group(1).strip())
    return milestones


def extract_seed_section_span(spec_text: str) -> tuple[int, int] | None:
    match = re.search(
        r"(?ms)^## Milestone Seeds\s*\n```json\s*\n.*?\n```\s*(?=^## |\Z)",
        spec_text,
    )
    if not match:
        return None
    return match.start(), match.end()


def render_seed_section(seeds: list[dict[str, Any]]) -> str:
    payload = json.dumps({"seeds": seeds}, indent=2, ensure_ascii=True)
    return f"{SEED_SECTION_HEADING}\n```json\n{payload}\n```\n"


def replace_or_insert_seed_section(spec_text: str, section_text: str) -> str:
    span = extract_seed_section_span(spec_text)
    if span:
        start, end = span
        prefix = spec_text[:start].rstrip()
        suffix = spec_text[end:].lstrip("\n")
        merged = f"{prefix}\n\n{section_text}"
        if suffix:
            merged += f"\n{suffix}"
        return merged.rstrip() + "\n"

    match = re.search(r"(?ms)^## First Milestones\s*\n.*?(?=^## |\Z)", spec_text)
    if match:
        insert_at = match.end()
        prefix = spec_text[:insert_at].rstrip()
        suffix = spec_text[insert_at:].lstrip("\n")
        merged = f"{prefix}\n\n{section_text}"
        if suffix:
            merged += f"\n{suffix}"
        return merged.rstrip() + "\n"

    return spec_text.rstrip() + f"\n\n{section_text}"


def rel_file(path: Path, workspace: Path) -> str:
    return path.resolve().relative_to(workspace.resolve()).as_posix()


def build_seed_for_milestone(milestone: str, workspace: Path) -> tuple[dict[str, Any] | None, str]:
    milestone_text = normalize_text(milestone)
    milestone_key = milestone_text.lower()

    if milestone_key == "decide the repo bootstrap path and source of truth.":
        target = workspace / "docs/overview.md"
        references = [
            workspace / "packages/schema/README.md",
            workspace / "packages/playbooks/README.md",
            workspace / "apps/cloud-brain/README.md",
        ]
        missing_reference = next((path for path in references if not path.is_file()), None)
        if not target.is_file():
            return None, "missing_target_file:docs/overview.md"
        if missing_reference is not None:
            return None, f"missing_reference_file:{rel_file(missing_reference, workspace)}"
        return {
            "milestone": milestone_text,
            "title": "Document repo bootstrap decision and source of truth",
            "category": "learning",
            "target_file": rel_file(target, workspace),
            "anchor": "## Public Baseline Goal",
            "done_markers": ["## Repo Bootstrap Decision"],
            "reference_files": [rel_file(path, workspace) for path in references],
            "reference_limit": 3,
            "reason_template": "Start with `{target_file}` after `{anchor}`. `{spec_ref}` lists milestone `{milestone}`, but the overview does not yet define a dedicated `## Repo Bootstrap Decision` section. Add one deterministic section that names the initial repo bootstrap path, the current source-of-truth files, and the narrow rule for which repo contracts drive the first implementation across {reference_paths}.",
            "priority": "medium",
            "impact": 5,
            "effort": 2,
            "confidence": 0.84,
        }, ""

    if milestone_key == "confirm mandatory mvp protection cases.":
        target = workspace / "docs/architecture/first-slice.md"
        playbooks = sorted((workspace / "packages" / "playbooks").glob("*.json"))
        if not target.is_file():
            return None, "missing_target_file:docs/architecture/first-slice.md"
        if not any(path.is_file() for path in playbooks):
            return None, "missing_reference_glob:packages/playbooks/*.json"
        return {
            "milestone": milestone_text,
            "title": "Document mandatory MVP protection cases in first slice",
            "category": "learning",
            "target_file": rel_file(target, workspace),
            "anchor": "## Scope",
            "done_markers": ["## Mandatory MVP Protection Cases"],
            "reference_globs": ["packages/playbooks/*.json"],
            "reference_min_count": 1,
            "reference_limit": 4,
            "reason_template": "Start with `{target_file}` after `{anchor}`. `{spec_ref}` lists milestone `{milestone}`, but the first-slice architecture doc does not yet define a dedicated `## Mandatory MVP Protection Cases` section. Add one deterministic section that enumerates the currently supported first-slice protection cases backed by {reference_paths}.",
            "priority": "medium",
            "impact": 5,
            "effort": 2,
            "confidence": 0.84,
        }, ""

    if milestone_key == "define telemetry schema, incident model, and first playbooks.":
        target = workspace / "packages/schema/README.md"
        telemetry_schema = workspace / "packages/schema/telemetry-event.schema.json"
        incident_schema = workspace / "packages/schema/incident.schema.json"
        playbook_readme = workspace / "packages/playbooks/README.md"
        overview = workspace / "docs/overview.md"
        references = [telemetry_schema, incident_schema, playbook_readme]
        missing_reference = next((path for path in references if not path.is_file()), None)
        if not target.is_file():
            return None, "missing_target_file:packages/schema/README.md"
        if missing_reference is not None:
            return None, f"missing_reference_file:{rel_file(missing_reference, workspace)}"
        if not overview.is_file():
            return None, "missing_required_file:docs/overview.md"
        return {
            "milestone": milestone_text,
            "title": "Document baseline contract map for telemetry incidents and playbooks",
            "category": "learning",
            "target_file": rel_file(target, workspace),
            "anchor": "Current contracts:",
            "done_markers": ["## Baseline Contract Map"],
            "required_markers": [
                {
                    "file": rel_file(overview, workspace),
                    "marker": "## Repo Bootstrap Decision",
                }
            ],
            "reference_files": [rel_file(path, workspace) for path in references],
            "reference_limit": 3,
            "reason_template": "Start with `{target_file}` after `{anchor}`. `{spec_ref}` lists milestone `{milestone}`, but the schema package does not yet define a dedicated `## Baseline Contract Map` section. Add one deterministic section that maps the telemetry schema, incident model, and first playbook package coverage across {reference_paths}, and state the single source of truth for each contract boundary.",
            "priority": "medium",
            "impact": 4,
            "effort": 2,
            "confidence": 0.83,
        }, ""

    if milestone_key == "align credential recovery playbook trigger coverage with the telemetry contract.":
        target = workspace / "packages/playbooks/account_recovery_after_credential_risk.json"
        telemetry_schema = workspace / "packages/schema/telemetry-event.schema.json"
        contract_map = workspace / "packages/schema/README.md"
        if not target.is_file():
            return None, "missing_target_file:packages/playbooks/account_recovery_after_credential_risk.json"
        if not telemetry_schema.is_file():
            return None, "missing_reference_file:packages/schema/telemetry-event.schema.json"
        if not contract_map.is_file():
            return None, "missing_required_file:packages/schema/README.md"
        return {
            "milestone": milestone_text,
            "title": "Align credential recovery trigger coverage in account recovery playbook",
            "category": "code",
            "target_file": rel_file(target, workspace),
            "anchor": "trigger_event_types",
            "done_markers": ["credential_recovery_trigger"],
            "required_markers": [
                {
                    "file": rel_file(contract_map, workspace),
                    "marker": "## Baseline Contract Map",
                }
            ],
            "reference_files": [
                rel_file(telemetry_schema, workspace),
                rel_file(workspace / "apps/cloud-brain/src/incident-flow.mjs", workspace),
            ],
            "reference_limit": 2,
            "reason_template": "Start with `{target_file}` in `trigger_event_types`. `{spec_ref}` lists milestone `{milestone}`, but the account recovery playbook still does not declare `credential_recovery_trigger` even though the telemetry contract and cloud-brain runtime already recognize that event family. Add the missing deterministic trigger entry so the playbook contract matches the current credential recovery event path described in {reference_paths}.",
            "priority": "medium",
            "impact": 5,
            "effort": 2,
            "confidence": 0.86,
            "success_signals": [
                "The account recovery playbook declares `credential_recovery_trigger` in `trigger_event_types`.",
                "`node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing` exits 0.",
            ],
            "verification_command": "node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing",
        }, ""

    if milestone_key == "enforce trigger-aware playbook routing in the cloud-brain runtime.":
        target = workspace / "apps/cloud-brain/src/incident-flow.mjs"
        playbook = workspace / "packages/playbooks/account_recovery_after_credential_risk.json"
        smoke = workspace / "apps/cloud-brain/scripts/smoke.mjs"
        if not target.is_file():
            return None, "missing_target_file:apps/cloud-brain/src/incident-flow.mjs"
        if not playbook.is_file():
            return None, "missing_required_file:packages/playbooks/account_recovery_after_credential_risk.json"
        if not smoke.is_file():
            return None, "missing_reference_file:apps/cloud-brain/scripts/smoke.mjs"
        return {
            "milestone": milestone_text,
            "title": "Enforce trigger-aware playbook routing in incident flow",
            "category": "code",
            "target_file": rel_file(target, workspace),
            "anchor": "resolveIncidentPlaybook",
            "done_markers": [
                "trigger_event_types.includes(eventType)",
                "resolveIncidentPlaybook(playbooks, incidentType, event.event_type)",
            ],
            "required_markers": [
                {
                    "file": rel_file(playbook, workspace),
                    "marker": "credential_recovery_trigger",
                }
            ],
            "reference_files": [
                rel_file(playbook, workspace),
                rel_file(smoke, workspace),
            ],
            "reference_limit": 2,
            "reason_template": "Start with `{target_file}` at `resolveIncidentPlaybook`. `{spec_ref}` lists milestone `{milestone}`, but the runtime still resolves playbooks only by `incident_type` and ignores whether the playbook actually declares the live event type. Narrow the resolver so it also requires a matching `trigger_event_types` entry and pass `event.event_type` from `runIncidentFlow`, keeping the current deterministic single-match behavior described in {reference_paths}.",
            "priority": "high",
            "impact": 6,
            "effort": 2,
            "confidence": 0.87,
            "success_signals": [
                "The incident-flow resolver requires `trigger_event_types.includes(eventType)`.",
                "`node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing` exits 0.",
            ],
            "verification_command": "node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing",
        }, ""

    if milestone_key == "verify trigger-aware credential recovery routing in the smoke flow.":
        target = workspace / "apps/cloud-brain/scripts/smoke.mjs"
        runtime = workspace / "apps/cloud-brain/src/incident-flow.mjs"
        playbook = workspace / "packages/playbooks/account_recovery_after_credential_risk.json"
        if not target.is_file():
            return None, "missing_target_file:apps/cloud-brain/scripts/smoke.mjs"
        if not runtime.is_file():
            return None, "missing_required_file:apps/cloud-brain/src/incident-flow.mjs"
        if not playbook.is_file():
            return None, "missing_reference_file:packages/playbooks/account_recovery_after_credential_risk.json"
        return {
            "milestone": milestone_text,
            "title": "Verify trigger-aware credential recovery routing in smoke flow",
            "category": "stability",
            "target_file": rel_file(target, workspace),
            "anchor": "credentialRecoveryRun",
            "done_markers": [
                "trigger_event_types.includes(\"credential_recovery_trigger\")",
            ],
            "required_markers": [
                {
                    "file": rel_file(runtime, workspace),
                    "marker": "trigger_event_types.includes(eventType)",
                }
            ],
            "reference_files": [
                rel_file(playbook, workspace),
                rel_file(runtime, workspace),
            ],
            "reference_limit": 2,
            "reason_template": "Start with `{target_file}` around `credentialRecoveryRun`. `{spec_ref}` lists milestone `{milestone}`, but the smoke flow still does not assert that the resolved credential recovery playbook explicitly advertises `credential_recovery_trigger`. Add one deterministic assertion tied to {reference_paths} so the smoke path proves the runtime and playbook contracts stay aligned.",
            "priority": "medium",
            "impact": 5,
            "effort": 2,
            "confidence": 0.85,
            "success_signals": [
                "The smoke flow asserts that the resolved credential recovery playbook includes `credential_recovery_trigger`.",
                "`node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing` exits 0.",
            ],
            "verification_command": "node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing",
        }, ""

    if milestone_key == "define the initial learning-center scope tied to incidents.":
        target = workspace / "docs/overview.md"
        if not target.is_file():
            return None, "missing_target_file:docs/overview.md"
        return {
            "milestone": milestone_text,
            "title": "Define incident-linked learning scope in overview",
            "category": "learning",
            "target_file": rel_file(target, workspace),
            "anchor": "## Current Focus",
            "done_markers": ["## Incident-Linked Learning Scope"],
            "reason_template": "Start with `{target_file}` after `{anchor}`. `{spec_ref}` lists milestone `{milestone}`, but the overview does not yet define a dedicated `## Incident-Linked Learning Scope` section. Add one deterministic section that ties the first learning-center scope to the current incident families, their matching learning themes, and the narrow v1 boundaries for when learning is attached.",
            "priority": "medium",
            "impact": 4,
            "effort": 2,
            "confidence": 0.82,
        }, ""

    if milestone_key == "bootstrap the first production-lean code slice in the repo.":
        target = workspace / "apps/cloud-brain/README.md"
        references = [
            workspace / "apps/cloud-brain/src/incident-flow.mjs",
            workspace / "apps/cloud-brain/scripts/smoke.mjs",
            workspace / "packages/schema/incident.schema.json",
            workspace / "packages/playbooks/account_recovery_after_credential_risk.json",
        ]
        missing_reference = next((path for path in references if not path.is_file()), None)
        if not target.is_file():
            return None, "missing_target_file:apps/cloud-brain/README.md"
        if missing_reference is not None:
            return None, f"missing_reference_file:{rel_file(missing_reference, workspace)}"
        return {
            "milestone": milestone_text,
            "title": "Document first production-lean cloud-brain slice",
            "category": "learning",
            "target_file": rel_file(target, workspace),
            "anchor": "## Decision Table",
            "done_markers": ["## First Production-Lean Slice"],
            "reference_files": [rel_file(path, workspace) for path in references],
            "reference_limit": 4,
            "reason_template": "Start with `{target_file}` after `{anchor}`. `{spec_ref}` lists milestone `{milestone}`, but the cloud-brain blueprint does not yet define a dedicated `## First Production-Lean Slice` section. Add one deterministic section that names the minimal first-slice code path and its concrete runtime anchors in {reference_paths}.",
            "priority": "medium",
            "impact": 5,
            "effort": 2,
            "confidence": 0.83,
        }, ""

    if milestone_key == "define the first incident-state contract for the web dashboard.":
        target = workspace / "apps/web/README.md"
        overview = workspace / "docs/overview.md"
        if not target.is_file():
            return None, "missing_target_file:apps/web/README.md"
        if not overview.is_file():
            return None, "missing_reference_file:docs/overview.md"
        return {
            "milestone": milestone_text,
            "title": "Define incident state contract in web dashboard blueprint",
            "category": "learning",
            "target_file": rel_file(target, workspace),
            "anchor": "## Core Cards",
            "done_markers": ["## Incident State Contract"],
            "reference_files": [
                rel_file(overview, workspace),
                rel_file(workspace / "apps/cloud-brain/README.md", workspace),
            ],
            "reference_limit": 2,
            "reason_template": "Start with `{target_file}` after `{anchor}`. `{spec_ref}` lists milestone `{milestone}`, but the web dashboard blueprint does not yet define a dedicated `## Incident State Contract` section. Add one deterministic section that names the minimal incident payload fields, approval state, and learning linkage the first dashboard must receive from the cloud-brain path described in {reference_paths}.",
            "priority": "medium",
            "impact": 4,
            "effort": 2,
            "confidence": 0.82,
        }, ""

    if milestone_key == "add verification gates for every initial component.":
        target = workspace / "scripts/verify-baseline.sh"
        overview = workspace / "docs/overview.md"
        cloud_readme = workspace / "apps/cloud-brain/README.md"
        if not target.is_file():
            return None, "missing_target_file:scripts/verify-baseline.sh"
        if not overview.is_file():
            return None, "missing_required_file:docs/overview.md"
        if not cloud_readme.is_file():
            return None, "missing_required_file:apps/cloud-brain/README.md"
        return {
            "milestone": milestone_text,
            "title": "Extend baseline verification for initial learning and slice markers",
            "category": "stability",
            "target_file": rel_file(target, workspace),
            "anchor": "the top-level path constants and the existing `require_pattern` block after the README checks",
            "done_markers": [
                "## Incident-Linked Learning Scope",
                "## First Production-Lean Slice",
            ],
            "required_markers": [
                {
                    "file": rel_file(overview, workspace),
                    "marker": "## Incident-Linked Learning Scope",
                },
                {
                    "file": rel_file(cloud_readme, workspace),
                    "marker": "## First Production-Lean Slice",
                },
            ],
            "reason_template": "Start with `{target_file}` near the top-level path constants and the existing `require_pattern` block after the README checks. `{spec_ref}` lists milestone `{milestone}`, but baseline verification still does not require `docs/overview.md` to keep `## Incident-Linked Learning Scope` or `apps/cloud-brain/README.md` to keep `## First Production-Lean Slice`. Add the missing deterministic file constant plus `require_file`/`require_pattern` checks so the initial component markers stay guarded.",
            "priority": "medium",
            "impact": 5,
            "effort": 2,
            "confidence": 0.84,
            "success_signals": [
                "`bash scripts/verify-baseline.sh` exits 0.",
                "Baseline verification checks the initial learning and slice markers.",
            ],
            "verification_command": "bash scripts/verify-baseline.sh",
        }, ""

    if milestone_key == "add verification gates for the repo bootstrap, contract map, and dashboard state markers.":
        target = workspace / "scripts/verify-baseline.sh"
        overview = workspace / "docs/overview.md"
        schema_readme = workspace / "packages/schema/README.md"
        web_readme = workspace / "apps/web/README.md"
        if not target.is_file():
            return None, "missing_target_file:scripts/verify-baseline.sh"
        if not overview.is_file():
            return None, "missing_required_file:docs/overview.md"
        if not schema_readme.is_file():
            return None, "missing_required_file:packages/schema/README.md"
        if not web_readme.is_file():
            return None, "missing_required_file:apps/web/README.md"
        return {
            "milestone": milestone_text,
            "title": "Extend baseline verification for bootstrap contract and dashboard markers",
            "category": "stability",
            "target_file": rel_file(target, workspace),
            "anchor": "require_pattern",
            "done_markers": [
                "## Repo Bootstrap Decision",
                "## Baseline Contract Map",
                "## Incident State Contract",
            ],
            "required_markers": [
                {
                    "file": rel_file(overview, workspace),
                    "marker": "## Repo Bootstrap Decision",
                },
                {
                    "file": rel_file(schema_readme, workspace),
                    "marker": "## Baseline Contract Map",
                },
                {
                    "file": rel_file(web_readme, workspace),
                    "marker": "## Incident State Contract",
                }
            ],
            "reason_template": "Start with `{target_file}` in the `require_pattern` section after the existing docs and README checks. `{spec_ref}` lists milestone `{milestone}`, but baseline verification still does not guard the `## Repo Bootstrap Decision`, `## Baseline Contract Map`, and `## Incident State Contract` markers that now define the autonomous roadmap. Add deterministic `require_pattern` checks so those control-plane contracts cannot silently regress.",
            "priority": "medium",
            "impact": 5,
            "effort": 2,
            "confidence": 0.84,
            "success_signals": [
                "`bash scripts/verify-baseline.sh` exits 0.",
                "Baseline verification guards the repo bootstrap, contract map, and dashboard markers.",
            ],
            "verification_command": "bash scripts/verify-baseline.sh",
        }, ""

    if milestone_key == "align incident status enum with the dashboard contract.":
        target = workspace / "packages/schema/incident.schema.json"
        web_readme = workspace / "apps/web/README.md"
        runtime = workspace / "apps/cloud-brain/src/incident-flow.mjs"
        if not target.is_file():
            return None, "missing_target_file:packages/schema/incident.schema.json"
        if not web_readme.is_file():
            return None, "missing_reference_file:apps/web/README.md"
        if not runtime.is_file():
            return None, "missing_reference_file:apps/cloud-brain/src/incident-flow.mjs"
        return {
            "milestone": milestone_text,
            "title": "Align incident status enum with dashboard contract",
            "category": "code",
            "target_file": rel_file(target, workspace),
            "anchor": "\"status\"",
            "done_markers": [
                "pending_approval",
            ],
            "reference_files": [
                rel_file(web_readme, workspace),
                rel_file(runtime, workspace),
            ],
            "reference_limit": 2,
            "reason_template": "Start with `{target_file}` at the `status` enum. `{spec_ref}` lists milestone `{milestone}`, but the dashboard contract in `apps/web/README.md` uses `pending_approval` while the incident schema still only exposes the runtime-only approval status naming. Add the dashboard-facing `pending_approval` status entry and align the schema examples with the intended web handoff described in {reference_paths}.",
            "priority": "high",
            "impact": 6,
            "effort": 2,
            "confidence": 0.85,
        }, ""

    if milestone_key == "align incident approval states with the dashboard contract.":
        target = workspace / "packages/schema/incident.schema.json"
        web_readme = workspace / "apps/web/README.md"
        if not target.is_file():
            return None, "missing_target_file:packages/schema/incident.schema.json"
        if not web_readme.is_file():
            return None, "missing_reference_file:apps/web/README.md"
        return {
            "milestone": milestone_text,
            "title": "Align incident approval states with dashboard contract",
            "category": "code",
            "target_file": rel_file(target, workspace),
            "anchor": "\"approval_state\"",
            "done_markers": [
                "postponed",
            ],
            "required_markers": [
                {
                    "file": rel_file(target, workspace),
                    "marker": "pending_approval",
                }
            ],
            "reference_files": [
                rel_file(web_readme, workspace),
            ],
            "reference_limit": 1,
            "reason_template": "Start with `{target_file}` at the `approval_state` enum. `{spec_ref}` lists milestone `{milestone}`, but the dashboard contract already documents a `postponed` approval outcome and the incident schema still omits it. Add the missing deterministic enum value and update the relevant examples so the schema matches the web approval flow described in {reference_paths}.",
            "priority": "high",
            "impact": 5,
            "effort": 2,
            "confidence": 0.84,
        }, ""

    if milestone_key == "add dashboard incident payload fields to the incident schema.":
        target = workspace / "packages/schema/incident.schema.json"
        web_readme = workspace / "apps/web/README.md"
        runtime = workspace / "apps/cloud-brain/src/incident-flow.mjs"
        if not target.is_file():
            return None, "missing_target_file:packages/schema/incident.schema.json"
        if not web_readme.is_file():
            return None, "missing_reference_file:apps/web/README.md"
        if not runtime.is_file():
            return None, "missing_reference_file:apps/cloud-brain/src/incident-flow.mjs"
        return {
            "milestone": milestone_text,
            "title": "Add dashboard incident payload fields to incident schema",
            "category": "code",
            "target_file": rel_file(target, workspace),
            "anchor": "\"properties\"",
            "done_markers": [
                "\"incident_key\"",
                "\"headline\"",
                "\"evidence_summary\"",
                "\"safe_next_step\"",
                "\"learning_theme\"",
                "\"learning_recommendation_id\"",
                "\"learning_path\"",
            ],
            "required_markers": [
                {
                    "file": rel_file(target, workspace),
                    "marker": "pending_approval",
                },
                {
                    "file": rel_file(target, workspace),
                    "marker": "postponed",
                },
                {
                    "file": rel_file(web_readme, workspace),
                    "marker": "## Incident State Contract",
                }
            ],
            "reference_files": [
                rel_file(web_readme, workspace),
                rel_file(runtime, workspace),
            ],
            "reference_limit": 2,
            "reason_template": "Start with `{target_file}` in the root `properties` block and the examples section. `{spec_ref}` lists milestone `{milestone}`, but the dashboard contract now expects fields like `incident_key`, `headline`, `evidence_summary`, `safe_next_step`, and learning linkage fields that the incident schema still does not publish. Add the missing deterministic properties plus example coverage so the public incident schema matches the dashboard payload described in {reference_paths}.",
            "priority": "high",
            "impact": 6,
            "effort": 3,
            "confidence": 0.85,
        }, ""

    if milestone_key == "project dashboard contract fields from the cloud-brain runtime.":
        target = workspace / "apps/cloud-brain/src/incident-flow.mjs"
        incident_schema = workspace / "packages/schema/incident.schema.json"
        web_readme = workspace / "apps/web/README.md"
        if not target.is_file():
            return None, "missing_target_file:apps/cloud-brain/src/incident-flow.mjs"
        if not incident_schema.is_file():
            return None, "missing_required_file:packages/schema/incident.schema.json"
        if not web_readme.is_file():
            return None, "missing_reference_file:apps/web/README.md"
        return {
            "milestone": milestone_text,
            "title": "Project dashboard contract fields from incident flow",
            "category": "code",
            "target_file": rel_file(target, workspace),
            "anchor": "const incident = {",
            "done_markers": [
                "incident_key: incidentKey",
                "headline:",
                "evidence_summary:",
                "safe_next_step:",
                "learning_theme:",
                "learning_recommendation_id:",
                "learning_path:",
                "pending_approval",
            ],
            "required_markers": [
                {
                    "file": rel_file(incident_schema, workspace),
                    "marker": "\"learning_path\"",
                }
            ],
            "reference_files": [
                rel_file(incident_schema, workspace),
                rel_file(web_readme, workspace),
            ],
            "reference_limit": 2,
            "reason_template": "Start with `{target_file}` where `runIncidentFlow` builds the incident payload. `{spec_ref}` lists milestone `{milestone}`, but the runtime still returns only the older minimal incident shape and does not project the dashboard contract fields or dashboard-facing approval status naming. Add those deterministic fields directly from the current incident/playbook context so the emitted payload matches the schema and web contract in {reference_paths}.",
            "priority": "high",
            "impact": 7,
            "effort": 3,
            "confidence": 0.86,
        }, ""

    if milestone_key == "verify dashboard incident payload coverage in the smoke flow.":
        target = workspace / "apps/cloud-brain/scripts/smoke.mjs"
        runtime = workspace / "apps/cloud-brain/src/incident-flow.mjs"
        incident_schema = workspace / "packages/schema/incident.schema.json"
        if not target.is_file():
            return None, "missing_target_file:apps/cloud-brain/scripts/smoke.mjs"
        if not runtime.is_file():
            return None, "missing_required_file:apps/cloud-brain/src/incident-flow.mjs"
        if not incident_schema.is_file():
            return None, "missing_reference_file:packages/schema/incident.schema.json"
        return {
            "milestone": milestone_text,
            "title": "Verify dashboard incident payload coverage in smoke flow",
            "category": "stability",
            "target_file": rel_file(target, workspace),
            "anchor": "credentialRecoveryRun",
            "done_markers": [
                "credentialRecoveryRun.incident.incident_key",
                "credentialRecoveryRun.incident.headline",
                "credentialRecoveryRun.incident.safe_next_step",
                "credentialRecoveryRun.incident.learning_path",
                "credentialRecoveryRun.incident.status === \"pending_approval\"",
            ],
            "required_markers": [
                {
                    "file": rel_file(runtime, workspace),
                    "marker": "learning_path:",
                }
            ],
            "reference_files": [
                rel_file(incident_schema, workspace),
                rel_file(runtime, workspace),
            ],
            "reference_limit": 2,
            "reason_template": "Start with `{target_file}` around `credentialRecoveryRun`. `{spec_ref}` lists milestone `{milestone}`, but the smoke path still does not prove that the emitted incident payload includes the dashboard contract fields and dashboard-facing approval status. Add deterministic assertions tied to {reference_paths} so the smoke run fails immediately when the runtime payload drifts from the schema-backed dashboard contract.",
            "priority": "high",
            "impact": 6,
            "effort": 2,
            "confidence": 0.86,
            "success_signals": [
                "The smoke flow asserts the dashboard payload fields and `pending_approval` status.",
                "`node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing` exits 0.",
            ],
            "verification_command": "node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing",
        }, ""

    if milestone_key in {
        "add verification gates for dashboard payload and approval-state contract fields.",
        "add verification gates so `bash scripts/verify-baseline.sh` guards the dashboard status, payload, and approval-state schema fields.",
    }:
        target = workspace / "scripts/verify-baseline.sh"
        incident_schema = workspace / "packages/schema/incident.schema.json"
        if not target.is_file():
            return None, "missing_target_file:scripts/verify-baseline.sh"
        if not incident_schema.is_file():
            return None, "missing_required_file:packages/schema/incident.schema.json"
        return {
            "milestone": milestone_text,
            "title": "Add baseline verification for dashboard payload contract fields",
            "category": "stability",
            "target_file": rel_file(target, workspace),
            "anchor": "require_query",
            "done_markers": [
                "dashboard incident status contract is missing",
                "dashboard incident approval-state contract is missing",
                "dashboard incident payload contract check is missing",
                "dashboard incident payload fields are missing or not required",
            ],
            "required_markers": [
                {
                    "file": rel_file(incident_schema, workspace),
                    "marker": "\"learning_path\"",
                }
            ],
            "reason_template": "Start with `{target_file}` in the existing `require_query` block for `packages/schema/incident.schema.json`. `{spec_ref}` lists milestone `{milestone}`, but baseline verification still does not contain one deterministic jq assertion family that guards the dashboard-facing incident status, postponed approval state, and required payload fields. Add deterministic jq checks so these public contract fields cannot silently regress.",
            "priority": "high",
            "impact": 6,
            "effort": 2,
            "confidence": 0.85,
            "success_signals": [
                "`bash scripts/verify-baseline.sh` exits 0.",
                "Baseline verification guards dashboard status, approval-state, and payload contract fields.",
            ],
            "verification_command": "bash scripts/verify-baseline.sh",
        }, ""

    return None, "unmapped_milestone"


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate structured milestone seeds from a project spec.")
    parser.add_argument("project", nargs="?", default="", help="Project name under projects/<name>/project.json")
    parser.add_argument("--root", default="", help="Repository root containing projects/<name>/project.json")
    parser.add_argument("--spec-file", default="", help="Explicit spec.md path")
    parser.add_argument("--workspace", default="", help="Explicit project workspace path")
    parser.add_argument("--write", action="store_true", help="Replace or insert the Milestone Seeds block in the spec file")
    args = parser.parse_args()

    root_dir = Path(args.root).resolve() if str(args.root).strip() else Path(__file__).resolve().parents[1]
    project_name = str(args.project or "").strip()

    metadata = load_project_metadata(root_dir, project_name) if project_name else {}
    spec_file = Path(args.spec_file).resolve() if str(args.spec_file).strip() else Path(
        str(metadata.get("spec_file") or (root_dir / "projects" / project_name / "spec.md"))
    ).resolve()
    workspace = Path(args.workspace).resolve() if str(args.workspace).strip() else Path(
        str(metadata.get("workspace") or root_dir)
    ).resolve()

    if not spec_file.is_file():
        print(json.dumps({
            "status": "fail",
            "message": "Spec file not found.",
            "data": {
                "project": project_name,
                "spec_file": str(spec_file),
                "workspace": str(workspace),
            },
        }, indent=2))
        return 1

    spec_text = read_text(spec_file)
    milestones = extract_first_milestones(spec_text)
    seeds: list[dict[str, Any]] = []
    unresolved: list[dict[str, str]] = []
    for milestone in milestones:
        seed, reason = build_seed_for_milestone(milestone, workspace)
        if seed is None:
            unresolved.append({
                "milestone": milestone,
                "reason": reason or "no_seed_template",
            })
            continue
        seeds.append(seed)

    wrote_spec = False
    if args.write:
        updated_spec = replace_or_insert_seed_section(spec_text, render_seed_section(seeds))
        if updated_spec != spec_text:
            write_text(spec_file, updated_spec)
        wrote_spec = True

    print(json.dumps({
        "status": "success",
        "message": "Generated milestone seed suggestions.",
        "data": {
            "project": project_name,
            "spec_file": str(spec_file),
            "workspace": str(workspace),
            "wrote_spec": wrote_spec,
            "seed_count": len(seeds),
            "milestone_count": len(milestones),
            "unresolved_milestones": unresolved,
            "seeds": seeds,
        },
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
