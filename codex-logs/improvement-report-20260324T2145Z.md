# System Improvement Report — 2026-03-24T21:45Z

## 1. Identified Weakness: Task Complexity Mismatch

**Core problem**: The system generates implementation tasks that exceed the coder agent's demonstrated capability, resulting in a 12% overall success rate. Analysis of the current registry (31 tasks) reveals a stark pattern:

- **Successful tasks** (6/31): Inventory inspections, metric detections, single-file replacements
- **Failed tasks** (24/31): Multi-file implementations, new feature additions, complex integrations

Successful task types: "Inventory current state for X", "Detect low first-pass success", "Replace X with bounded experiment"
Failed task types: "Add a project sources registry", "Implement persisted sources", "Inject project steering into planning"

Additionally, 3 duplicate failed tasks existed in the registry (same title, different IDs), indicating the deduplication check was missing.

**Evidence**:
- Success rate: 12% overall, ~50% for inventory tasks, <10% for implementation tasks
- 3 duplicate failed tasks consuming registry space
- Registry at 384KB (approaching 400KB pressure threshold)
- Strategy saturation and retry churn both detected

## 2. Improvements Applied

### 2a. Registry Deduplication (immediate)
- Removed 3 duplicate failed tasks (same title prefix, kept most recent)
- Registry reduced: 31 → 28 tasks, 384KB → 349KB
- Moves registry further from the 400KB pressure threshold

### 2b. Task Complexity Gating Rules (knowledge + rules)
Added to `codex-learning/rules.md`:
- **Complexity gate**: Prefer inventory/detection tasks when success rate < 30%
- **Deduplication guard**: Check for equivalent failed tasks before creating new ones
- **Inventory-first decomposition**: After 3+ root failures, require inventory task before implementation

Added to `codex-memory/knowledge.json` (3 new rules):
- `task_selection`: Prefer inventory over implementation when success rate < 30%
- `task_selection`: Deduplicate against existing failed tasks before creation
- `stability`: Inventory-first workflow for repeatedly-failed roots

### 2c. No code changes required
These are knowledge/rule changes that influence the strategy loop's task generation decisions. The strategy loop already reads from rules.md and knowledge.json.

## 3. Outcome: Applied (pending next strategy cycle)

**Immediate effect**: 3 duplicate tasks removed, registry 9% smaller.
**Expected next-cycle effect**: Strategy loop will prefer inventory tasks, skip duplicate task creation, and decompose failed roots into inventory-first workflows.

## 4. Knowledge Gained

- The system's success/failure pattern is predictable by task type: read-only tasks succeed, write-heavy tasks fail
- The deduplication gap allowed the same goal to consume multiple registry slots
- Rules in `rules.md` and `knowledge.json` are the primary influence channels for strategy behavior — no code changes needed to shift task selection quality
- The root-level failure ceiling (previous improvement) prevents retry cascading; complexity gating prevents wasteful task generation at the source

## 5. Next Best Improvement

**Automatic task-type tagging at generation time**: When the strategy loop creates a task, classify it as `inventory`, `detection`, `single-file-edit`, or `multi-file-implementation` based on the step descriptions. Use this tag to enforce the complexity gate programmatically in the strategy loop code (rather than relying on the LLM reading the rules). This would make the gate deterministic and auditable.
