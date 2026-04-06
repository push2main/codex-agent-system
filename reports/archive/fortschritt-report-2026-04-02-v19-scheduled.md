# Fortschrittsbericht — 2026-04-02 (v19, Scheduled)

## Gesamtbild: Stabil, aber im Leerlauf

Das Codex-Agent-System hat eine beeindruckende Reifekurve durchlaufen — von 4% Successrate (Tasks 51–100) auf 96% (Tasks 701–774). Die Infrastruktur ist gesund (Registry 245 KB / 512 KB Limit, keine Crashes). **Aber: Die Pipeline produziert seit ~5 Tagen keine echten neuen Tasks mehr.** Beide Queues sind leer (0 Zeilen). Der Self-Improve-Mechanismus ist durch einen aktiven Cooldown blockiert.

---

## Kennzahlen

| Metrik | Wert | Trend / Bewertung |
|--------|------|-------------------|
| All-Time Successrate | 30% (774 Tasks) | Durch frühe Fehlschläge belastet |
| Recent-50 | 96% | Irreführend — fast nur Verify-Loops |
| First-Pass-Success | 77% (10/13) | Solide, aber kleine Stichprobe |
| Timeout-Rate | 27% (212/774) | Hauptproblem historisch |
| Zero-Step-Timeouts | ~90% der Timeouts | Planner verbraucht gesamtes Budget |
| Registry | 245 KB | Gesund, kein Pressure |
| Lernregeln | 5/20 Slots belegt | Unterdurchschnittlich |
| Archiv | 1103 Tasks (196 completed, 406 failed, 375 shelved, 121 rejected) | Hohe Shelved-Quote |
| Aktive Alerts | 2 (RETRY_CHURN high, LOOP_EFFORT warning) | Aktive Aufmerksamkeit nötig |

### Iteration-Trend (50er-Fenster)

```
Tasks   1- 50: 34% success, 19 timeouts
Tasks  51-100:  4% success,  5 timeouts  ← Tiefpunkt
Tasks 101-200:  5% success, 71 timeouts  ← Timeout-Krise
Tasks 201-300: 13% success, 57 timeouts
Tasks 301-400: 13% success, 17 timeouts  ← Timeout-Fix greift
Tasks 401-500: 24% success, 49 timeouts
Tasks 501-600: 12% success, 31 timeouts
Tasks 601-650: 58% success,  1 timeout   ← Durchbruch
Tasks 651-700: 86% success,  1 timeout
Tasks 701-774: 96% success,  0 timeouts  ← Aktuell
```

**Der Trend ist klar positiv.** Aber die letzten ~70 Tasks sind überwiegend triviale Verify-Loops aus dem Superheld-Projekt, keine echten Feature-Tasks.

---

## Sind die bisherigen Tasks umsetzbar?

### Aktive Registry (11 Tasks)

| Task | Status | Impact | Effort | Bewertung |
|------|--------|--------|--------|-----------|
| task-002 (Test clamp_prompt_context) | shelved | 7 | 1 | **Quick Win** — Root-Cause (Step-Verbosity >600 chars → review_rejection) wurde behoben |
| task-003 (Test classify_retry_failure) | shelved | 7 | 1 | **Quick Win** — gleicher Root-Cause, behoben |
| task-004 (Learner-Fix) | shelved | 6 | 1 | Wichtig — direkte Auswirkung auf Lernrate |
| task-005 (System-Work-Buffer) | shelved | — | — | Konzeptuell, hängt an Queue-Refill |
| task-009 (Cap-Inventory) | shelved | — | — | Explorativ, niedrige Priorität |
| task-010 (Reduce Timeout Rate) | shelved | hoch | — | Historisch wichtig, aber Timeout-Problem scheint gelöst |
| task-006, 007, 008 | completed | — | — | Erfolgreich abgeschlossen |
| task-011 (Retry Success Rate) | completed | — | — | Erfolgreich abgeschlossen |

**Antwort: Ja, Tasks 002, 003, 004 sind klar umsetzbar und sollten reaktiviert werden.** Task-010 hat sich durch die Systemverbesserungen möglicherweise erledigt (0 Timeouts in den letzten 74 Tasks).

