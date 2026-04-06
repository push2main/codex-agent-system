# Fortschrittsbericht — 30. März 2026, v6 (Scheduled)

## Systemstatus: PARTIAL RECOVERY — Pipeline produziert wieder, aber Durchsatz extrem niedrig

Nach dem in v5 gemeldeten Deadlock zeigt das System erste Lebenszeichen. Am 29. März liefen 27 Tasks mit 41% Success Rate (11/27), am 30. März bisher 4 Tasks mit 50% (2/4). Die Queue ist allerdings wieder leer, was den nächsten Stillstand ankündigt.

---

## Kennzahlen im Vergleich

| Metrik | v5 (heute früher) | v6 (jetzt) | Trend |
|---|---|---|---|
| Gesamttasks (Log) | 618 | 618 | unverändert |
| Archiv (tasks-archive) | 1.103 | 1.103 | unverändert |
| Completed (Archiv) | 196 | 196 | stabil |
| All-time Success Rate | 15% | 15% | stagnierend |
| Recent-50 Success Rate | 26% | 26% | stabil |
| First-Pass Rate | 57% (4/7) | 57% (4/7) | unverändert |
| Timeout-Rate (global) | 34% | 34% | unverändert |
| Aktive Registry | 11 (4 done, 7 shelved) | 11 (4 done, 7 shelved) | **0 offene Tasks** |
| Queue | leer | **leer** | Pipeline-Starvation |
| Alerts | retry_churn, loop_effort | retry_churn, loop_effort | unverändert |

---

## Tages-Detailanalyse (letzte 7 Tage)

| Datum | Tasks | Success | Rate | Kommentar |
|---|---|---|---|---|
| 24. März | 165 | 21 | 13% | Hoher Durchsatz, niedrige Qualität |
| 25. März | 110 | 26 | 24% | System-Fixes greifen teilweise |
| 26. März | 4 | 0 | 0% | Pipeline fast tot |
| 27. März | 20 | 0 | 0% | Deadlock beginnt |
| 28. März | 41 | 0 | 0% | Deadlock voll aktiv |
| 29. März | 27 | 11 | **41%** | Erholung — beste Rate seit Beginn |
| 30. März | 4 | 2 | **50%** | Positiv, aber extrem wenige Tasks |

**Beobachtung:** Am 29. März sprang die Rate auf 41% — die höchste Tagesrate im gesamten Projektverlauf. Das zeigt, dass die Tasks, die durchkommen, jetzt besser zugeschnitten sind. Das Problem ist nicht mehr Qualität, sondern Quantität.

---

## Sind die bisherigen Tasks umsetzbar?

**Ja — die, die es bis zur Ausführung schaffen.**

Die 4 completed Tasks in der Registry (Kommentar in planner.sh, Dedup-Kommentar in learner.sh, Planner-Step-Test, Retry-Success-Improvement) folgen alle dem bewährten Muster: ein File, ein konkreter Anker, eine klare Erwartung. First-Pass-Rate dort: 57%.

Die 7 shelved Tasks sind korrekt archiviert — sie waren entweder zu abstrakt ("Inventory current decision path"), veraltete Signale (OpenAI v2.30.0), oder unscoped ("Reduce timeout rate" ohne konkreten Ansatzpunkt).

---

## Heben wir die Success Rate?

**Gemischt.** Globalrate stagniert bei 15%, aber die Trendwende am 29./30. März ist real:

- Window 601-618 (letzte 18 Tasks): **33% Success Rate** — die zweitbeste aller Windows
- 29. März standalone: **41%** — absolute Bestmarke
- Zero-Step-Timeouts seit 27. März: **0** (vorher hunderte)

Die gelernten Rules und System-Fixes (Zombie-Guard, Planning-Cap, Enriched-Retry-Text) zeigen Wirkung. Das System produziert bessere Tasks, wenn es Tasks produziert.

---

## Failure-Analyse (seit 27. März, 92 Tasks)

| Failure Kind | Anzahl | Anteil | Kommentar |
|---|---|---|---|
| review_rejection | 33 | 42% | Hauptproblem — Code wird geschrieben, aber Reviewer lehnt ab |
| timeout | 13 | 16% | Deutlich reduziert (von 34% global) |
| missing_source_file | 12 | 15% | Tasks referenzieren Dateien, die nicht existieren |
| empty_output | 8 | 10% | Agent produziert keinen Output |
| unknown_persistent | 7 | 9% | Nicht klassifizierbare Fehler |
| execution_failure | 4 | 5% | Runtime-Fehler |
| planning_failure | 2 | 3% | Planner scheitert |

