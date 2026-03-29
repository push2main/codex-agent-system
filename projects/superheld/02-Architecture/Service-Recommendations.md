# Service Recommendations

## Decision Summary

Recommended default stack for the first Superheld implementation wave:

- Cloudflare Workers for runtime
- Cloudflare Queues for asynchronous event processing
- Cloudflare Durable Objects for serialized household, incident, and approval state
- Supabase Postgres as the primary system of record
- Cloudflare Hyperdrive between Workers and Supabase Postgres if latency or connection pressure becomes visible
- GitHub Actions for CI verification
- Sentry for runtime errors, tracing, and optional AI-path monitoring
- PostHog for product analytics, session replay, and feature flags

Optional accelerator:

- Clerk Organizations if household memberships and role management become the main implementation bottleneck

## Why These Services Fit

### Performance

- Cloudflare Workers give a global serverless runtime with built-in observability and background-job support.
- Cloudflare Queues are a clean fit for asynchronous signal ingestion.
- Durable Objects are a strong fit for serialized coordination when one household or incident needs a single authoritative state owner.
- Hyperdrive is a good performance layer if Workers need to talk to a regional Postgres database repeatedly.

### Quality

- GitHub Actions is the simplest path for automated schema, playbook, and integration checks in the repo.
- Sentry gives error tracking and distributed tracing, which matters once web and cloud paths diverge.
- PostHog adds fast feedback on whether users understand incidents, complete approvals, or drop out of recovery flows.

### Implementation Speed

- Supabase keeps the data layer close to Postgres and Auth instead of forcing a custom backend from day one.
- Clerk can speed up household membership, admin/member roles, and invitation flows if that work starts to dominate the MVP.
- PostHog feature flags can reduce launch risk for sensitive family-safety features.

## Recommended Service Boundaries

### Cloudflare

Use for:

- API and event intake
- asynchronous incident processing
- state coordination around household approvals
- edge-adjacent logic for fast explanation delivery

Do not use first:

- broad infrastructure sprawl
- premature multi-service decomposition

### Supabase

Use for:

- core relational incident, household, membership, and learning state
- row-level security and simple operational tooling

Do not use first:

- deeply custom auth flows unless clearly needed

### Sentry

Use for:

- production error visibility
- latency and trace analysis across web and cloud runtime
- optional AI-assisted explanation path monitoring if those flows appear early

### PostHog

Use for:

- funnel and drop-off analysis for approvals and recovery flows
- session replay on the family dashboard
- feature flags for staged rollouts

Do not use for:

- broad surveillance-style analytics on children

## Auth Recommendation

Default recommendation:

- start with Supabase Auth if the team wants the fewest vendors and can tolerate building household roles and invitations in-app

Escalation recommendation:

- use Clerk Organizations if household membership, invitations, and role boundaries are slowing delivery materially

## Best Current Service Combination

For the current state of Superheld, the strongest combination is:

1. Cloudflare Workers, Queues, and Durable Objects
2. Supabase Postgres
3. GitHub Actions
4. Sentry
5. PostHog

Inference:

This combination best balances speed, deterministic backend control, operational visibility, and low initial complexity for the current MVP.

## Official Sources

- [Cloudflare Workers](https://developers.cloudflare.com/workers/)
- [Cloudflare Queues](https://developers.cloudflare.com/queues/get-started/)
- [Cloudflare Durable Objects](https://developers.cloudflare.com/durable-objects/)
- [Cloudflare Hyperdrive](https://developers.cloudflare.com/hyperdrive/)
- [Supabase architecture](https://supabase.com/docs/architecture)
- [Supabase Auth architecture](https://supabase.com/docs/guides/auth/architecture)
- [Clerk Organizations roles and permissions](https://clerk.com/docs/organizations/roles-permissions)
- [GitHub Actions docs](https://docs.github.com/en/actions)
- [Sentry tracing docs](https://docs.sentry.io/platforms/javascript/guides/express/tracing)
- [Sentry AI Agent Monitoring for Cloudflare](https://docs.sentry.io/platforms/javascript/guides/cloudflare/tracing/instrumentation/ai-agents-module/)
- [PostHog](https://posthog.com/)
