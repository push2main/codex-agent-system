# Architecture Overview

## Reference Shape

Superheld should be designed as four layers:

1. native sensors per operating system
2. secure device channel for telemetry and commands
3. cloud brain for normalization, correlation, and incident state
4. consumer UX for explanation, approval, and guided response

## Default Technical Direction

- endpoint logic: Rust shared core with native OS-specific integrations
- cloud edge: Cloudflare Workers plus Queues plus Durable Objects
- control plane: Supabase Postgres
- orchestration: LangGraph for incident workflows and approvals
- push: Firebase Cloud Messaging

## Control Principles

- deterministic rules and playbooks decide actions
- LLMs are used for explanation, triage, and suggestions
- high-risk actions pause for human approval
- incident state must be durable and auditable

## Architecture Boundaries

- social-media protection in the MVP should be companion-style: analysis, guidance, approvals, and learning, not deep control over third-party platforms
- iOS and Android are companion surfaces for alerts, message review, account protection, and learning flows early on
- deeper endpoint visibility remains a later protection layer, not the first user-facing proof point

## Immediate Architecture Deliverables

- shared telemetry schema
- device, identity, household, and incident data model
- first three playbooks with clear approval boundaries
- secure command path and idempotent action model
