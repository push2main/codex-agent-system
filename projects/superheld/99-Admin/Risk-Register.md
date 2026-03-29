# Risk Register

## Scope Risk

- Risk: Superheld tries to cover too many threat classes too early
- Impact: slow delivery, shallow protection, unclear beta value
- Mitigation: lock 3-5 protection cases and reject new categories until the first loop works

## Repo Drift Risk

- Risk: the local workspace and the public repo diverge from the start
- Impact: messy first history, confusion about source of truth
- Mitigation: finish planning first, then choose an intentional public baseline before any broad push

## Product Clarity Risk

- Risk: the product sounds like generic antivirus instead of a guided security platform
- Impact: weak positioning and unclear user expectations
- Mitigation: keep messaging centered on household safety and guided incident response

## Architecture Risk

- Risk: LLM behavior leaks into core response logic
- Impact: unsafe actions, poor auditability, verification problems
- Mitigation: keep rules, actions, and approval gates deterministic and versioned

## Privacy Risk

- Risk: telemetry scope expands before privacy boundaries are set
- Impact: compliance burden, user trust loss, unnecessary data retention
- Mitigation: define telemetry minimization and diagnostic tiers before collecting broad signals

## Platform Risk

- Risk: iOS expectations are set too high for what sandboxing allows
- Impact: roadmap distortion and product disappointment
- Mitigation: treat iOS as a companion surface early on, not a deep endpoint sensor

## Operational Risk

- Risk: beta support load becomes too high because incidents are noisy or hard to explain
- Impact: team overload and poor user trust
- Mitigation: launch with few high-signal playbooks and strong guided response copy

## Verification Risk

- Risk: planning and implementation advance without a clear test bar
- Impact: regressions and weak confidence in detections or responses
- Mitigation: define verification gates before broad implementation work
