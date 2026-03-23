# Learned Rules

- Restate the file, allowed edit scope, and forbidden changes before modifying anything.
- If scope is limited to existing rules only, do not add new selectors or change other file types.
- Separate inspection from editing so changes stay constrained to the confirmed target rules.
- Verify with a read-only pass that checks the diff against the stated constraints and reports pass/fail.
- If requirements are ambiguous or incomplete, stop and ask instead of inferring.

