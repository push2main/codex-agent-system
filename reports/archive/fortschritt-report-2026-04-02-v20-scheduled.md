# Fortschrittsbericht — 2026-04-02 (v20, Scheduled)

## Gesamtzustand: Stabil, Pipeline im Leerlauf

Das System läuft stabil. Die Successrate hat sich historisch von 4% auf 96–98% verbessert. Beide Queues sind leer, der Self-Improve-Mechanismus ist durch `cooldown_active` blockiert. Das System produziert keine neuen Feature-Tasks — es läuft nur noch der Verify-Loop im Superheld-Projekt.

---

## Kennzahlen (Stand 2026-04-02 17:07 UTC)

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Gesamttasks | 775 | |
| All-Time Successrate | 30% | Durch 400+ frühe Fehlschläge belastet |
| Recent-50 Successrate | 98% | Hoch, aber überwiegend Verify-Loops |
| First-Pass-Success | 77% | Solide |
| Timeout-Rate | 27% (212/775) | Historisch — aktuell 0 Timeouts |
| Registry-Größe | 264 KB / 512 KB | Gesund |
| Aktive Alerts | 2 (retry_churn high, loop_effort warning) | Bedarf Aufmerksamkeit |
| Lernregeln | 5 von 20 Slots belegt | Unterausgelastet |
| Archiv | 1103 Tasks (196 completed, 406 failed, 375 shelved, 121 rejected) | |

### Trend (50er-Fenster)

```
Tasks   1- 50: 34%  →  Tasks 51-100:  4% (Tiefpunkt)
Tasks 101-200:  5%  →  Tasks 201-300: 13%
Tasks 301-400: 13%  →  Tasks 401-500: 24%
Tasks 501-600: 12%  →  Tasks 601-650: 58% (Durchbruch)
Tasks 651-700: 86%  →  Tasks 701-775: 96-98% (aktuell)
```

---

## Sind die bisherigen Tasks umsetzbar?

### Hauptregistry (codex-agent-system) — 11 Tasks

**3 Quick-Win Tasks, die reaktiviert werden sollten:**

1. **task-002** (shelved) — Unit-Test für clamp_prompt_context (Impact 7, Effort 1). Root-Cause wurde behoben. Direkt umsetzbar.
2. **task-003** (shelved) — Unit-Test für classify_retry_failure (Impact 7, Effort 1). Gleicher Root-Cause, behoben. Direkt umsetzbar.
3. **task-004** (shelved) — Learner-Fix dedup-Kommentar (Impact 6, Effort 1). Einfache Textänderung.

**2 Tasks durch Zombie-Guard blockiert:**

4. **task-005** — System-Work-Buffer (26 Prior Failures → Zombie-Guard). Nicht mehr sinnvoll in dieser Form.
5. **task-009** — Inventory-Task (5 Prior Failures → Zombie-Guard). Repetitives Muster, korrekt geblockt.

**1 Task möglicherweise obsolet:**

6. **task-010** — Reduce Timeout Rate. 0 Timeouts in den letzten 74+ Tasks → Problem scheint gelöst. Kann archiviert werden.

**4 Tasks erfolgreich abgeschlossen:** task-006, 007, 008, 011.

### Superheld-Projekt — 11 Tasks

10 completed, 1 failed. Alle Tasks sind Verify-Loops (Dashboard-Incident-ID, Credential-Recovery). **Kein echtes Feature-Work mehr.** Das Projekt dreht sich im Kreis.

---

## Hauptblocker

### 1. Self-Improve ist tot
- `self-improve-run.json`: `cooldown_active` als dominant_reason
- Alle Zähler auf 0: 0 detected, 0 generated, 0 submitted
- `self-improve-automation-memory.json`: source=none, kein automation_id
- **Ohne aktiven Self-Improve entstehen keine neuen Tasks**

### 2. Queues sind leer
- Keine Tasks in der Queue — weder für codex-agent-system noch für superheld
- Der Loop produziert nur noch Verify-Wiederholungen

### 3. Alerts aktiv
- **retry_churn (high)**: 22 Analysis-Runs, Churn weiterhin aktiv
- **loop_effort (warning)**: 23 überflüssige Step-Attempts über 11 Tasks

---

## Empfehlungen

### Sofort umsetzbar (kein User-Eingriff nötig)
- Tasks 002, 003, 004 könnten reaktiviert werden — sie sind low-effort Quick Wins
- Task 010 sollte als "resolved" archiviert werden (Timeout-Problem gelöst)

### Systemmodifikationen empfohlen
1. **Self-Improve-Cooldown zurücksetzen** — Der Cooldown blockiert die gesamte Pipeline. Ohne Reset entsteht kein neues Work.
2. **Verify-Loop-Erkennung** — Das Superheld-Projekt wiederholt dieselben 2-3 Verify-Tasks endlos. Ein Mechanismus, der nach N erfolgreichen Verifications denselben Task-Typ pausiert, würde Verschwendung reduzieren.
3. **Zombie-Guard Titel-Generierung** — Der Task-Generator erzeugt immer noch Tasks, die sofort geshelved werden (z.B. "Inventory current decision path..." 20x). Der Generator braucht Zugriff auf die Zombie-Liste, um diese Titel gar nicht erst vorzuschlagen.
4. **Lernregeln auffüllen** — Nur 5/20 Slots belegt. Die erfolgreichen Muster der letzten 100 Tasks (2-Step-Plans, Context-Clamping) sollten als Regeln formalisiert werden.

### Strategische Frage
Die 98% Successrate basiert auf trivialen Verify-Tasks. Um zu validieren, dass die Verbesserungen auch bei echten Feature-Tasks halten, muss **neues, substanzielles Work** eingespeist werden — entweder durch:
- Reaktivierung der shelved Tasks (002-004)
- Manuelle Task-Erzeugung für das Superheld-Projekt
- Reset des Self-Improve-Cooldowns

---

## Fazit

Das System ist technisch gesund und hat eine beeindruckende Lernkurve gezeigt. Aber es befindet sich im **produktiven Stillstand** — die Pipeline produziert keine echten neuen Tasks, der Self-Improve ist blockiert, und die hohe Successrate ist ein Artefakt trivialer Verify-Loops. Die nächste Priorität ist klar: Cooldown zurücksetzen, Quick-Win-Tasks reaktivieren, und echtes Feature-Work einspeisen, um die Verbesserungen unter Last zu validieren.
