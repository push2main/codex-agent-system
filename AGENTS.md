# Agent Rules

## Goal
Build a stable, self-improving, production-ready AI system.

## Execution
- Runs repeatedly (scheduled)
- Must remain stable at all times
- Only small incremental changes

## Rules
- NEVER break the system
- NEVER rewrite large parts
- ALWAYS verify changes

## Agents
All agents must:
- return JSON
- be deterministic

## Safety
- max retries = 2
- no infinite loops
