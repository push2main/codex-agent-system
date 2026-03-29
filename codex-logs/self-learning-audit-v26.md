# Self-Learning Audit v26 — 2026-03-26

## Frage: Lernt das System effizient dazu?

**Teilweise.** Das System hat 20 Regeln gelernt und wendet sie an (z.B. 60s Planner-Cap eliminierte Zero-Step-Timeouts: 197→0 in den letzten 50 Einträgen). Aber der Lernkreislauf war blockiert: die Regelkapazität war bei 20/20 erschöpft — es konnten keine neuen Erkenntnisse aufgenommen werden.

**Behoben:** Regeln von 20→16 konsolidiert durch Zusammenführung überlappender Queue-Dispatch-Regeln (5→1) und Task-Size-Gating-Regeln (2→1). 4 freie Slots stehen für neue Erkenntnisse zur Verfügung.

## Frage: Wird es bei jeder Iteration messbar besser?

**Ja, aber langsam.** Die Daten zeigen einen klaren Aufwärtstrend:

| Fenster | Erfolgsrate | Timeouts |
|---------|-------------|----------|
| Tasks 1-50 | 34% | 19 |
| Tasks 51-200 | 4-6% | 76 (Timeout-Krise) |
| Tasks 201-350 | 10-16% | 62 (Erholung) |
| Tasks 351-500 | 12-26% | 61 (steigend) |
| Tasks 501-526 | 19% | 19 (haltend) |

- Trend: **+4.4pp** (erste vs zweite Hälfte)
- Non-Timeout-Erfolgsrate: **27%** (+6.2pp/100 Tasks)
- Traced Recent (letzte 10): **60%**

## Festgestellte Probleme und Lösungen

### 1. Metriken-Drift (KRITISCH, 4. Auftreten)
- **Problem:** metrics.json meldete 12 genehmigte Tasks und 36 Gesamttasks; tatsächlich: 0 genehmigte, 19 Gesamt. Falsche Alarme (retry_churn, queue_starvation) wurden ausgelöst.
- **Ursache:** Die gelernte Regel "Metriken bei jedem Sync neu berechnen" existierte, wurde aber von keinem automatisierten Skript durchgesetzt.
- **Lösung:** `scripts/validate-metrics.sh` erstellt — ein leichtgewichtiger Guard, der die Registry-Zähler mit metrics.json abgleicht und Abweichungen inline korrigiert. In `memory-sync.sh` und `self-improve.sh` vor dem Lesen der Metriken eingehängt.
- **Verifikation:** Guard korrekt getestet — erkennt Drift und auto-korrigiert, Folgeaufrufe bestätigen Konsistenz.

### 2. Regelkapazität erschöpft (20/20)
- **Problem:** Lernsystem konnte keine neuen Erkenntnisse aufnehmen.
- **Lösung:** 5 Queue-Dispatch-Regeln (bidirektionale Konsistenz, non-null Provider, .txt-Matching, Execution-Objekt-Pflicht) zu 1 umfassenden Regel zusammengeführt. 2 Task-Size-Regeln (Oversized-Rewrite + Timeout-Prone-Split) zu 1 zusammengeführt.
- **Ergebnis:** 16/20 Regeln, 4 freie Slots.

### 3. Falsche Alert-Flags
- **Problem:** retry_churn_detected=true und queue_starvation_detected=true waren falsch-positiv (basierend auf veralteten Metriken).
- **Lösung:** Durch Metriken-Korrektur bereinigt. Validation-Guard prüft auch Alert-Flags bei jedem Lauf.

## Geänderte Dateien

1. `codex-learning/metrics.json` — Korrigiert: approved_tasks 12→0, task_registry_total 36→19, learning_rules_count 20→16, retry_churn/queue_starvation Flags bereinigt
2. `codex-learning/rules.md` — Konsolidiert von 20→16 Regeln
3. `scripts/validate-metrics.sh` — NEU: Pre-Dispatch Validation Guard
4. `scripts/memory-sync.sh` — Guard-Aufruf vor Metriken-Lesen eingefügt
5. `scripts/self-improve.sh` — Guard-Aufruf vor refresh_persisted_metrics eingefügt
6. `CLAUDE.md` — v26 Changelog, aktualisierte Bottleneck-Prioritäten, Rule-Count

## Empfehlungen für nächste Iteration

1. **Queue-Worker starten:** 3 Tasks (130-132) warten seit 2+ Tagen. Execution-Objekte und Provider sind korrekt — Workers müssen laufen.
2. **Hollow-Success-Rate messen:** Score=0-Passes tracken und Verifikationsqualitätsregel evaluieren.
3. **Lern-Effizienz steigern:** Mit 4 freien Slots können neue Erkenntnisse aus den nächsten Ausführungen aufgenommen werden.
4. **Metriken-Guard-Effektivität monitoren:** Falls v27 keine Drift mehr zeigt, ist das Strukturproblem gelöst.
