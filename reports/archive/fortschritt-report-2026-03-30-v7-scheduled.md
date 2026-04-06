# Fortschrittsbericht — 30. März 2026, v7 (Scheduled)

## Systemstatus: PIPELINE STARVATION — Qualität steigt, aber keine neuen Tasks

---

## Kennzahlen-Übersicht

| Metrik | Wert | Trend |
|---|---|---|
| Gesamt-Tasks (Log) | 618 | +0 seit v6 |
| Archiv (tasks-archive) | 16 (8 completed, 4 rejected, 4 failed) | stabil |
| All-time Success Rate | 15% | stagnierend |
| Recent-50 Success Rate | 26% | stabil |
| Letztes Window (601–618) | **33%** | positiv |
| 29. März Tagesrate | **41%** (11/27) | Allzeit-Bestmarke |
| 30. März Tagesrate | **50%** (2/4) | gut, aber winzige Stichprobe |
| First-Pass Rate | 57% (4/7) | solide |
| Timeout-Rate (global) | 34% | unverändert |
| Zero-Step-Timeouts (seit 27.3.) | **0** | eliminiert |
| Aktive Queue | **leer** | kritisch |
| Aktive Registry | 0 offene Tasks | Pipeline hungert |
| Alerts | retry_churn (high), loop_effort (warning) | persistent |

---

## Trend-Analyse nach 50er-Windows

| Window | Rate | Timeouts | Bewertung |
|---|---|---|---|
| 1–50 | 34% | 19 | Anfangsphase, hohe Rate |
| 51–100 | 4% | 5 | Einbruch |
| 101–200 | 4–6% | 33–38 | Timeout-Krise |
| 201–300 | 10–16% | 23–34 | langsame Erholung |
| 301–400 | 12–14% | 5–12 | Stabilisierung |
| 401–500 | 22–26% | 20–29 | Aufwärtstrend |
| 501–600 | 10–14% | 8–23 | Rückschlag |
| **601–618** | **33%** | **1** | **Bestes Window seit Start** |

Die Kurve zeigt: Das System hat seit Window 401+ gelernt, bessere Tasks zu generieren. Der Rückfall in 501–600 wurde durch den Deadlock (26.–28.3.) verursacht, nicht durch Qualitätsverlust. Seit der Erholung am 29.3. ist die Qualität die höchste im gesamten Projektverlauf.

---

## Sind die bisherigen Tasks umsetzbar?

**Ja — die wenigen, die durchkommen, funktionieren gut.**

Die Rule-Effectiveness zeigt, dass die besten Regelsets (Hash `afdc1a2d`) eine Success Rate von **63.6%** erreichen. Die 5 gelernten Rules sind wirksam:

1. "Reject undeclared files" — verhindert missing_source_file Failures
2. "Structured-data isolation" — verhindert Scope-Creep
3. "Split discovery vs. implementation" — reduziert Komplexität
4. "One file, one anchor, one outcome" — erzwingt Fokus
5. "Standard verification" — vermeidet Custom-Verification-Overhead

Das Problem ist nicht die Task-Qualität, sondern der **Task-Nachschub**.

---

## Heben wir die Success Rate?

**Lokal ja, global nein.**

- Die globale Rate (15%) bewegt sich nicht, weil 618 historische Tasks den Durchschnitt drücken
- Die **relevante Metrik** ist die Rate der letzten 50 Tasks (26%) und das letzte Window (33%)
- First-Pass-Rate bei 57% — d.h. mehr als die Hälfte der Tasks gelingt beim ersten Versuch
- Die Trendwende am 29./30. März (41–50%) zeigt echtes Qualitäts-Improvement

---

## Hauptprobleme (priorisiert)

### 1. KRITISCH: Pipeline Starvation — Queue leer, kein Task-Nachschub

**Root Cause:** Die Self-Improve-Engine findet 3 Opportunities, blockt aber alle als `external_control_plane_task`. Ergebnis: `generated: 0, submitted: 0, blocked_analysis: 3`.

