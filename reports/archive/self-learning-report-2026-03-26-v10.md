# Self-Learning Report — Iteration 10
**Date:** 2026-03-26T00:15:00Z
**Trigger:** Scheduled task (autonomous)

## Leitfrage: Lernt das System effizient dazu?

**Ja, das System lernt effizient** — aber es war 24+ Stunden durch einen Multi-Layer-Deadlock blockiert.

### Lerneffizienz-Metriken

| Metrik | Wert | Trend |
|--------|------|-------|
| Gesamterfolgsrate | 15% (79/522) | ↑ +1.73pp/100 Tasks |
| Non-Timeout-Erfolgsrate | 28% (287 Tasks) | ↑ +6.8pp/100 Tasks |
| Letzte 50 Tasks | 28% | Stabil |
| First-Pass-Erfolgsrate | 55% (22 Tasks) | — |
| Diagnostic Coverage | 100% | Stabil |
| Gelernte Regeln | 20 (Maximum) | Konsolidiert |

**Kernaussage:** Die Non-Timeout-Lerngeschwindigkeit von +6.8pp/100 Tasks ist 4× stärker als das Gesamtsignal. Das System lernt effektiv, wenn es nicht durch Timeouts blockiert wird.

### Identifizierte Probleme

#### Problem 34: Multi-Layer-Deadlock (KRITISCH)

Die Pipeline war seit 2026-03-25T07:27Z komplett blockiert (24+ Stunden). **5 unabhängige Blocker** verhinderten gleichzeitig die Erholung:

1. **low_success + backlog:** success_rate=0.15 + approved_tasks=12 → blockiert
2. **backlog_overload:** approved_tasks=12 >= threshold=8 → blockiert
3. **registry_pressure:** 1.13MB (superheld-Projekt) → blockiert
4. **loop_effort:** true (globaler Flag) → blockiert
5. **retry_churn:** true (globaler Flag) → blockiert

**Ursache:** Die Queue-Gate in `strategy-loop.sh` hatte keinen Staleness-Escape. Wenn keine Tasks laufen, werden die Metriken nie aktualisiert → Gate bleibt ewig aktiv → Pipeline tot.

**Iteration 9 half nicht**, weil sie nur die Timeout-Crisis-Gate in `strategy.sh` fixte. Aber `strategy.sh` wird NIE aufgerufen, wenn `strategy-loop.sh` die Queue-Gate blockiert.

#### Problem 35: Cross-Project-Metrik-Bleed

`approved_tasks=12` stammt aus dem superheld-Projekt (nicht erreichbar von VM). Die lokale Registry hat 0 approved Tasks. Globale Flags (`retry_churn`, `loop_effort`, `registry_pressure`) blockieren die lokale Strategie.

#### Problem 36: Timeout-Crisis-Signal eingefroren

Das letzte Fenster (501-522) zeigt 77% Timeout-Rate. Ohne neue Tasks wird dieses Fenster nie aktualisiert → `timeout_crisis_active` bleibt für immer `true`.

### Implementierte Fixes

#### Fix 34: Staleness-Escape-Hatch (strategy-loop.sh)

Wenn keine Tasks in >6 Stunden ausgeführt wurden (`pipeline_stale=true`), werden ALLE Health-Flags überschrieben:
- `effective_pressure=false`
- `effective_loop=false`
- `effective_churn=false`

Dies stellt sicher, dass keine Kombination von Flags die Pipeline permanent blockieren kann.

#### Fix 35: Cross-Project-Isolation (strategy-loop.sh)

- Lokale `approved_count` wird aus der lokalen Registry berechnet (nicht aus globalen Metriken)
- Cross-project `registry_pressure` wird unterdrückt wenn `pressure_reason=cross_project_registry_pressure`
- Shared-Health-Flags (`retry_churn`, `loop_effort`) werden effektiv unterdrückt wenn `shared_health_suppressed=1`

#### Fix 36: Pipeline-Staleness-Tracking (task_metrics.py + strategy.sh)

- Neue Funktion `_compute_pipeline_staleness()` in task_metrics.py — berechnet ob letzte Task >6h alt
- `pipeline_stale` und `pipeline_stale_since` Felder in metrics.json
- Timeout-Crisis-Berechnung in `strategy.sh` überspringt Crisis-Aktivierung wenn `pipeline_stale=true`

### Validierung

- `bash -n strategy-loop.sh` → OK
- `python3 -c "ast.parse(...)"` für task_metrics.py → OK
- `python3 -c "ast.parse(...)"` für strategy.sh Python-Block → OK
- CLAUDE.md auf 108 Zeilen kompaktiert (Limit: 200)
- Regeln bei genau 20 (keine Änderung nötig)

### Erwartete Auswirkungen

1. Pipeline sollte bei nächstem strategy-loop-Lauf wieder starten
2. Strategy kann trotz globalem Druck lokale Tasks generieren
3. Timeout-Crisis blockiert nicht mehr die Recovery
4. Geschätzte Erholungszeit: 20-30 neue Tasks bis zur Stabilisierung

### System-Gesundheit (Iteration 10)

```
Tasks: 522 | Erfolgsrate: 15% | Non-Timeout: 28%
Timeouts: 235 (45%) | Zero-Step: 222 (94%)
Regeln: 20 | Diagnostic: 100% | Registry: 48KB lokal
Velocity: +1.73pp/100 (gesamt) | +6.8pp/100 (non-timeout)
Pipeline: STALLED seit 24h → Fixes deployed, Erholung erwartet
Self-Learning-Iterationen: 10
```
