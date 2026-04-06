---
paths: agents/reviewer.sh
paths: agents/evaluator.sh
---

- On review_rejection, include a structured diff hint in the rejection message for the retry
- Reviewer must output a classification field (pass, fail, indeterminate) — never omit it
- Evaluator must capture failure_kind for every non-SUCCESS result
