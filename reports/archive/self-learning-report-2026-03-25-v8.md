# Self-Learning System Analysis & Fixes — 2026-03-25 (Iteration 8)

## Leitfrage: Lernt das System effizient dazu?

**Kurze Antwort: Nein — aber die Ursachen sind jetzt identifiziert und behoben.**

Das System zeigt zwar einen positiven Trend (4-6% → 22-26% Erfolgsrate in neueren Fenstern), aber drei strukturelle Probleme verhinderten effizientes Lernen. Diese wurden in dieser Iteration durch Code-Änderungen behoben.

---

## Metriken vor den Fixes

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Gesamterfolgsrate | 15% (79/522) | Kritisch niedrig |
| Letzte 50 Tasks | 28% | Verbessernd |
| First-Pass-Rate | 55% | Akzeptabel |
| Timeout-Rate | 36% (235 Timeouts) | Kritisch |
| Zero-Step-Timeouts | 100% aller Timeouts | Planner frisst Budget |
| Diagnostic Coverage | 21% (91/443) | Learning-Loop blind |
| Zombie Tasks | 17 Titel × 151 Slots | Massive Verschwendung |
| Registry-Druck | 1.18 MB | Dashboard-Performance |

## Problem 1: Diagnostic Coverage bei 0% für neue Failures

**Ursache:** `resolve_failed_step_text` bereicherte nur "generische" Steps. `append_task_record` hatte keinen Fallback für leere `FAILED_STEP_TEXT`. Ergebnis: 100% der Failures im task log haben ein leeres `failed_step`-Feld.

**Fix (orchestrator.sh):**
- `resolve_failed_step_text` erweitert: extrahiert jetzt Error-Context aus coder UND reviewer JSON (message, error, data.summary, data.reason) für ALLE Failures
- `append_task_record` hat jetzt Multi-Level-Fallback: plan.json → failure-classification.json → coder/reviewer Logs → strukturierter Fallback-String
- Garantie: Kein Failure wird mehr ohne Diagnostic-Text geloggt

## Problem 2: Zombie Tasks werden endlos regeneriert

**Ursache:** Strategy hatte keinen Mechanismus, um Task-Titel zu blocken, die historisch 5+ Mal gescheitert sind. 17 Zombie-Titel verbrauchten 151 Worker-Slots.

**Fix (strategy.sh):**
- `build_zombie_title_blocklist()` liest tasks.log und baut Set von Titeln mit 5+ Failures
- `is_zombie_title()` prüft exakte Matches UND 80% Wort-Überlappung (Fuzzy-Match)
- Guard eingefügt vor `create_task()` und `create_enterprise_seed_task()`
- Verifiziert: Alle 17 bekannten Zombies werden geblockt, neue Tasks passieren

## Problem 3: Keine Messung der Lern-Effektivität

**Ursache:** Metrics trackten nicht, ob Diagnostic Coverage sich verbessert. Ohne Messung kein Feedback-Loop.

**Fix (task_metrics.py):**
- Neue Felder: `diagnostic_coverage`, `recent_diagnostic_coverage`, `failures_with_diagnostic`, `total_failure_records`
- Ermöglicht: Trend-Tracking ob Fix 1 wirkt (Ziel: >80% Coverage für neue Failures)

## Erwartete Auswirkungen

| Fix | Erwartete Verbesserung |
|-----|----------------------|
| Diagnostic Extraction | 0% → >80% Coverage für neue Failures → Learner kann Patterns erkennen |
| Zombie Blocklist | 151 verschwendete Slots → 0 (17 Titel permanent geblockt) |
| Metrics Coverage | Messbarer Feedback-Loop für Lern-Effektivität |

## Geänderte Dateien

1. `agents/orchestrator.sh` — resolve_failed_step_text + append_task_record Fallbacks
2. `agents/strategy.sh` — Zombie-Blocklist-Funktionen + Guards bei Task-Erstellung
3. `scripts/task_metrics.py` — Diagnostic Coverage Metriken
4. `codex-learning/rules.md` — 3 neue code-enforced Rules
5. `CLAUDE.md` — Aktualisierte System Health + Fix-Dokumentation

## Nächste Schritte

1. **Monitoring:** Nach 50 neuen Tasks prüfen ob `recent_diagnostic_coverage` > 80%
2. **Registry-Kompaktierung:** `scripts/compact-registry.sh` ausführen für superheld-Projekt (1.08 MB)
3. **Rule Effectiveness:** Nach 100 Tasks prüfen ob `rule-effectiveness-report.json` positiven Delta zeigt
4. **Planner-Optimierung:** Zero-Step-Timeout-Rate bei neuen Tasks überwachen (60s-Cap sollte helfen)
