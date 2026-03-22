# Prompt Rules

- Start by answering the exact requested inspection step with concrete function names and exact `task_intent` fields before making any code changes.
- When a task says "single function/path", stay on that path only and avoid proposing multi-file changes or broader redesigns.
- Echo the required artifact format exactly in the response so reviewer and evaluator can match it deterministically.
- For persistence tasks, trace one record from source to queue handoff and verify the field survives unchanged at that boundary.
- If attempt 1 fails on review, narrow the retry to the missing detail or format mismatch instead of repeating the same broad response.

