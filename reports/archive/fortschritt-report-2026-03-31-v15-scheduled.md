# Fortschrittsbericht — 2026-03-31 (v15, Scheduled)

**Generiert:** 2026-03-31 ~14:10 UTC, automatisierter Scheduled Run (Cowork)

---

## 1. Gesamtstatus: 82% SR stabil — Pipeline aktiv auf Superheld, Codex-System im Deadlock

Die Success Rate bleibt bei **82% über die letzten 50 Tasks** stabil. Die Pipeline ist allerdings gespalten: **Superheld-Tasks laufen erfolgreich** (4/4 der heutigen Runs = SUCCESS), während das **codex-agent-system-Projekt im Deadlock** steckt (keine neuen Tasks generiert, Queue leer, alle 11 Registry-Tasks entweder shelved oder completed).

---

## 2. Kennzahlen

| Metrik | Wert | Bewertung |
|---|---|---|
| Tasks gesamt (all-time) | 690 | +3 seit v14 |
| All-time Success Rate | 21% | historisch belastet |
| **Letzte 50 Tasks SR** | **82%** | stabil |
| First-Pass SR | 85% (17/20) | sehr gut |
| Timeout-Rate (kumulativ) | 31% (211 von 690) | keine neuen |
| Zero-Step-Timeouts | 227 kumulativ, 0 neue | eliminiert |
| Registry-Größe | 339 KB | unter 512 KB |
| Queue codex-agent-system | **LEER** | Deadlock |
| Queue superheld | **aktiv** (Tasks werden generiert + ausgeführt) | OK |
| Active Registry (codex-agent-system) | 4 completed, 7 shelved = 11 total | stagniert |
| Archiv | 1103 Tasks (196 completed, 406 failed, 375 shelved, 121 rejected) | |
| Zombie-Tasks | 20 | korrekt geshelved |
| Retry-Churn | detected: true | Monitoring aktiv |
| Diagnostic Coverage | 100% (542 Failures klassifiziert) | exzellent |
| Learning Rules | 10 aktiv, 199 Knowledge-Einträge | |

---

## 3. Trendverlauf (Iteration Windows)

| Window | SR | Timeouts |
|---|---|---|
| 1–50 | 34% | 19 |
| 51–200 | 4–6% | 76 (Lerntal) |
| 201–400 | 10–16% | 74 |
| 401–600 | 14–26% | 80 |
| **601–650** | **58%** | **1** |
| **651–690** | **82%** | **1** |

Improvement-Velocity: **+6.22pp pro 100 Tasks**. Non-Timeout-Velocity sogar **+11.07pp/100**.

---

## 4. Heutige Runs (31.03.2026)

Alle 4 heutigen Runs waren **SUCCESS** auf dem Superheld-Projekt:

| Run | Task | Score | Attempts |
|---|---|---|---|
| 13:24 | Inventory credential recovery routing | 100 | 1 |
| 13:14 | Inventory dashboard incident payload | 66 | 1 |
| 13:06 | Verify trigger-aware credential recovery | 100 | 1 |
| 12:59 | Verify dashboard incident payload coverage | 100 | 2 |

Die Superheld-Pipeline arbeitet zuverlässig mit Inventory-first + Verify-Muster.

---

## 5. Sind die bisherigen Tasks umsetzbar?

**Ja, für Superheld eindeutig.** Die Inventory-first-Strategie funktioniert hervorragend (Score 66–100, First-Pass).

**Für codex-agent-system: teilweise.** Von 11 Registry-Tasks:
- **4 completed** (syntax-check-planner, verify-step-cap, fix-learner-comment, improve-retry-success-rate) — alle erfolgreich
- **7 shelved** — davon scheiterten 3 an `review_rejection` (zu verbose Steps, inzwischen gefixt), 2 sind Meta-Tasks (external signal review, reduce-timeout-rate) und 2 Stabilitäts-Tasks

Die shelved Tasks task-002 (test context-clamp) und task-003 (test classify-retry) sind grundsätzlich umsetzbar — sie scheiterten an einem inzwischen behobenen Bug (Step-Verbosity >600 chars). Ein Requeue wäre sinnvoll als Canary-Test.

---

## 6. Heben wir die Success Rate?

**Ja, die SR wird gehalten und die Maßnahmen tragen:**

