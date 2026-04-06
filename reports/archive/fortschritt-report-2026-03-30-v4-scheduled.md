# Fortschrittsbericht — 30. März 2026, v4 (Scheduled)

## Systemstatus: DEADLOCK — Pipeline steht seit ~5 Tagen

Die Diagnose aus den vorherigen Reports (v2, v3) bestätigt sich weiterhin vollständig. Seit dem letzten manuellen Eingriff hat sich der Zustand nicht verändert. Das System läuft technisch, produziert aber keinen produktiven Output.

---

## Kennzahlen-Übersicht

| Metrik | Wert | Trend |
|---|---|---|
| Gesamttasks (Archiv) | 1.103 | stabil |
| Completed/Done | 200 (18,1%) | keine Veränderung |
| Failed | 406 (36,8%) | keine Veränderung |
| Shelved | 375 (34,0%) | keine Veränderung |
| All-time Success Rate | 15% | stagnierend |
| Recent 50 Success Rate | 26% | leicht besser als Schnitt |
| First-Pass Success Rate | 57% (4/7) | kleine Basis |
| Timeout-Rate | 34% (global), 45% (superheld) | problematisch |
| Aktive Registry | 11 Tasks: 4 completed, 7 shelved | **0 offene Tasks** |
| Queue | **leer** (0 Bytes) | Pipeline-Starvation |
| Aktive Alerts | retry_churn (high), loop_effort (warning) | unverändert |

---

## Sind die bisherigen Tasks umsetzbar?

### Ja — aber nur eng fokussierte Tasks

Die 4 erfolgreich abgeschlossenen Tasks zeigen ein klares Erfolgsmuster:

- Kommentar in planner.sh hinzufügen → Erfolg nach 3 Versuchen
- Unit-Test für Step-Längenlimit → Erfolg nach 3 Versuchen
- Kommentar-Update in learner.sh → Erfolg nach 3 Versuchen
- Retry-Rate verbessern → Erfolg beim 1. Versuch

**Erfolgsfaktoren**: Ein File, ein konkreter Anker, ein klarer erwarteter Outcome. Genau das, was die gelernten Rules vorschreiben.

### Was systematisch scheitert

Kategorien mit ~0% Success Rate über dutzende Versuche: ux (0/52), security (0/24), architecture (0/12), auth via claude (0/8), documentation (0/4), localization (0/4). Auch self-improve Meta-Tasks scheitern zu 100% (rules_hash 9f968207: 0/5).

### Die letzten 15 archivierten Tasks

Ein besorgniserregendes Muster: 6× identischer "Inventory current decision path for recover stale pipeline" Task — shelved. Das System generiert repetitive, abstrakte Inventory-Tasks, die keine konkrete Wirkung haben.

---

## Heben wir die Success Rate?

**Nein.** Kein konsistenter Aufwärtstrend über die 12 Fenster à 50 Tasks. Schwankung zwischen 4% und 34%. Der CLAUDE.md-Trend zeigt -1.0pp zwischen erster und zweiter Hälfte. Die Rule-Sets zeigen gemischte Wirkung:

| Rule-Set | Tasks | Success Rate |
|---|---|---|
| afdc1a2d (bester) | 11 | 63,6% |
| 422daf81 (aktuell) | 12 | 50,0% |
| aeb35f3c | 7 | 28,6% |
| 9f968207 (self-improve) | 5 | 0,0% |

Die Rules selbst funktionieren für geeignete Tasks. Das Problem ist nicht die Regelqualität, sondern dass keine neuen passenden Tasks generiert werden.

---

## Root Causes des Deadlocks

### 1. Claude-Provider defekt (KRITISCH)
`claude print failed` tritt 2.029× auf (steigend). Der Self-Improve-Analyzer braucht den claude-Provider und scheitert durchgehend. Ohne ihn: keine automatische Task-Generierung.

### 2. Gating-Blockade `external_control_plane_task`
Der Self-Improve-Loop erkennt 3 Improvement-Opportunities, blocked alle 3 mit `external_control_plane_task`. Das System wartet auf externen Input, der nicht kommt.

