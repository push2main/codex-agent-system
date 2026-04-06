# Fortschrittsbericht — 30. März 2026 (Scheduled, v3)

## Systemstatus: DEADLOCK — Pipeline seit ~5 Tagen ohne produktiven Output

Die Kerndiagnose aus dem v2-Report bestätigt sich vollständig. Das System läuft, aber dreht leer.

---

## Aktuelle Lage im Überblick

| Metrik | Wert | Bewertung |
|---|---|---|
| Gesamttasks (Archiv) | 1.103 | — |
| Davon completed/done | 200 (18,1%) | niedrig |
| Davon failed | 406 (36,8%) | hoch |
| Davon shelved | 375 (34,0%) | viel Waste |
| Davon rejected | 121 (11,0%) | — |
| **All-time Success Rate** | **15%** (metrics.json) | stagnierend |
| **Recent Success Rate (letzte 20)** | **30%** | leichte Besserung |
| First-Pass Success Rate | 57% | akzeptabel, aber auf kleiner Basis (4 von 7) |
| Timeout-Rate | 34% | problematisch |
| Lokale Registry | 11 Tasks: 4 completed, 7 shelved | **keine offenen Tasks** |
| Queue | **leer** (0 Bytes beide Dateien) | Pipeline-Starvation |
| Registry-Druck | 91 KB lokal / 160 KB gesamt | gesund (<512 KB) |
| Aktive Alerts | retry_churn (high), loop_effort (warning) | 2 aktive Warnungen |
| `claude print failed` | **2.029x** (steigend von 1.954) | Provider-Dauerfehler |

---

## Sind die bisherigen Tasks umsetzbar?

### Was funktioniert hat (4 completed Tasks)

Die 4 erfolgreich abgeschlossenen Tasks zeigen ein klares Muster:

- **task-006**: Kommentar in planner.sh → Erfolg nach 3 Versuchen
- **task-007**: Unit-Test für Step-Längenlimit → Erfolg nach 3 Versuchen
- **task-008**: Kommentar-Update in learner.sh → Erfolg nach 3 Versuchen
- **task-011**: Retry-Rate verbessern → Erfolg beim 1. Versuch

**Erfolgsmuster**: Eng fokussierte, einzelne Datei-Änderungen (Kommentare, einfache Tests, isolierte Config-Anpassungen).

### Was nie funktioniert hat (aus Archiv-Analyse)

Kategorien mit 0% oder nahe-0% Success Rate über 50+ Versuche:

- ux (0/52), security (0/24), architecture (0/12), auth (0/8 via claude-Provider)
- performance (0/2 lokal), documentation (0/4), localization (0/4)
- self-improve Meta-Tasks (rules_hash 9f968207: 0/5, d5bbcbcd: 0/4)

### Superheld-Projekt: Aktiver aber fehlerhafter Run

Der letzte Run (20260330-020454) zeigt einen laufenden Task im superheld-Projekt. Step 1 scheiterte beim ersten Versuch (evaluator=fail, score=0) und wurde retried. Der codex-Provider funktioniert grundsätzlich — das Problem liegt beim claude-Provider.

---

## Heben wir die Success Rate?

### Trend-Analyse (50er-Fenster)

| Fenster | Success Rate | Timeouts |
|---|---|---|
| 1–50 | 34% | 19 |
| 51–100 | 4% | 5 |
| 101–150 | 6% | 33 |
| 151–200 | 4% | 38 |
| 201–250 | 16% | 34 |
| 251–300 | 10% | 23 |
| 301–350 | 14% | 5 |
| 351–400 | 12% | 12 |
| 401–450 | 22% | 29 |
| 451–500 | 26% | 20 |
| 501–550 | 10% | 23 |
| 551–600 | 14% | 8 |
| 601–616 | 31% | 1 |

**Bewertung**: Es gibt keinen konsistenten Aufwärtstrend. Die Rate schwankt zwischen 4% und 34%. Das letzte Fenster (601–616, 16 Tasks) zeigt 31%, aber bei so kleiner Stichprobe ist das nicht belastbar. Über alle 616 Tasks ist der Trend laut CLAUDE.md "NOT IMPROVING (-1.7pp)".

### Rule-Effectiveness zeigt gemischtes Bild

Der beste Rule-Set (afdc1a2d) erreichte 63,6% Success Rate bei 11 Tasks. Der aktuelle Rule-Set liefert solide 50% bei 12 Tasks. Aber: Die Self-Improve Meta-Tasks (die das System verbessern sollen) haben 0% — das System kann sich nicht selbst optimieren.

---

## Retry-Failure-Analyse

| Klassifikation | Anzahl | Anteil |
|---|---|---|
| review_rejection | 54 | 41,5% |
| timeout | 39 | 30,0% |
| step_not_completed | 18 | 13,8% |
| missing_environment | 12 | 9,2% |
| test_failure | 2 | 1,5% |
| Sonstige | 5 | 3,8% |