| Maßnahme | Wirkung |
|---|---|
| Step-Cap (max 6) | Zero-Step-Timeouts eliminiert (227 → 0 neue) |
| Zombie-Guard (5+ Failures → Shelve) | 20 Endlos-Loops eliminiert |
| Retry-Klassifizierung | 100% Coverage, auto-reclassify aktiv |
| Pfad-Existenz-Checks (Learned Rules) | missing_source_file Fehler reduziert |
| Inventory-first-Pattern (Superheld) | Stabile 82%+ Execution |
| Step-Verbosity-Fix im Planner | review_rejection-Rate sollte sinken |

**Limitierung:** Ohne neue codex-agent-system-Tasks kann die SR dort nicht weiter steigen. Die 82% wird aktuell nur durch Superheld getragen.

---

## 7. Hauptproblem: Cooldown-Deadlock (codex-agent-system)

### Diagnose
- `self-improve-automation-memory.json`: `external_sync_pending: true`, `source: none`, `automation_id: ""`
- `self-improve-superheld-cooldown`: Timestamp **1774958695** = 2026-03-31 14:04 CEST (ständig in die Zukunft geschrieben → Endlos-Cooldown)
- `self-improve-codex-agent-system-cooldown`: Wert `0` → kein Cooldown für dieses Projekt, aber die leere Queue + fehlende Task-Generierung = effektiver Deadlock
- Beide Queues (`queues/codex-agent-system.txt`, `queues/superheld.txt`) sind leer

### Paradox
Superheld-Tasks **laufen trotz Cooldown**, weil sie über den Orchestrator direkt aus der Projekt-Queue kommen, nicht über self-improve. Das codex-agent-system hat dagegen **keine Quelle für neue Tasks** mehr.

---

## 8. Empfohlene Modifikationen

### KRITISCH — Sofort

1. **Self-Improve-Automation-Memory reparieren**
   - `external_sync_pending` → `false`
   - `source` → `"internal"` (statt `"none"`)
   - `automation_id` → gültige ID setzen
   - **Ohne diesen Fix generiert self-improve keine neuen codex-agent-system Tasks**

2. **Cooldown-Logik debuggen**
   - Der Superheld-Cooldown wird mit Timestamps in der Zukunft beschrieben (aktuell +0s, aber Mechanismus schreibt immer "jetzt" → Cooldown wird nie abgebaut)
   - Fix: Cooldown-TTL auf max 2h begrenzen, danach automatischer Reset

3. **2 shelved Tasks als Canaries requeuen**
   - `task-002-test-context-clamp-4k` (Testing, Score 6.3)
   - `task-003-test-classify-retry-failure` (Testing, Score 6.3)
   - Beide scheiterten an Step-Verbosity-Bug, der inzwischen gefixt ist
   - Validiert ob die Pipeline nach Deadlock-Fix funktioniert

### WICHTIG — Kurzfristig

4. **Cooldown-Auto-Reset einführen**
   - Wenn Queue >4h leer und kein Task generiert → automatischer Cooldown-Reset
   - Verhindert erneuten Deadlock

5. **Task-Generator für codex-agent-system aktivieren**
   - Aktuell kommen alle neuen Tasks nur für Superheld
   - Self-improve sollte auch für codex-agent-system aus Failures + Metrics neue Tasks ableiten

### EMPFOHLEN — Mittelfristig

6. **Code-Quality-Kategorie verschärfen**
   - Schlechteste Kategorie: 11% SR (codex), 0% (claude)
   - Regel: 1 Task = 1 Datei + 1 konkrete Änderung + Pfad-Existenz-Check
   - Keine Tasks ohne konkreten Implementierungsplan

7. **Archiv kompaktieren**
   - 1103 Archiv-Tasks, davon 496 irrelevant (375 shelved + 121 rejected)
   - Cold-Archive würde Leseperformance verbessern

8. **Inventory-first-Pattern auch für codex-agent-system übernehmen**
   - Superheld zeigt 100% Erfolg mit "Inventory → Verify → Implement"
   - Dieses Pattern auf Code-Quality und Testing-Tasks für codex-agent-system anwenden

---

## 9. Fazit

Das System funktioniert — die **82% SR und 85% First-Pass-Rate** sind der Beweis. Die Superheld-Pipeline läuft stabil mit 4/4 Erfolgen heute. Das Kernproblem ist der **Self-Improve-Deadlock für codex-agent-system**: `external_sync_pending: true` bei `source: none` blockiert die Task-Generierung. Der Fix ist klar definiert (Automation-Memory reparieren + Cooldown-TTL einführen). Sobald dies umgesetzt ist, sollte die Pipeline mit der bewährten 82%+ SR weiterlaufen. Die beiden shelved Canary-Tasks sind der ideale erste Test nach dem Fix.
