# Existing Workspace Audit

## Audit Scope

Audited local workspace:

- `/Users/benediktpoller/code/push2main.io/superheld`

Audit date:

- 2026-03-29

## High-Level Finding

The local workspace is not a Git checkout and should not become the first public baseline unchanged.

It contains:

- multiple parallel product directions
- broad multi-platform scaffolding
- generated and machine-local artifacts
- release and infrastructure setup that outpaces the actual product core
- working code in some areas, but also demo data, in-memory stores, and disconnected surfaces

## Structural Snapshot

- `web/`: most mature user-facing implementation, but product scope drifts into DSAR, cookie consent, privacy score, and training flows
- `backend/`: real Ktor code and tests exist, but the service mixes many concerns and still relies on in-memory stores
- `shared/`: meaningful KMP domain and utility code exists, but it covers a much wider product than the current MVP and includes placeholder security implementations
- `app/`: substantial Android UI and protection scaffolding exists
- `iosApp/`: substantial iOS UI exists, but it is driven by sample data rather than real backend integration
- `desktop/`: very thin shell only
- `website/`: separate marketing/docs site duplicates documentation concerns
- `k8s/`, `.github/workflows/`, `fastlane/`: deployment and release scaffolding exists early
- `.gradle*`, `build/`, `local.properties`, `.codex-agent/`: non-public or machine-local material

## Keep / Refactor / Leave Out

### Keep as source material

- `shared/`
  Rationale: contains reusable domain and storage concepts, tests, and some portable core logic
- `backend/`
  Rationale: contains real routes, app wiring, and tests that can seed a smaller service
- `web/`
  Rationale: contains usable frontend structure, test setup, and some incident-oriented UI building blocks
- selected `docs/`
  Rationale: compliance and operational notes can be reused after pruning placeholders

### Refactor before public baseline

- `app/`
  Rationale: substantial Android work exists, but scope is broader than the new MVP and includes flows that should not lead the first public baseline
- `iosApp/`
  Rationale: useful reference UI, but currently sample-data-driven rather than product-integrated
- `shared/`
  Rationale: keep only the parts that support the chosen first slice; remove broad optional features from the first baseline
- `backend/`
  Rationale: split out cookie consent, DSA, chat, gamification, and other mixed concerns from the first service baseline
- `web/`
  Rationale: align routes and UI to the new guided-security product instead of cookie consent and DSAR-led entry points
- `.github/workflows/`
  Rationale: current pipelines assume a much larger product surface than the initial public baseline should contain
- `k8s/`, `docker-compose.yml`
  Rationale: useful later, but too heavy for the first clean public baseline

### Leave out of the first public baseline

- `.gradle/`
- `.gradle-home/`
- `.gradle-local/`
- `.gradle-user-home/`
- `app/build/`
- `shared/build/`
- `local.properties`
- `.codex-agent/`
- `projects/`
- `website/`
- `fastlane/`
- `BSI-Digitaler-Verbraucherschutz-partnership-proposal.md`

## Concrete Audit Findings

### 1. The workspace is not a Git repo

There is no `.git` directory in `/Users/benediktpoller/code/push2main.io/superheld`, so this tree should be treated as a local working snapshot, not as authoritative history.

### 2. The web surface is the most mature, but only partly aligned to the current MVP

- the home page centers a cookie consent analyzer
- there are family, phishing trainer, and privacy-related flows mixed with unrelated DSAR and cookie-consent scope
- the dashboard persists key data to local storage rather than treating backend state as source of truth

This means `web/` is useful, but must be repurposed before it represents the family-safety product direction cleanly.

### 3. Mobile surfaces exist, but are not yet a trustworthy product core

- iOS currently uses `SampleFamilyStore`
- Android contains family, privacy, and phishing scaffolding that is partly relevant, but still broader than the current MVP requires
- Android manifest references `QrScannerActivity`, but that implementation was not found in `app/src`

This is useful prototype material, not a first public baseline.

### 4. Backend and shared code are promising, but too broad and still prototype-heavy

- backend routes and tests exist
- shared code contains meaningful family, blocklist, auth, and gamification structures
- several stores are in-memory
- some security-related implementations are explicitly placeholder-grade

This supports selective migration, not direct publication.

### 5. Operational scaffolding is ahead of product reality

- Kubernetes manifests
- release workflows
- iOS release pipeline
- backup jobs

These should follow a narrow product baseline, not define it.

## Recommended First Public Baseline

Do not publish the existing workspace as-is.

Instead:

1. create a fresh repo baseline
2. move only intentionally selected files and modules into it
3. center the baseline on the first product slice, not on platform breadth

## Recommended Public Baseline Contents

- `docs/`
  product vision, MVP scope, first slice, schema, incidents, playbooks
- `apps/web/`
  minimal incident-focused web shell only
- `apps/cloud-brain/`
  minimal ingest and incident service only
- `packages/schema/`
  telemetry and incident contracts
- `packages/playbooks/`
  deterministic playbook definitions

## Migration Guidance

### Migrate early

- selected backend route structure and tests
- selected shared data models and tests
- selected web layout, test tooling, and reusable components

### Migrate later

- Android and iOS UI concepts
- desktop shell
- release automation
- infrastructure manifests

### Exclude until justified

- machine-local files
- generated artifacts
- demo-only flows
- legal placeholders not yet tied to a real operating entity

## Bottom Line

The existing local workspace is valuable as a reference pool, but it is too wide, too mixed, and too prototype-heavy to serve as the first public Superheld repo unchanged.
