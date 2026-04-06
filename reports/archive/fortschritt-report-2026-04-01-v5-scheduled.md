# Fortschritt-Report — 2026-04-01 v5 (Scheduled)

## Zusammenfassung

Die Execution-Engine läuft auf exzellentem Niveau — der aktuell aktive Task (task-113, Dashboard Incident ID Smoke Verification) hat soeben alle 3 Steps erfolgreich abgeschlossen (Verify-Anchor → Implementation → Smoke-Run). Die Recent-Success-Rate liegt bei 92-95%. Das Kernproblem bleibt der **Pipeline-Deadlock (Tag 5+)**: Queues sind leer, Self-Improve generiert keine neuen Tasks, und die Automation-Memory ist uninitialisiert.

## Kernkennzahlen

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Total Tasks | 715 | Großes historisches Dataset |
| All-time SR | 24% | Historisch belastet (frühe Phase) |
| Recent-20 SR | **95%** | Exzellent |
| Letztes Window (701-715) | **93%** | Stabiles Plateau |
| First-Pass SR | 64% | Unter 80%-Ziel, verbesserbar |
| Timeout-Rate (recent) | **0%** | Gelöst |
| Registry | 195 KB (kein Pressure) | Gesund |
| Queues | **Alle leer (Tag 5+)** | KRITISCH |
| Aktive Alerts | 2 (retry_churn, loop_effort) | Altlast |

## Aktueller Task-Status

**Task-113** (Verify dashboard incident id field in smoke flow) ist der einzige laufende Task:

- Step 1/3 ✅ Verify-Anchor identifiziert (README Incident State Contract)
- Step 2/3 ✅ Fokussierte `incident_id`-Assertion in smoke.mjs eingefügt
- Step 3/3 ✅ Smoke-Run bestanden (`credential recovery routing smoke passed`, exit code 0)

Alle drei Steps: Coder → Review → Evaluation → **Approved**. Der Task sollte in Kürze als `completed` registriert werden.

Superheld-Projekt: 15/16 Tasks completed — das Projekt ist nahezu abgeschlossen.

## Historischer Trend — der Beweis, dass das System funktioniert

| Window | SR | Timeouts |
|--------|----|----------|
| 501-550 | 10% | 23 |
| 551-600 | 14% | 8 |
| 601-650 | 58% | 1 |
| 651-700 | 86% | 1 |
| 701-715 | **93%** | **0** |

+83 Prozentpunkte Verbesserung in den letzten ~200 Tasks. Die Learned Rules, Provider-Routing und Zombie-Guards greifen nachweislich.

## Sind die Tasks umsetzbar?

**Ja — alle aktiven Tasks werden erfolgreich umgesetzt.** Das Problem ist nicht die Umsetzbarkeit, sondern der **Nachschub**:

- Aktive Registry: 4 completed + 7 shelved + 1 running
- Keine pending/approved Tasks in der Pipeline
- Queues: 0 Bytes in beiden Queue-Dateien
- Self-Improve: Blockiert durch `cooldown_active` + leere Automation-Memory

## Pipeline-Deadlock — Analyse und empfohlene Modifikationen

### Ursache: Dreifacher Zirkelschluss (unverändert seit 28.03.)

1. **Automation-Memory leer** → `automation_id: ""`, `source: "none"`, `external_hydrated: false`
   - Self-Improve kann keinen Run starten ohne gültige Memory

2. **Cooldown-Gate blockiert** → `dominant_reason: "cooldown_active"` selbst bei 0 queued Tasks
   - Das Gate schützt vor Überproduktion, erkennt aber Unterproduktion nicht

3. **Queue-Starvation unerkannt** → `queue_starvation_detected: false` trotz 5+ Tagen Leere
   - Detection prüft vermutlich nur Momentaufnahme, nicht zeitliche Dauer

### Empfohlene System-Modifikationen

**PRIORITÄT 1 — Pipeline entsperren** (ohne dies sind alle anderen Verbesserungen blockiert):

1. **Automation-Memory initialisieren**: `self-improve-automation-memory.json` mit gültiger `automation_id` (UUID), `source: "manual_reset"`, `external_hydrated: true` befüllen

2. **Cooldown-Bypass bei leerer Queue**: Gating-Logik erweitern:
   ```
   if (queued_tasks === 0 && pending_tasks === 0 && approved_tasks === 0) → skip cooldown
   ```

3. **Queue-Starvation zeitbasiert erkennen**: Wenn Queue > 24h leer → `queue_starvation_detected: true` setzen und Recovery auslösen

**PRIORITÄT 2 — Alert-Hygiene nach Reset**:

- `retry_churn` und `loop_effort` Alerts zurücksetzen — beides Altlasten aus der frühen Phase
- 7 shelved Tasks evaluieren: Re-queue oder permanent archivieren

**PRIORITÄT 3 — First-Pass SR auf 80%+ steigern** (nach Pipeline-Reset):

- Hauptursache für Nicht-First-Pass: Tasks referenzieren nicht-existente Dateien
- Fix: Quelldatei-Validierung (`test -f <path>`) vor Task-Submission
- code_quality Kategorie besonders schwach — Provider-Routing bereits korrekt auf Codex

**PRIORITÄT 4 — Provider-Routing verschärfen**:

- Claude: 0% SR in auth, code_quality, project, learning (zusammen 26 Tasks, 0 Erfolge)
- Empfehlung: Claude nur noch für explizite UI-Screenshot-Tasks, alles andere → Codex
- Codex-Highlights: auth 72%, testing 57%, ui 28% — deutlich besser in allen Kategorien

## System-Health Ampel

| Komponente | Status |
|------------|--------|
| Execution Engine | 🟢 93% SR, 0 Timeouts |
| Retry Classification | 🟢 100% Coverage |
| Registry Pressure | 🟢 195 KB (< 512 KB) |
| Timeout Management | 🟢 Von 31% auf 0% |
| Learning System | 🟡 10 Rules, 199 Knowledge — stagnierend |
| Provider Routing | 🟡 Funktional, Claude zu breit eingesetzt |
| Pipeline/Queue | 🔴 Deadlock Tag 5+, alle Queues leer |
| Self-Improve | 🔴 Blockiert (Automation-Memory leer) |
| Starvation Detection | 🔴 Erkennt 5-Tage-Leere nicht |

## Fazit

**Das System hat seinen Nachweis erbracht:** Von 10% auf 93% Success Rate, Timeout-Problem gelöst, Retry-Classification auf 100%. Die Execution-Pipeline ist robust und liefert zuverlässig. Task-113 bestätigt dies erneut mit einem sauberen 3/3-Step-Durchlauf.

**Der einzige kritische Blocker ist die Pipeline-Versorgung.** Drei gezielte Eingriffe (Automation-Memory Reset, Cooldown-Bypass, Starvation-Detection) würden den Deadlock auflösen und den Weg frei machen für weitere Verbesserungen an First-Pass SR und Provider-Routing.

**Handlungsdruck: HOCH** — Das System steht bereit, aber wird nicht gefüttert.