### 3. Queue-Starvation → Teufelskreis
Queue leer → keine Arbeit → keine neuen Metriken → Gating blockiert weiter → Queue bleibt leer. Das System schützt sich vor neuen Tasks, weil die Metriken schlecht sind.

### 4. Retry-Failure-Verteilung
41,5% der Retries scheitern an Reviewer-Rejections (zu strenger Reviewer oder zu vage Tasks). 30% sind Timeouts (Planner verbraucht zu viel Budget). 90% der Timeouts im superheld-Projekt sind Zero-Step-Timeouts.

---

## Empfohlene Modifikationen

### Priorität 1: Deadlock brechen (manuell)

1. **Claude-Provider reparieren** — `claude print failed` diagnostizieren. API-Token prüfen, CLI-Version aktualisieren, oder den Self-Improve-Analyzer auf den codex-Provider umrouten in `codex-learning/provider-routing.json`.

2. **Gating-Blockade `external_control_plane_task` aufheben** — In `codex-learning/self-improve-run.json` oder den entsprechenden Gating-Code die Blockade entfernen oder umkonfigurieren, damit die 3 erkannten Improvements submitted werden können.

3. **3–5 einfache Tasks manuell in die Queue einspeisen** — Bewährte Typen:
   - code_quality: Kommentare, kleine Refactors
   - testing: Einfache Unit-Tests
   - stability: Eng gefasste Guards

### Priorität 2: Strukturelle Verbesserungen

4. **Kategorien mit 0% dauerhaft blacklisten** — ux, security, architecture, auth (claude), documentation, localization aus der Task-Generierung ausschließen. Diese verbrennen nur Budget.

5. **Reviewer-Strictness kalibrieren** — 41,5% Reviewer-Rejections sind zu hoch. Entweder Reviewer-Kriterien lockern oder Task-Formulierungen enger fassen.

6. **Planning-Budget-Cap durchsetzen** — 227 Zero-Step-Timeouts und 90% Zero-Step-Rate im superheld-Projekt. Das 60s-Planning-Cap aus CLAUDE.md muss aktiv enforced werden.

7. **Repetitive Task-Generierung unterbinden** — Der 6× wiederholte "Inventory current decision path" Task zeigt, dass der Titel-Dedup nicht greift. Family-Filter verschärfen.

### Priorität 3: Optimierungen

8. **Besten Rule-Set (afdc1a2d, 63,6%) reaktivieren** — Der aktuelle Rule-Set (422daf81, 50%) ist gut, aber afdc1a2d war besser. Prüfen, ob eine Rückkehr möglich ist.

9. **Priority-Kalibrierung** — priority.json überschätzt Success-Rates systematisch. Auf beobachtete Raten zurücksetzen.

---

## Zusammenfassung

| Frage | Antwort |
|---|---|
| Aktueller Fortschritt? | **Stillstand** — 0 offene Tasks, Queue leer, Pipeline idle seit ~5 Tagen |
| Tasks umsetzbar? | **Nur eng fokussierte** — code_quality/testing mit 1 File/1 Anker funktionieren (50–63%); komplexe/abstrakte Tasks scheitern (0–10%) |
| Success Rate steigend? | **Nein** — kein Trend, schwankt 4–34%, Gesamt 15%, NOT IMPROVING |
| Modifikationen nötig? | **Ja, dringend** — Provider reparieren, Gating-Blockade lösen, manuell Tasks einspeisen, 0%-Kategorien blacklisten |

**Prognose**: Ohne manuellen Eingriff ändert sich nichts. Das System befindet sich in einem stabilen Deadlock — der defekte Provider verhindert Task-Generierung, die Gating-Logik blockiert alles weitere. Die gelernten Rules funktionieren bei geeigneten Tasks, aber es kommen keine nach. Der wichtigste einzelne Schritt ist die Reparatur oder Umroutung des claude-Providers.
