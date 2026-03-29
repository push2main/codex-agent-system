# Decision Log

## Locked Planning Defaults

- Product category: personal security platform for households
- Initial protection model: deterministic rules and playbooks first
- LLM role: explanation, bounded triage, and suggestions
- Risk policy: high-risk actions require approval
- Delivery priority: family and child safety flows before deep endpoint expansion
- Mobile and web role: companion experience, family dashboard, notifications, approvals, and learning-center flows

## Decisions Still Needed

### Product Decisions

- Which family and child protection cases are mandatory for launch?
- Which social platforms should be supported first?
- How tightly should the Learning Center be coupled to incidents and approvals?

### Technical Decisions

- Which existing local code should be promoted into the first public repo baseline?
- Should the first companion slice start mobile-first, web-first, or both?
- Is the default MVP stack Cloudflare plus Supabase plus LangGraph, or should that be revised now?

### Operational Decisions

- Which launch region and privacy posture are the default?
- How much manual review is acceptable during beta?
- What is the minimum test bar before first public push?

## Decision Criteria

When a choice is unclear, use these filters:

1. user value in the first 90 days
2. feasibility for a small team
3. deterministic verification
4. privacy and support burden
5. reversibility if the assumption is wrong

## Current Recommended Answers

- Mandatory MVP cases: suspicious social messages and spam, phishing links, account recovery, household approvals, learning-center recommendations
- First audience: families with children first, prosumers second
- Launch emphasis: family safety, guided recovery, and guided learning
- First implementation slice: suspicious social-message and spam review
- Architecture baseline: Cloudflare Workers and Queues, Durable Objects, Supabase, LangGraph
- Repo baseline recommendation: start from a fresh public baseline and selectively migrate from the existing local workspace instead of publishing the current tree as-is

## Change Policy

Planning decisions can change, but only if the replacement improves focus, shortens time to value, or materially reduces risk.
