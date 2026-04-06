# Fortschrittsbericht — 2026-03-27 19:05 UTC (Scheduled v9)

## Gesamtzustand: STALLED — Pipeline blockiert, Queue leer (5. Wiederholung)

### Kernmetriken

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Gesamterfolgsrate | 15% (526 Tasks) | Niedrig |
| Recent-50 | 28% | Aufwärtstrend |
| Recent-20 | 10% | **Regression** |
| Non-Timeout Success | 27% | Positiv |
| Timeout-Rate | 37% (197 von 526) | Kritisch |
| Zero-Step-Timeouts | 94% aller Timeouts | Strukturproblem |
| Registry | 20 Tasks (12 shelved, 3 failed, 3 queued, 1 pending, 1 completed) | |
| Learned Rules | 12/20 (8 Slots frei) | Gesund |
| Pipeline | **STALE seit >30h** | Blockiert |

### Kritisches Problem: Queue-Starvation (5. Wiederholung)

Die `queues/codex-agent-system.txt` (live dispatch directory) ist **erneut 0 Bytes**. Die 3 queued Tasks (task-130, 131, 132) existieren nur in `codex-queue/codex-agent-system.txt` — dort wo Worker sie **nicht lesen**.

Das v30-Update dokumentierte einen "structural fix" (Auto-Copy-Guard in strategy-loop.sh), aber der Worker-Prozess ist idle (`status.txt: state=idle, waiting_for_tasks=1`). Das bedeutet: der Guard läuft nur im Strategy-Loop, nicht beim Worker-Start. Wenn keine Strategy-Loop-Iteration stattfindet, bleibt die Queue dauerhaft leer.

**Dies ist das 5. Mal in 4 Tagen** (v23, v24, v29, v30, jetzt). Der strukturelle Fix reicht nicht aus.

### Task-Bewertung: Sind die aktuellen Tasks umsetzbar?

**3 Queued Tasks:**

1. **"Improve first-pass success rate"** (Priority 7, claude) — Ziel: planner.sh verbessern. **Umsetzbar**, aber sehr breit formuliert. Empfehlung: Auf einen konkreten Aspekt eingrenzen (z.B. "Reduce planner prompt size below 4000 tokens").

2. **"Break retry churn"** (Priority 6, claude) — Ziel: Exponential backoff in orchestrator.sh. **Umsetzbar**, konkreter Scope (1 Datei). Gute Chancen bei claude-Provider.

3. **"Reduce strategy saturation"** (Priority 4, claude) — Ziel: strategy-loop.sh anpassen. **Umsetzbar**, aber hängt davon ab, ob die Loop überhaupt regelmäßig läuft.

**1 Pending Approval:**

4. **"Improve retry success rate"** (claude) — Wartet auf Approval. Sollte geprüft und entweder approved oder mit task-131 dedupliziert werden (Überschneidung).

### Trend-Analyse: Heben wir die Success Rate?

**Langfristig: Ja.** Der Trend über 526 Tasks zeigt +4.4pp Verbesserung mit +1.36pp Velocity pro 100 Tasks. Die Non-Timeout-Erfolgsrate steigt mit +6.23pp/100 Tasks.

**Kurzfristig: Nein.** Die letzten 20 Tasks liegen bei nur 10% — eine klare Regression verursacht durch Timeout-Burst bei komplexen superheld-Tasks (iOS Notifications, Network Scanners, Gamification). 8 von 10 letzten Failures sind Timeouts.

**Kernerkenntnis:** Wenn Timeouts rausgerechnet werden, liegt die Erfolgsrate bei 27% — das System wird besser bei Tasks die es tatsächlich bearbeiten kann. Das Hauptproblem sind nicht schlechte Lösungen, sondern Tasks die gar nicht erst starten (94% Zero-Step-Timeouts).

### Empfohlene Modifikationen

#### System/Konfiguration (Priorität 1-3):

1. **Queue-Sync als Worker-Startup-Check** — Der Auto-Copy-Guard muss auch beim Worker-Start laufen, nicht nur in der Strategy-Loop. Sonst bleibt die Queue bei idle Workers permanent leer.

2. **Pipeline-Stale-Flag automatisch clearen** — `pipeline_stale: true` seit >30h blockiert den Self-Improve-Loop. Ein Watchdog sollte das Flag nach erfolgreichem Queue-Dispatch automatisch zurücksetzen.

3. **Zero-Step-Timeout-Diagnose** — 94% der Timeouts passieren vor dem ersten Arbeitsschritt. Das deutet auf zu großen Context beim Planner-Start hin. Tasks mit >3 Dateien oder >24 Wörtern sollten automatisch abgelehnt werden (Regel existiert, wird aber offenbar nicht durchgesetzt).

#### Tasks (Priorität 4-5):

4. **Task-133 deduplizieren** — "Improve retry success rate" überlappt stark mit task-131 "Break retry churn". Eines davon shelven.

5. **Superheld-Tasks pausieren** — Die letzten Timeout-Bursts kommen von komplexen superheld-Tasks (iOS/Android SDK). Bis die Timeout-Rate sinkt, sollten nur codex-agent-system-interne Tasks laufen.

### Fazit

Das System lernt nachweislich (+4.4pp langfristig, 198 Knowledge-Einträge, 12 konsolidierte Regeln), aber ein **struktureller Queue-Bug** verhindert seit 3+ Tagen jede Ausführung. Die 3 queued Tasks sind grundsätzlich umsetzbar, werden aber nie dispatched. Ohne Fix des Worker-Startup-Queue-Checks dreht sich das System im Leerlauf. Die kurzfristige Regression (10%) ist durch superheld-Timeout-Burst verursacht — nicht durch Qualitätsverlust bei tatsächlich bearbeiteten Tasks.

**Nächste Schritte:**
- Queue-Entries von `codex-queue/` nach `queues/` kopieren (sofort)
- Worker-Startup-Script um Queue-Sync ergänzen (verhindert 6. Wiederholung)
- Pipeline-Stale-Flag clearen
- Task-133 gegen task-131 deduplizieren
