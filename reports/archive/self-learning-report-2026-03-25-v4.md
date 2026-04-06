# Self-Learning Audit Report — 2026-03-25 v4

## Question: Lernt das System effizient dazu? Wird es bei jeder Iteration messbar besser?

### Diagnosis

**No — the system was not learning efficiently.** Three structural problems prevented learnings from translating into runtime improvements:

1. **76% of retry failures classified as "unknown"** — The learner couldn't extract patterns from failures it couldn't categorize. Root cause: error text was not being captured at the time of recording (fix was applied to code but 47/62 historical records had empty error_text fields).

2. **42% of all failures are timeouts** — Plans were too broad (multiple platforms, 6+ files per step), causing coder agents to hit the 420-900s timeout. The planner had no post-validation to reject overly broad plans.

3. **Rules not translating to improvements** — Only 5 rules survived 522 tasks due to a previous overwrite bug (fixed). But even with accumulation working, rules were too generic ("prefer rules that address repeated failures") rather than operational ("each step must touch at most 3 files").

### Fixes Applied

| Fix | Before | After | Impact |
|-----|--------|-------|--------|
| Retroactive reclassification of 39 unknown records | 76% unknown | 13% unknown | Learner can now see that timeouts (42%) and missing_environment (19%) dominate |
| Auto-reclassification at write time in `record_retry_failure_event` | New unknowns accumulated silently | Combined error+reviewer+evaluator text checked against 10 pattern categories at write time | Prevents future unknown accumulation |
| Planner scope validation | No post-validation | Plans with >4 impl steps trimmed to 3+verify; steps mentioning 4+ files scoped down; vague broad language flagged | Should reduce timeout rate |
| 5 new operational rules in rules.md | 5 generic rules | 10 rules including timeout budgets, environment gates, scope limits | Rules now target the actual dominant failure modes |
| CLAUDE.md updated | Stale "81% unknown" guidance | Corrected to "13% unknown", new focus on timeout reduction | All future sessions see accurate priorities |

### Key Metrics

- **Unknown classification:** 76% → 13% (39 records reclassified)
- **Learned rules:** 5 → 10 (all operationally specific)
- **Timeout identified as #1 problem:** 42% of all failures (26/62 retries)
- **Missing environment identified as #2:** 19% of all failures (mostly Android/iOS/Gradle tasks)
- **Local registry:** 93KB (healthy, below 250KB threshold)
- **Superheld registry:** 1.08MB (unreachable from sandbox — needs external compaction)

### What Needs to Happen Next

1. **Strategy must stop generating Android/iOS/KMP tasks** unless Docker delegation is available — these account for ~19% of all failures
2. **Planner scope limits need validation** over the next 50 tasks to measure timeout rate reduction
3. **Superheld registry** needs external compaction (run `bash scripts/compact-registry.sh` from the superheld project directory)
4. **Learning rate** should increase from 0.96 to ~3 rules/100 tasks now that failure categories are visible
5. **First-pass success** at 55% is the best lever — most first-pass failures are scope-too-broad

### Conclusion

The system had the infrastructure for learning but was **blind to its own failure patterns** due to 76% unknown classifications. With this fix, the feedback loop is now functional: failures → classified → rules generated → planner constrained → fewer timeouts. The next 50 tasks should show measurable improvement in timeout rate and first-pass success.