**Top-3 Hebel:**
1. **review_rejection (42%)**: Der Coder schreibt Code, der Reviewer lehnt ab. Hier liegt das größte Verbesserungspotenzial — entweder durch bessere Task-Formulierung oder durch relaxierte Review-Kriterien für kleine Änderungen.
2. **missing_source_file (15%)**: Tasks referenzieren Dateien, die nicht existieren. Der Planner-Pre-Check (learned rule: "Reject plans that reference undeclared or nonexistent files") greift nicht zuverlässig.
3. **timeout (16%)**: Zwar reduziert, aber immer noch relevant. Zero-Step-Timeouts sind eliminiert, reguläre Timeouts bleiben.

---

## Root-Cause: Warum ist die Queue leer?

Der Deadlock-Zyklus aus v5 besteht fort:

1. **`external_control_plane_task` Gating**: Self-Improve-Analyzer findet Opportunities, blocked sie aber alle als "external control plane task". `blocked_analysis: 3, generated: 0, submitted: 0`.
2. **Keine manuelle Task-Einspeisung**: Ohne User-Interaktion kommen keine neuen Tasks in die Queue.
3. **Strategy-Engine inaktiv**: `strategy_saturation_detected: false`, aber die Engine generiert trotzdem nichts.

---

## Empfohlene Modifikationen

### 1. SOFORT: Deadlock brechen (manueller Eingriff)

Das `external_control_plane_task` Gating in der Self-Improve-Logik muss gelockert werden. Wenn alle 3 Opportunities geblockt werden, gibt es keine Arbeit. Entweder:
- Das Gating auf maximal 1 von 3 Opportunities begrenzen
- Einen Fallback einbauen, der bei 0 generierten Tasks automatisch die höchst-priorisierte Opportunity freigibt

### 2. KURZFRISTIG: Review-Rejection-Rate senken (42% der Failures)

Optionen:
- **Task-Shaping**: Vor Ausführung den erwarteten Diff-Umfang in die Task-Beschreibung aufnehmen, damit Coder und Reviewer die gleiche Erwartung haben
- **Review-Threshold**: Für Tasks mit effort=1 (kleine Änderungen) einen milderen Review-Standard anwenden
- **Pre-Validation**: Den Planner eine "expected changes" Sektion generieren lassen, die der Reviewer als Baseline nutzt

### 3. KURZFRISTIG: Missing-Source-File Guard verschärfen (15% der Failures)

Die learned rule existiert bereits, greift aber nicht. Mögliche Ursache: Der Pre-Check validiert nur deklarierte Files, nicht ob sie im Workspace tatsächlich existieren. Fix: `ls`/`stat`-Check vor Execution, nicht nur Pattern-Match im Plan-Text.

### 4. MITTELFRISTIG: Durchsatz erhöhen

Die aktuelle Rate von 4 Tasks/Tag ist zu niedrig. Das System braucht einen Mechanismus, der bei leerer Queue automatisch:
- Die top-3 Tasks aus dem Archiv mit status=failed und failure_kind != timeout reaktiviert
- Oder aus den 10 learned rules neue konkrete Tasks ableitet (eine Rule → ein Test-Task)

### 5. SYSTEM-CONFIG: Retry-Churn-Alert auflösen

`retry_churn_detected: true` und `loop_effort_detected: true` sind seit Tagen aktiv. Die 7 shelved Tasks in der Registry triggern diese Alerts vermutlich fälschlich. Nach dem Shelving sollten die Alert-Berechnungen die geshelved Tasks ausschließen.

---

## Fazit

Das System hat den Deadlock vom 26.–28. März teilweise überwunden und produziert jetzt qualitativ bessere Ergebnisse (41–50% Success Rate in den letzten 2 Tagen). Die Hauptprobleme sind:

1. **Quantität**: Die Queue ist leer, das System hungert nach Arbeit
2. **Review-Rejections**: 42% der Failures — der größte einzelne Hebel
3. **Gating**: Die Self-Improve-Engine blockt sich selbst

Die gelernten Rules funktionieren. Die System-Fixes (Zero-Step-Timeout-Elimination, Enriched-Retry-Classification) funktionieren. Was fehlt, ist der Task-Nachschub. Ohne manuellen Eingriff in das Gating wird die Pipeline innerhalb von Stunden wieder stillstehen.
