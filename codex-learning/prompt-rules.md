# Prompt Rules

- Split mixed research-and-edit tasks into separate steps; first inspect and summarize the in-repo surface, then make a narrowly scoped change only if needed.
- For anything about "latest" releases or external changes, require an explicit source to compare against instead of asking the coder to discover it broadly.
- Keep each implementation step to one exact file or one exact verification command; avoid prompts that span multiple areas at once.
- State the smallest allowed outcome up front, including that `no change` is valid if the current pin or integration is already safe.
- Make the pass/fail check deterministic and local to the repo, and ask the coder to report that result directly.

