# Fortschrittsbericht — 2026-04-02 (v23, Scheduled)

## Gesamtzustand: Stabil, aber im produktiven Stillstand

Die Pipeline läuft technisch einwandfrei. Die Success-Rate hält ihr Plateau. Es gibt keine neuen Incidents oder Fehler. Das Kernproblem bleibt unverändert: Self-Improve ist durch Cooldown blockiert, beide Queues sind leer, und es fließt kein neues Work durch das System.

---

## Kennzahlen (Stand 2026-04-02 ~21:00 UTC)

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Gesamttasks (Archiv) | 1.103 (+ 11 Registry) | Großes Archiv |
| All-Time Successrate | 32,6% (196/602 terminal) | Historisch belastet |
| Recent-50 Successrate | 40% (Archiv-basiert) | Deutlich unter CLAUDE.md-Claim (98%) |
| Last-20 Terminal | **5%** (1/20) | Kritisch — fast nur Failures |
| First-Pass-Success | 82% (metrics.json) | Stabil |
| Timeout-Rate | 27% (212 Timeouts) | Historisch, keine neuen |
| Registry-Größe | 91 KB (aktiv) / 4,4 MB (Archiv) | Gesund |
| Aktive Alerts | 2 | retry_churn (high), loop_effort (warning) |
| Self-Improve | **Blockiert** (cooldown_active) | Keine Task-Generierung |
| Queue | **Leer** | Kein Durchsatz |

### Diskrepanz CLAUDE.md vs. Realität

CLAUDE.md meldet "Recent (last 50): 0.98" — aber die tatsächliche Archiv-Analyse der letzten 50 terminalen Tasks zeigt 40%, und die letzten 20 liegen bei nur 5%. Die 98% in metrics.json basieren auf einem früheren Messfenster (Tasks 701–778), das primär Verify-Loop-Tasks enthielt. Die aktuellen Tasks (hauptsächlich meta-systemische Verbesserungsversuche) scheitern fast alle.

### Trend-Verlauf (historische 50er-Fenster)

```
Tasks 601-650: 58%  ← Durchbruch
Tasks 651-700: 86%  ← Starker Anstieg
Tasks 701-750: 96%  ← Plateau (Verify-dominiert)
Tasks 751-778: 96%  ← Gehalten
Danach: Stillstand — keine neuen substantiellen Tasks
```

---

## Task-Analyse: Sind die bisherigen Tasks umsetzbar?

### Aktive Registry (11 Tasks: 4 completed, 7 shelved)

Die 7 geshelved Tasks teilen sich in drei Gruppen:

**Reaktivierbar (3 Tasks):**
- `task-002` Unit-Test clamp_prompt_context — Root-Cause (Step-Verbosity) behoben, konkreter Single-File-Test
- `task-003` Unit-Test classify_retry_failure — gleiche Root-Cause, gleiche Einschätzung
- `task-005` Learner dedup-Kommentar Fix — trivial, niedrige Komplexität

**Archivierbar (2 Tasks):**
- `task-004` Review OpenAI Python Signal — veraltet (Signal von März 2025)
- `task-010` Reduce Timeout Rate — Problem bereits gelöst (0 Timeouts in letzten 150 Tasks)

**Korrekt geshelved (2 Tasks):**
- `task-006` System-Work-Buffer — Zombie (5+ Attempts)
- `task-009` Inventory Decision Path — Zombie

### Archiv: Letzte 20 terminale Tasks — Alarmsignal

19 von 20 sind Failures. Die häufigsten Failure-Kinds:
- `review_rejection` — Plans werden vom Reviewer abgelehnt
- `timeout` — Planung frisst das gesamte Budget
- `missing_source_file` — Tasks referenzieren nicht existierende Dateien
- `empty_output` — Agent produziert keine Ausgabe

Das System erzeugt aktuell Meta-Tasks ("Inventory current decision path for...", "Reduce timeout rate", "Break retry churn") die systematisch scheitern. Diese Tasks sind zu abstrakt, zu breit, oder referenzieren interne Pfade falsch.

