# Fortschrittsbericht — 28. März 2026, 18:10 UTC (Scheduled)

## Systemzustand: STALLED / Kritisch

Das System befindet sich seit ~4 Tagen in einem Deadlock. Die Pipeline ist operativ inaktiv, obwohl die Infrastruktur (Strategy-Loop, Queue-Worker, Memory-Sync) technisch läuft.

---

## Kennzahlen

| Metrik | Wert | Bewertung |
|---|---|---|
| Gesamte Tasks | 575 | — |
| All-time Success Rate | 14% | Niedrig |
| Recent Success Rate (letzte 50) | **0%** | Kritisch |
| First-Pass Success Rate | **0%** | Kritisch |
| Timeout-Rate | 36% | Hoch |
| Zero-Step Timeouts | 91% der Timeouts | Dominantes Fehlerbild |
| Letzter erfolgreicher Task | 2026-03-24T19:35:27Z | Vor 4 Tagen |
| Aktive Tasks | 0 laufend, 1 pending_approval | Pipeline leer |
| Queue (codex-queue) | 3 Tasks seit 4+ Tagen wartend | Nicht drainend |
| Self-Improve | PAUSED | Korrekt pausiert bei 0% |

## Pipeline-Deadlock: Ursachenanalyse

Das System steckt in einer dreifachen Blockade:

**1. Self-Improve ist pausiert (richtig so, aber blockierend)**
Die Pause-Datei (`codex-logs/self-improve-paused`) wurde am 28.03. um 10:29 korrekt gesetzt, weil die letzten 18 Self-Improve-Tasks alle gescheitert sind. Die Strategy-Loop erkennt jede Minute, dass die Pipeline stale ist und null approved/running Tasks hat — kann aber nichts generieren, weil die Pause aktiv ist. Das erzeugt eine Endlosschleife aus WARN-Logs ohne Aktion.

**2. Queued Tasks werden nicht verarbeitet**
Drei Tasks (130-132) liegen seit dem 24.-26. März in `codex-queue/`, aber die Queue-Worker scheinen nur `queues/` zu lesen (die dort liegenden Dateien sind leer). Es gibt eine bekannte Directory-Mismatch-Problematik zwischen `codex-queue/` (wo Tasks geschrieben werden) und `queues/` (wo Workers lesen).

**3. Pending Approval blockiert**
Task-001 (OpenAI Python v2.30.0 Review) wartet seit 09:32 UTC auf Approval. Ohne Auto-Approve-Mechanismus für externe Signale bleibt dieser Task stehen.

## Sind die bisherigen Tasks umsetzbar?

**Kurze Antwort: Nein, nicht in der aktuellen Konfiguration.**

Die drei wartenden Tasks (Improve First-Pass Success, Break Retry Churn, Reduce Strategy Saturation) adressieren die richtigen Probleme, aber:

- **Task-130 (First-Pass Success)**: Zielt auf `agents/planner.sh`. Das Kernproblem ist der 34KB Planner-Context, der 91% der Timeouts verursacht. Der Task ist konzeptionell korrekt, aber die Ausführung scheitert selbst am selben Problem (oversized context → zero-step timeout).
- **Task-131 (Break Retry Churn)**: Retry-Churn wurde durch den Zombie-Guard bereits teilweise entschärft. Der Task ist weniger kritisch.
- **Task-132 (Reduce Strategy Saturation)**: Strategy Saturation ist ein Symptom, nicht die Ursache. Solange der Planner-Context zu groß ist, hilft eine Reduktion der Saturation nichts.

**Der OpenAI-Signal-Task (task-001)** ist umsetzbar und risikoarm, hat aber keine Auswirkung auf die Kernprobleme.

## Hebt sich die Success Rate?

**Nein.** Der Trend ist klar negativ:

```
Tasks 401-450:  22% Success
Tasks 451-500:  26% Success (Peak)
Tasks 501-550:  10% Success
Tasks 551-575:   0% Success ← aktuell
```

Die Verbesserungsgeschwindigkeit liegt bei **-0.69 Prozentpunkten pro 100 Tasks**. Das System verschlechtert sich, statt sich zu verbessern. Seit dem 24. März gab es keinen einzigen erfolgreichen Task mehr.

## Notwendige Modifikationen

### P0 — Ohne diese Änderungen bleibt das System blockiert

1. **Planner-Context auf <10KB reduzieren**
   - 91% aller Timeouts passieren vor Step 1 (Zero-Step), weil der Planner 34KB Context zusammenbaut
   - In `agents/planner.sh` → `fallback_planner()` muss die Context-Assemblierung radikal gekürzt werden
   - Maximal 2 ähnliche Tasks, 40-Zeilen-Snippets, kein volles Archiv

2. **Queue-Directory-Mismatch fixen**
   - Tasks werden in `codex-queue/` geschrieben, Workers lesen aus `queues/`
   - Entweder Worker auf `codex-queue/` umstellen oder Sync-Mechanismus einbauen
   - Aktuell gehen alle neuen Tasks verloren

3. **Self-Improve kontrolliert re-enablen**
   - Die Pause ist berechtigt, aber ohne sie passiert gar nichts
   - Vorschlag: Pause aufheben, aber Scope drastisch einschränken (nur 1-Datei-Änderungen, max 20-Wort-Prompts)

### P1 — Stabilisierung nach Entsperrung

4. **Task-Timeout auf minimum 300s erhöhen**
   - Aktuell reichen ~130s nicht, wenn 60s für Planning draufgehen
   - Bereits in CLAUDE.md als Ziel dokumentiert (420s→600s), aber nicht umgesetzt

5. **Auto-Reject für Pending-Approval nach 6h**
   - Externe Signal-Tasks, die niemand approved, blockieren den einzigen Registry-Slot
   - Timeout-basiertes Auto-Reject oder Auto-Shelve einführen

6. **Rule-Set-Rollback prüfen**
   - Frühere Konfiguration erreichte 64% Success vs. aktuelle 0%
   - Unklar, welche Regeländerung den Absturz verursacht hat

### P2 — Langfristige Verbesserungen

7. **Provider-Routing validieren**: Claude-Routing für learning/code_quality Tasks prüfen
8. **Registry-Compaction**: 4.4MB Archiv regelmäßig komprimieren
9. **Kategorie-spezifische Retry-Budgets** statt globaler Limits

## Zusammenfassung

Das System hat starke diagnostische Fähigkeiten (88 Learnings, 20 Regeln, korrekte Failure-Klassifizierung) und eine solide Architektur. Aber es ist operativ tot, weil drei Probleme sich gegenseitig blockieren: der oversized Planner-Context verursacht Timeouts → Timeouts führen zu 0% Success → 0% Success pausiert Self-Improve → ohne Self-Improve keine automatische Reparatur.

**Empfehlung**: Manueller Eingriff an den drei P0-Punkten. Insbesondere die Planner-Context-Reduktion ist der Hebel mit der größten Wirkung. Danach Self-Improve mit eingeschränktem Scope re-enablen und beobachten, ob die Success Rate über 10% steigt, bevor weitere Autonomie zugelassen wird.
