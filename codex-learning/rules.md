# Learned Rules

- Keep single-file tasks narrowly scoped: if a task targets one file, do not expand writable scope beyond that file, and split mixed "investigate plus implement" work into bounded steps only when necessary.
- For review-rejection retries on single-file tasks, require minimal structured context from the rejection: target file, a concrete edit anchor, and the reason for retry; if that context is missing, route to inventory instead of retrying implementation.
- Suppress near-duplicate implementation tasks when a very recent open or successful task already targets the same file and intent; prefer emitting a single verification or inventory task instead.
- Treat low-confidence successes conservatively: if success follows multiple attempts or weak review evidence, require bounded verification before using that success to suppress related follow-up work.
- Reject rules that depend on specific filenames, exact word counts, exact hour windows, exact score cutoffs, or exact phrase patterns; generalize them before adoption.

