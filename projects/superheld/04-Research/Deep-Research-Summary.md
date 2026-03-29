# Deep Research Summary

## Core Takeaways

- Superheld is viable if it is positioned as a personal security platform, not just an antivirus product.
- The technical split must stay strict: deterministic rules and playbooks for action, LLMs for explanation and bounded triage.
- Windows and macOS are the strongest first desktop surfaces.
- iOS should be treated as a companion app early on, not as a deep endpoint sensor.
- Privacy by design and telemetry minimization are not optional for this product.

## Recommended MVP Stack

- Cloudflare Workers, Queues, and Durable Objects
- Supabase Postgres
- LangGraph for orchestrated playbooks and approval gates
- Clerk for fast auth if speed matters
- Stripe for billing
- FCM for notifications

## Strategic Implications

- The product should launch with a few excellent protection cases, not broad shallow coverage.
- Human approval is required for risky remediation.
- The first launch narrative should focus on household safety and guided recovery.

## Source

- `/Users/benediktpoller/Downloads/deep-research-report (19).md`
