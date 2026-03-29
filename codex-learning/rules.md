# Learned Rules

- Require every generated task to name at least one existing file path and one concrete function, branch, or section anchor.
- Reject or rewrite tasks that span multiple files or multiple objectives into a single-file, single-outcome task before execution.
- Fail fast with `missing_source_file` when a task references files that do not exist; do not spend retries on ungrounded prompts.
- Keep inspection or inventory tasks to at most two steps: identify one concrete edit location, then verify.
- Ban meta-improvement tasks when recent execution success is very low; prioritize concrete source-file edits and tests instead.

