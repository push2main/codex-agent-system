# Learned Rules

- Reject rules that hard-code exact files, selectors, or breakpoint ranges unless the task already specifies them.
- Keep prompts single-purpose: inspect first, edit second, verify last.
- Before editing, restate the current relevant lines or values found in the file.
- Require one deterministic acceptance check tied to the requested change.
- On retry, narrow the prompt further to one small change and one pass/fail verification.

