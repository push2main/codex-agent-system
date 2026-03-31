# Fortschrittsbericht — 30. März 2026, v8 (Scheduled)

## Systemstatus: PIPELINE STILLSTAND — Qualität auf Allzeit-Hoch, aber keine neuen Tasks

---

## Kennzahlen-Übersicht

| Metrik | Wert | Bewertung |
|---|---|---|
| Gesamt-Tasks | 618 | kein Zuwachs seit v7 |
| All-time Success Rate | 15% | stagnierend (historischer Ballast) |
| Recent-50 Success Rate | 26% | stabil |
| Letztes Window (601–618) | **33%** | **Allzeit-Best** |
| 29. März Tagesrate | **41%** (11/27) | bisheriges Tages-Maximum |
| First-Pass Rate | 57% (4/7 letzte) | solide |
| Timeout-Rate (global) | 34% | historisch belastet |
| Zero-Step-Timeouts (seit 27.3.) | **0** | ✅ eliminiert |
| Aktive Queue | **leer** | 🔴 kritisch |
| Offene Tasks in Registry | **0** | 🔴 Pipeline hungert |
| Aktive Alerts | 2 (retry_churn, loop_effort) | persistent, verrauscht |

---

## Sind die bisherigen Tasks umsetzbar?

**Ja.** Die Task-Qualität ist nachweislich die beste im gesamten Projektverlauf:

- Das aktuell aktive Regelset (`afdc1a2d`) erreicht **63.6% Success Rate** (7/11 Tasks) — mehr als doppelt so gut wie der Gesamtdurchschnitt.
- Die 5 gelernten Rules (undeclared-file-rejection, structured-data-isolation, discovery/implementation-split, one-file-one-anchor, standard-verification) greifen effektiv.
- Zero-Step-Timeouts sind seit dem 27.3. vollständig eliminiert — das Planning-Cap funktioniert.
- First-Pass-Rate bei 57% zeigt, dass Tasks beim ersten Versuch gelingen.

**Die Tasks selbst sind nicht das Problem — der fehlende Task-Nachschub ist es.**

---

## Heben wir die Success Rate?

**Lokal ja, global kaum.**

Die globale Rate (15%) ist durch 618 historische Tasks belastet und wird sich nur langsam bewegen. Die relevanten Metriken zeigen klaren Aufwärtstrend:

| Zeitraum | Success Rate | Trend |
|---|---|---|
| Gesamt (1–618) | 15% | stagnierend |
| Recent-50 | 26% | +12pp vs. Window 501–550 |
| Window 601–618 | 33% | **Allzeit-Best** |
| 29. März | 41% | **Tages-Best** |
| Best Ruleset (afdc1a2d) | 63.6% | exzellent |

Der non-timeout Verbesserungstrend ist positiv (+0.93pp pro 100 Tasks). Die Qualität verbessert sich — aber nur wenn Tasks fließen.

---

## Hauptprobleme — Priorisiert

### 🔴 1. KRITISCH: Pipeline Starvation (unverändert seit v7)

**Status:** Beide Queues (superheld.txt, codex-agent-system.txt) sind leer. 0 offene, 0 queued, 0 running Tasks.

**Root Cause:** Self-Improve-Engine findet 3 Opportunities, blockt aber alle als `external_control_plane_task`:
```
detected: 3, generated: 0, submitted: 0, blocked_analysis: 3
gating.dominant_reason: "external_control_plane_task"
```

Die Automation-Memory ist leer (`automation_id: "", source: "none"`), und `external_sync_pending: true` — die externe Synchronisation hängt.

**Empfohlene Modifikation:**
1. `external_control_plane_task`-Gating lockern: Wenn alle Candidates geblockt werden, mindestens 1 durchlassen (Fallback-Logik)
2. Alternativ: Manuelles Queue-Seeding mit 3–5 gut strukturierten Tasks als Kickstart
3. `external_sync_pending` auflösen — prüfen warum die Automation-Memory nicht hydrated wird

**Ohne diesen Fix bleibt die Pipeline dauerhaft still.**

### 🟡 2. HOCH: Review Rejection als dominanter Failure-Typ (42%)

42% der jüngsten Failures sind Review-Rejections. Coder und Reviewer haben unterschiedliche Erwartungen.

**Empfohlene Modifikation:**
- Task-Descriptions um "expected diff" Sektion erweitern
- Für effort=1 Tasks milderen Review-Standard
- Pre-Validation-Step vor Execution

### 🟡 3. MITTEL: Stale Alerts verrauschen Monitoring

`retry_churn` (high) und `loop_effort` (warning) sind seit Tagen aktiv, obwohl die auslösenden Tasks korrekt geshelved wurden (20 Zombie-Tasks, 7 davon geshelved).

**Empfohlene Modifikation:**
- Alert-Berechnung: Geshelved Tasks aus Churn-Metrik ausschließen
- Alert-Reset-Trigger wenn alle Churn-verursachenden Tasks geshelved sind

### 🟢 4. NIEDRIG: Provider-Routing Optimierungspotential

| Provider | Kategorie | Success Rate | Tasks |
|---|---|---|---|
| codex | auth | **50%** | 6 |
| claude | testing | **35.7%** | 14 |
| codex | general | **21.2%** | 132 |
| claude | general | 18.5% | 54 |
| codex | ui | 9.5% | 148 |
| claude | learning | 8.3% | 12 |
| codex | learning | 6.5% | 31 |

**Empfohlene Modifikation:**
- `ui`-Tasks an `claude` routen (14.9% vs. codex 9.5% — signifikant besser)
- `auth`-Tasks weiter an `codex` (50% vs. claude 0%)
- `learning`-Tasks: beide Provider schlecht, Task-Design überdenken

---

## Konfigurationsempfehlungen (Zusammenfassung)

| # | Maßnahme | Aufwand | Impact | Status |
|---|---|---|---|---|
| 1 | `external_control_plane_task` Gating lockern | niedrig | **kritisch** | ⚠️ BLOCKIEREND |
| 2 | Automation-Memory / external_sync reparieren | niedrig | kritisch | ⚠️ BLOCKIEREND |
| 3 | Review-Threshold für effort=1 senken | mittel | hoch | empfohlen |
| 4 | Alert-Logic: shelved Tasks ausschließen | niedrig | mittel | empfohlen |
| 5 | UI-Tasks an claude Provider routen | niedrig | mittel | empfohlen |
| 6 | Manuelles Queue-Seeding als Notfallmaßnahme | niedrig | hoch | optional |

---

## Fazit

Das System befindet sich in einem paradoxen Zustand: **Die Qualität der Task-Ausführung ist so hoch wie nie** (33–63% Success Rate je nach Messwindow), aber **die Pipeline produziert keine neuen Tasks mehr**. Die gelernten Rules, das Planning-Cap und die Zombie-Guard funktionieren nachweislich.

Der **einzige kritische Blocker** bleibt das `external_control_plane_task`-Gating in der Self-Improve-Engine, das seit mindestens v7 alle neuen Opportunities blockt. Ohne Eingriff hier (entweder Gating-Logik lockern oder manuelles Queue-Seeding) wird das System weiter stillstehen.

**Prognose bei Behebung des Pipeline-Deadlocks:** Nachhaltige Success Rate von 35–45% ist realistisch, basierend auf dem aktuellen Ruleset-Performance (63.6%) und den jüngsten Tagesraten (41–50%).

**Prognose ohne Eingriff:** Das System bleibt auf 0 aktiven Tasks stehen. Keine Verschlechterung, aber auch kein Fortschritt.
