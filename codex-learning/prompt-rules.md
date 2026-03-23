# Prompt Rules

- Make read-only inspection tasks explicitly forbid edits and require a literal copy of names or selectors from the file with no inference or renaming.
- Ask for one narrow outcome per step: inspect first, verify second, and avoid mixing implementation or broader UI analysis into the same prompt.
- Require the agent to use exact file-local evidence only, such as literal selectors and exact `@media` lines present in the target file.
- State the preservation boundary directly: record the existing dashboard structure that must remain unchanged, not a reinterpretation of it.
- Require a minimal deterministic output format that only lists confirmed literals and a verification status.