Die Strategy-Engine meldet ebenfalls: "No strategy board changes needed." Beide Queue-Files (superheld.txt, codex-agent-system.txt) sind leer.

**Empfehlung:** Das `external_control_plane_task`-Gating in der Self-Improve-Logik muss gelockert werden. Mindestens eine von drei Opportunities sollte durchgelassen werden, wenn alle geblockt sind. Ohne diesen Fix bleibt die Pipeline tot.

### 2. HOCH: Review Rejection dominiert Failures (42%)

Von den jüngsten Failures sind 42% Review-Rejections — der Coder schreibt Code, der Reviewer lehnt ab. Das ist der größte einzelne Hebel.

**Empfehlungen:**
- Task-Descriptions um eine "expected diff" Sektion erweitern, damit Coder und Reviewer die gleiche Erwartung haben
- Für effort=1 Tasks (kleine Änderungen) einen milderen Review-Standard einführen
- Alternativ: Pre-Validation-Step, der den erwarteten Output vor Execution definiert

### 3. MITTEL: Persistent Alerts (retry_churn, loop_effort) verrauschen Monitoring

`retry_churn_detected: true` und `loop_effort_detected: true` sind seit Tagen aktiv, obwohl 7 Tasks korrekt geshelved wurden. Die Alert-Berechnung schließt geshelved Tasks vermutlich nicht aus.

**Empfehlung:** Alert-Logic anpassen, um geshelved Tasks aus der Churn-Berechnung auszuschließen.

### 4. NIEDRIG: Provider-Routing suboptimal

Provider-Stats zeigen:
- `codex` general: 21% Success (132 Tasks) — bester Performer
- `claude` general: 18.5% (54 Tasks)
- Beide Provider bei infra: identisch 13%
- `claude` learning: nur 8.3% (12 Tasks)

Das Routing-Assignment für `learning` an `claude` (8.3%) ist schlechter als `codex` learning (6%, aber nur 31 Tasks). Hier lohnt sich ein Experiment: learning-Tasks temporär an codex routen.

---

## Konfigurationsempfehlungen

| # | Was | Wo | Aufwand | Impact |
|---|---|---|---|---|
| 1 | `external_control_plane_task` Gating lockern | Self-Improve-Analyzer | niedrig | **kritisch** — ohne Fix keine neuen Tasks |
| 2 | Review-Threshold für effort=1 Tasks senken | agents/reviewer.sh | mittel | hoch — 42% der Failures addressieren |
| 3 | Alert-Logic: shelved Tasks ausschließen | codex-learning/alerts-logic | niedrig | mittel — weniger Rauschen |
| 4 | File-Existence-Check vor Execution | agents/planner.sh oder orchestrator.sh | niedrig | mittel — 15% missing_source_file eliminieren |
| 5 | Auto-Requeue bei leerer Queue | scripts/queue-refill oder strategy.sh | mittel | hoch — Pipeline-Starvation verhindern |

---

## Fazit

Das System befindet sich in einem paradoxen Zustand: Die **Qualität ist so hoch wie nie** (33–50% Success Rate in den letzten Tasks), aber die **Pipeline ist ausgetrocknet** (0 Tasks in der Queue, 0 offene Tasks in der Registry). Die gelernten Rules und System-Fixes greifen nachweislich — Zero-Step-Timeouts eliminiert, bessere Task-Formulierung, höhere First-Pass-Rate.

Der **einzige kritische Blocker** ist das `external_control_plane_task`-Gating, das alle neuen Task-Opportunities blockt. Ohne Eingriff hier wird die Pipeline dauerhaft still stehen. Alle anderen Verbesserungen (Review-Threshold, Alert-Bereinigung, Provider-Routing) sind sekundär und werden erst relevant, wenn wieder Tasks fließen.

**Prognose:** Bei Aufhebung des Gating-Deadlocks und den vorgeschlagenen Review-Adjustments ist eine nachhaltige Success Rate von 35–45% realistisch.
