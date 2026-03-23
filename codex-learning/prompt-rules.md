# Prompt Rules

- Keep prompts to one file, one behavior change, and one named verification command; avoid combining patching and broad validation in the same step.
- When a task has repeated timeout history, require an inspect-first step that names the exact hook to change before asking for any edit.
- For board or metrics work, tell the agent to derive new flags only from already persisted fields and to reuse the existing payload and health-decision path.
- If the previous failure was a coder command error, make the next prompt specify the exact file to patch and forbid any extra files, schema changes, or command chaining.
- Ask for the exact verification exit result only after the code change is complete; do not bundle reporting requirements that can distract from the minimal patch.

