# Prompt Rules

- Require the prompt to name one exact guard or function to change and forbid any extra edits outside that hook.
- Require a fast deterministic verification that proves the behavior changed, not just that the file was edited.
- When the same task fails twice, narrow the next prompt to the smallest safe patch and one acceptance check.
- Tell the agent to preserve existing metrics, schema, and routing unless the task explicitly requires changing them.
- If review keeps failing after successful edits, make the acceptance condition explicit enough for reviewer and evaluator to check mechanically.

