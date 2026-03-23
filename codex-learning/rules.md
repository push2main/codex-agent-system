# Learned Rules

- Keep each task to one small, localized change, with the exact file and condition to edit stated explicitly.
- Require an inspect-first step when behavior depends on current runtime state or counters.
- Require deterministic JSON output from every role, with no schema drift or free-form text.
- Ask for one narrow verification that proves the targeted edge case.
- Reject rules that prescribe provider-specific choices, overly specific failure patterns, or unrelated system changes.