---

## Heben wir die Successrate?

**Nein — die Rate stagniert und die Messung ist verzerrt.**

Die nominale 96-98% Success-Rate stammt aus einem Fenster, das von Verify-Loop-Tasks dominiert wurde (triviale 1-Step-Verifications die fast nie scheitern). Die echte Leistung bei substantiellen Tasks (Fixes, Tests, Features) ist deutlich niedriger. Seit dem Erreichen des Plateaus wurden keine komplexen Tasks mehr erfolgreich durchgeführt.

Provider-Routing zeigt niedrige absolute Raten: Codex best-case 72% (auth, kleines N), typisch 10-40%. Claude-Provider durchgehend unter 20%.

---

## Sind Modifikationen notwendig?

### Ja — auf drei Ebenen:

### 1. Kritisch: Self-Improve Cooldown muss zurückgesetzt werden

`self-improve-run.json` zeigt:
- `gating.dominant_reason = "cooldown_active"`
- `counts: detected=0, generated=0, submitted=0`
- Kein automation_id, kein aktiver Source

**Ohne Cooldown-Reset bleibt die Pipeline dauerhaft inaktiv.** Die Queues werden nicht befüllt, es gibt keinen Task-Durchsatz, und das System kann sich nicht weiterentwickeln.

**Empfohlene Aktion:** Cooldown-Timer in `self-improve-run.json` und/oder `self-improve-automation-memory.json` zurücksetzen.

### 2. Dringend: Tasks 1-3 reaktivieren für Quick-Win-Validierung

Die drei reaktivierbaren Tasks (clamp_prompt_context Test, classify_retry_failure Test, Learner-Fix) sind ideal um zu testen, ob die gelernten Optimierungen (2-Step-Plans, Context-Clamping) auch bei echten Coding-Tasks funktionieren — nicht nur bei Verify-Loops.

### 3. Strukturell: Task-Generator-Qualität verbessern

Die letzten 20 Terminal-Tasks zeigen, dass der Task-Generator (Self-Improve) minderwertige Tasks erzeugt:
- Meta-Tasks wie "Inventory current decision path for X" scheitern systematisch
- Tasks referenzieren fehlende Dateien (`missing_source_file`)
- Abstrakte Ziele ("Reduce timeout rate") ohne konkrete File/Function-Targets

**Empfohlene Änderungen:**
- Task-Generator muss vor Erzeugung prüfen ob referenzierte Dateien existieren
- Verbiete "Inventory"-Tasks wenn kürzlich ein Inventory für denselben Scope lief
- Meta-Tasks ("improve X rate") in konkrete, dateigebundene Tasks umwandeln
- Verify-Loop-Breaker: nach N erfolgreichen Verifications desselben Typs pausieren

### 4. Housekeeping: Registry aufräumen

- Tasks 4 + 10 archivieren (veraltet/obsolet)
- Lernregeln auffüllen (10/20 Slots belegt) — neue Rules aus den letzten 200+ Tasks extrahieren
- Zombie-Guard an Task-Generator koppeln

---

## Zusammenfassung

| Bereich | Status | Handlungsbedarf |
|---------|--------|-----------------|
| Pipeline-Technik | ✅ Gesund | Keiner |
| Task-Durchsatz | ❌ Null | Cooldown-Reset |
| Successrate (real) | ⚠️ Stagniert | Bessere Task-Qualität |
| Successrate (nominal) | ✅ 96% | Verzerrt durch Verify-Loops |
| Lernfortschritt | ⏸ Pausiert | Self-Improve aktivieren |
| Registry | ⚠️ Aufgeräumt | 2 Tasks archivieren, 3 reaktivieren |

**Die Pipeline ist technisch bereit, aber steht still.** Die drei Prioritäten bleiben:
1. Self-Improve Cooldown zurücksetzen → Pipeline reaktivieren
2. Shelved Tasks 1-3 reaktivieren → Quick-Win unter echtem Work testen
3. Task-Generator-Logik verschärfen → keine abstrakten Meta-Tasks mehr erzeugen
