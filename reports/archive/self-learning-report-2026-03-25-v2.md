# Self-Learning Audit Report — 2026-03-25

## Question: Lernt das System effizient dazu? Wird es bei jeder Iteration messbar besser?

### Answer: Nein — das System hatte drei strukturelle Lernblockaden, die in dieser Iteration behoben wurden.

---

## Diagnose: Warum das System nicht effizient lernte

### 1. Failure Classification Blindspot (80% "unknown")
**Problem:** 80% aller Retry-Failures wurden als "unknown" klassifiziert, weil `classify_failure()` nur den Coder-Output erhielt. Bei der häufigsten Fehlerart — Coder meldet Erfolg, Reviewer lehnt ab — enthielt der Input keine Fehlermuster.

**Impact:** Das System konnte nicht aus Fehlern lernen, weil es nicht wusste, WARUM Tasks fehlschlugen. Die Feedback-Loop war unterbrochen.

**Fix:** `agents/orchestrator.sh` erweitert: Reviewer- und Evaluator-Text wird jetzt an `classify_failure()` übergeben. Erwartete Verbesserung: "unknown" Rate sinkt von 80% auf ~30%.

### 2. Retry Churn via Re-Approval Reset
**Problem:** Re-Approval löschte den `execution`-Block und damit den Attempt-Counter. Task-127 erreichte Attempt=5 bei max_retries=2 durch 3 Re-Approvals. Das Server.js trackt `cumulative_attempts`, aber der Queue-Worker (`get_task_retry_count`) ignorierte diesen Wert.

**Impact:** Unendliche Retry-Loops verbrauchten Queue-Kapazität ohne Fortschritt. 62 Tasks hatten "loop effort" mit 156 Extra-Step-Attempts.

**Fix:** `scripts/lib.sh` → `resolve_task_retry_state()` gibt jetzt `cumulative_attempts` als 4. Zeile aus. `get_task_retry_count()` verwendet `max(file_count, cumulative_attempts)`.

### 3. Zu wenige Learned Rules (5 nach 470 Tasks)
**Problem:** Der Learner-Agent war zu konservativ. 470 Tasks, aber nur 5 generische Regeln. Konkrete, wiederkehrende Muster (Backward-Compat-Fehler, Missing-Environment-Retries, Strategy-Regeneration) wurden nicht als Regeln erfasst.

**Impact:** Gleiche Fehler wiederholten sich ohne Lerneffekt.

**Fix:** `codex-learning/rules.md` von 5 auf 14 Regeln erweitert, organisiert in Kategorien (Core Planning, Failure Prevention, Provider Routing). Alle aus 2+-Task-Patterns extrahiert.

---

## Messbare Metriken

| Metrik | Vorher | Erwartet nach Fix |
|--------|--------|-------------------|
| Success Rate (overall) | 14% | 20-25% (durch weniger Retry-Verschwendung) |
| Success Rate (traced batch) | 38% | 45%+ (bessere Failure-Klassifikation) |
| "Unknown" Classification Rate | 80% | ~30% |
| Learned Rules | 5 | 14 |
| Retry Churn Tasks | 62 | ~10 (cumulative_attempts enforced) |
| Extra Step Attempts from Loops | 156 | ~30 |

---

## Geänderte Dateien

1. **`scripts/lib.sh`** — `resolve_task_retry_state()`: gibt cumulative_attempts aus; `get_task_retry_count()`: verwendet max(file, cumulative)
2. **`agents/orchestrator.sh`** — Failure classification erhält jetzt Reviewer+Evaluator-Text
3. **`codex-learning/rules.md`** — Von 5 auf 14 Regeln erweitert
4. **`CLAUDE.md`** — Aktualisiert mit neuen Learnings und System Health
5. **`codex-memory/learnings.md`** — 3 neue Learnings dokumentiert

---

## Offene Punkte (nicht in diesem Run lösbar)

1. **Superheld Registry Pressure (944KB)** — Externe Datei nicht aus Sandbox erreichbar. Nächster Run sollte `bash scripts/compact-registry.sh` mit TASK_REGISTRY_FILE auf superheld zeigend ausführen.
2. **Provider-Stats für "learning" Kategorie** — 0%/7% Erfolgsrate deutet auf strukturelle Task-Probleme hin, nicht Provider-Issues. Task-Spezifikationen in dieser Kategorie sollten überprüft werden.
3. **Dashboard read performance** — Registry-Pressure bleibt bei 1MB+ wegen superheld. Per-project API-Paginierung würde dies lösen.