**Hauptproblem**: 41,5% der Retries scheitern an Reviewer-Rejections — der Reviewer ist zu streng oder die Tasks zu vage formuliert. 30% sind Timeouts (Planner verbraucht zu viel Budget).

---

## Diagnose: Warum steht das System?

### 1. Claude-Provider defekt (KRITISCH)

`claude print failed` tritt jetzt 2.029x auf (v2-Report: 1.954x). Der Self-Improve-Analyzer nutzt den claude-Provider und scheitert bei Zeile 6929 mit exit code 1. Ohne funktionierenden claude-Provider kann keine automatische Task-Generierung stattfinden.

### 2. Self-Improve-Loop dreht leer

Der Loop erkennt "improving=true delta=0.158" (aufgrund der letzten completed Tasks), generiert aber 0 Improvement-Tasks. Grund: `blocked_analysis: 3` — alle 3 erkannten Improvement-Opportunities werden durch `external_control_plane_task` blockiert.

### 3. Strategy-Loop ohne Wirkung

Die Strategy meldet "No strategy board changes were needed" und der Queue-Gate blockiert: `success_rate=0.22, retry_churn=true, loop_effort=true`. Das System schützt sich selbst vor neuen Tasks, weil die bestehenden Metriken schlecht sind — ein Teufelskreis.

### 4. Queue-Starvation → Keine Arbeit

Beide Queue-Dateien sind 0 Bytes. Ohne Tasks in der Queue passiert nichts, und ohne funktionierenden Analyzer kommen keine neuen Tasks.

---

## Empfohlene Modifikationen

### Sofortmaßnahmen (manuell erforderlich)

1. **Claude-Provider diagnostizieren und reparieren** — Der `claude print failed`-Error muss gelöst werden. Prüfen: Ist das API-Token gültig? Ist die CLI-Version aktuell? Ggf. `claude` CLI neu installieren oder Token erneuern.

2. **Self-Improve Provider-Routing auf codex umstellen** — In `codex-learning/provider-routing.json` den Self-Improve-Analyzer vom claude- auf den codex-Provider umstellen, damit die Task-Generierung wieder funktioniert.

3. **3–5 einfache Tasks manuell in die Queue legen** — Fokus auf bewährte Kategorien:
   - code_quality: Kommentare, kleine Refactors (historisch beste Rate)
   - testing: Einfache Unit-Tests für bestehende Funktionen
   - stability: Eng gefasste Guard-Verbesserungen

4. **Gating-Blockade `external_control_plane_task` auflösen** — Der Self-Improve-Loop hat 3 erkannte Improvements, die alle durch diese Blockade nicht submitted werden. Diese Sperre muss verstanden und ggf. aufgehoben werden.

### Strukturelle Verbesserungen

5. **Priority-Kalibrierung auf beobachtete Raten zurücksetzen** — priority.json überschätzt die Erfolgsraten systematisch (z.B. stability: predicted 76% vs. observed 33%).

6. **Reviewer-Strictness kalibrieren** — 41,5% der Retries sind Reviewer-Rejections. Entweder die Review-Kriterien lockern oder die Task-Formulierungen präziser machen.

7. **Kategorien mit 0% Success Rate dauerhaft blockieren** — ux, security, architecture, auth (via claude), documentation, localization sollten nicht mehr als Tasks generiert werden.

8. **Planning-Budget-Cap durchsetzen** — 227 Zero-Step-Timeouts bedeuten, dass der Planner oft die gesamte Ausführungszeit verbraucht. Das 60s-Cap aus CLAUDE.md muss aktiv durchgesetzt werden.

---

## Zusammenfassung

| Frage | Antwort |
|---|---|
| Aktueller Fortschritt? | **Stillstand** — Pipeline idle seit ~5 Tagen, nur superheld-Projekt hat sporadische Runs |
| Tasks umsetzbar? | **Nur eng fokussierte** — code_quality/testing funktionieren; systemweite/abstrakte Tasks scheitern systematisch |
| Success Rate steigend? | **Nein** — kein konsistenter Trend, schwankt zwischen 4–34%, Gesamtrate bei 15% |
| Modifikationen nötig? | **Ja, dringend** — Provider reparieren, Gating-Blockade lösen, manuell Tasks einspeisen |

**Prognose**: Ohne manuellen Eingriff wird sich an der Situation nichts ändern. Das System hat sich in einen stabilen Deadlock manövriert — es generiert keine Tasks, weil der Provider defekt ist und die Gating-Logik weitere Generierung blockiert. Die gelernten Rules funktionieren (50–63% bei geeigneten Tasks), aber es kommen keine passenden Tasks mehr nach.
