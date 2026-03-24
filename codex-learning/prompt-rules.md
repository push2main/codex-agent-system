# Prompt Rules

- Require the prompt to name the exact file and function that must be inspected before any edit.
- Require the task to reuse already persisted project data on disk and forbid introducing new schema unless the inspected path proves it is missing.
- Require one small planning-path change only; do not combine storage, UI, and planner updates in the same task.
- Require the prompt to state the exact project artifacts to load for context, such as steering and sources files under the target project.
- Require a lightweight verification that the planner input now includes the reused project metadata without changing unrelated behavior.

