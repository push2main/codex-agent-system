# Learned Rules

- Require the prompt to target the smallest safe change scope and avoid unrelated edits.
- Require a fast, deterministic verification that checks behavior, not just file modification.
- After two failed attempts, narrow the next prompt to a single minimal patch with one clear acceptance check.
- Preserve existing metrics, schemas, and routing unless the task explicitly requires changing them.
- Make acceptance conditions explicit and mechanically checkable by both reviewer and evaluator.

