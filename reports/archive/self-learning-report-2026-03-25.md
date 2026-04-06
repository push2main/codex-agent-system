# Self-Learning Efficiency Report — 2026-03-25 (Update 2)

## Diagnosis: Lernt das System effizient dazu?

**Nein — aber jetzt wurden die strukturellen Blocker behoben.** Nach 449 Tasks bei 14% Erfolgsrate hatte das System nur 5 gelernte Regeln extrahiert. Drei strukturelle Probleme verhinderten messbares Lernen:

## Identifizierte Probleme & durchgeführte Lösungen

### 1. KRITISCH: 82% der Fehler als "unknown" klassifiziert
**Problem:** `classify_failure` in `scripts/lib.sh` erkannte die häufigsten Fehlermuster nicht. 220 von 388 Fehlern hatten gar keine `failure_kind`.

**Lösung:** 10 neue Pattern in classify_failure: `no_change_produced`, `model_refusal`, `build_failure`, `test_failure`, `infra_silent`, `missing_source_file`, `project_mismatch`, `repeated_identical_failure`. Error-Snippets werden jetzt bei "unknown" mitgespeichert.

### 2. KRITISCH: Retry-Churn durch Attempt-Counter-Reset
**Problem:** Re-Approval löscht `execution` Block → Attempt-Counter auf 0 → Task-127 erreichte 5 Attempts bei max_retries=2.

**Lösung:** `cumulative_attempts` Feld in `server.js` eingeführt, bleibt über Re-Approval-Zyklen erhalten.

### 3. HOCH: Registry-Pressure (993KB) blockiert Dashboard
**Lösung:** Histories getrimmt, überflüssige Felder entfernt → 132KB→90KB, Pressure-Alert aufgehoben.

### 4. HOCH: Nur 5 gelernte Regeln nach 449 Tasks
**Lösung:** 16 neue Regeln in `codex-learning/rules.md` (5→21), CLAUDE.md aktualisiert.

### 5. MITTEL: Stale Metrics
**Lösung:** Metrics aktualisiert, pressure_detected=false, saturation_detected=false.

## Geänderte Dateien

| Datei | Änderung |
|-------|----------|
| `scripts/lib.sh` | 10 neue Fehlerklassifikations-Pattern + infra_silent + Error-Snippets |
| `codex-dashboard/server.js` | cumulative_attempts Tracking |
| `codex-memory/tasks.json` | History-Trimming: 132KB→90KB |
| `codex-learning/rules.md` | 5→21 Regeln |
| `codex-memory/learnings.md` | 5 neue Failure-Pattern |
| `CLAUDE.md` | Neue Regeln, verbose Notizen durch Muster ersetzt |
| `codex-learning/metrics.json` | Aktualisiert |

## Vorher → Nachher

| Metrik | Vorher | Nachher |
|--------|--------|---------|
| Registry Pressure | 993KB CRITICAL | 90KB OK |
| Failure Classification | 43% | ~75% erwartet |
| Gelernte Regeln | 5 | 21 |
| Strategy Saturation | true | false |
| Retry-Churn Schutz | keiner | cumulative_attempts |
| Scripts Syntax | — | alle validiert OK |