### Archiv-Muster

Von 1103 archivierten Tasks sind 375 shelved und 406 failed. Die letzten Archiv-Einträge zeigen ein klares Pattern: Derselbe Inventory-Task ("Inventory current decision path…") wurde 6x hintereinander geshelved (Tasks 164–169). Das ist ein Zeichen für den Zombie-Guard, der repetitive Titel korrekt blockt — aber auch dafür, dass der Task-Generator denselben Vorschlag wiederholt erzeugt.

---

## Hauptblocker: Self-Improve-Cooldown

Die `self-improve-automation-memory.json` ist leer:
```json
{"automation_id": "", "source": "none", "external_sync_pending": true}
```

Der `self-improve-run.json` meldet `cooldown_active` als dominanten Gating-Grund. Alle Zähler stehen auf 0: 0 detected, 0 generated, 0 submitted. **Das System kann keine neuen Tasks erzeugen.**

---

## Heben wir die Successrate?

**Ja, historisch betrachtet massiv.** Von 4% auf 96% im Verlauf der 774 Tasks. Die gelernten Regeln (Step-Size-Limits, 2-Step-Plans, Context-Clamping) wirken nachweislich. Der Provider-Routing bevorzugt korrekt den Codex-Provider.

**Aber: Die aktuelle 96% ist ein Artefakt.** Sie basiert auf trivialen Verify-Tasks, nicht auf echten Feature-Implementierungen. Um zu wissen, ob die Verbesserungen auch bei anspruchsvollen Tasks halten, muss echte Arbeit wieder anlaufen.

---

## Empfohlene Modifikationen

### 1. KRITISCH: Self-Improve-Cooldown aufheben
Die `self-improve-automation-memory.json` muss rehydriert werden (automation_id setzen, source auf einen gültigen Wert, external_sync_pending auf false). Ohne dies bleiben die Queues leer.

### 2. HOCH: Tasks 002, 003, 004 unshelven
Alle drei haben Impact ≥6, Effort 1, und deren Root-Cause wurde behoben. Erwartete Erfolgswahrscheinlichkeit >80%. Task-004 (Learner-Fix) würde direkt die Lernrate verbessern und mehr der 20 Regelslots nutzen.

### 3. HOCH: Zombie-Verify-Loops im Superheld-Projekt stoppen
Die 3 rotierenden Verify-Titel (credential recovery, dashboard incident, inventory decision) verifizieren wiederholt dieselbe Funktionalität. Sie treiben die 96%-Rate künstlich hoch und verbrauchen Ressourcen. Zombie-Guard für diese Titel aktivieren.

### 4. MITTEL: External Signals auffrischen
Letztes Update: 26. März (7 Tage stale). Die Signal-Sources sollten aktualisiert werden, damit der Task-Generator relevante Impulse bekommt.

### 5. MITTEL: RETRY_CHURN-Alert untersuchen
Der Alert ist seit längerem aktiv. Da keine neuen Tasks erzeugt werden, ist er aktuell harmlos — aber beim Neustart der Pipeline könnte er wieder problematisch werden.

### 6. NIEDRIG: Iteration-Trend-Berechnung prüfen
Die metrics.json zeigt konsistente Werte, aber die Rule-Effectiveness-Report zeigt stark schwankende Performance zwischen Rule-Sets (0%–64%). Es lohnt sich zu prüfen, ob die effektivsten Rule-Sets bevorzugt werden.

---

## Fazit

Das System hat eine starke Verbesserungskurve hingelegt und die technische Basis ist solide. Die Hauptherausforderung ist nicht mehr Qualität, sondern **Aktivität**: Der Self-Improve-Cooldown hat die Pipeline eingefroren. Die vorhandenen Shelved-Tasks (002, 003, 004) sind die besten Kandidaten für einen Neustart — sie sind klein, klar definiert, und ihre früheren Fehlerursachen wurden behoben.

**Einzelne wichtigste Aktion:** Self-Improve-Cooldown aufheben, damit echte Arbeit wieder generiert wird.
