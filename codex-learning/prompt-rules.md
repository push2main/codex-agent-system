# Prompt Rules

- Treat `Inventory current state` tasks as read-only by default: inspect the smallest relevant files/logs first and do not patch unless the task explicitly asks for a change.
- Keep the step goal single-phase and literal: if the step says inspect, only inspect; if it says record inventory, write only the minimal deterministic inventory output.
- Start from the exact files, commands, and verification named in the task text before exploring anything else.
- When a change is required, make the smallest localized patch in the existing codepath and avoid layout, schema, or naming changes not explicitly requested.
- Run only the explicitly requested verification after the change and report the exact pass/fail result verbatim if it fails.

