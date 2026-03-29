# Fortschrittsbericht — Codex Agent System
**Datum:** 2026-03-25, 10:15 UTC (Scheduled Task Run)
**Basis:** 522 Tasks, 169 im Registry, 70 dokumentierte Learnings

---

## 1. Aktuelle Kennzahlen

| Metrik | Wert | Trend | Bewertung |
|--------|------|-------|-----------|
| Gesamterfolgsrate | 15% | stagnierend | kritisch |
| Recent Success (letzte 50) | 28% | ↑ verbessert (von 26%) | positiv |
| First-Pass Success | 55% | ↓ leicht fallend (von 58%) | Aufmerksamkeit nötig |
| Timeout-Rate | 36% | ↓ verbessert (von 49%) | Fortschritt sichtbar |
| Retry-Klassifizierung | 87% | ↑ stark verbessert (von 24%) | großer Erfolg |
| Learned Rules | 10 von max 20 | ↑ verdoppelt (von 5) | Fortschritt |
| Registry-Druck | 1.18 MB (Schwelle: 512 KB) | kritisch | Handlungsbedarf |

## 2. Was funktioniert

Die jüngsten Systemverbesserungen zeigen messbare Wirkung. Die Retry-Klassifizierung ist von 24% auf 87% gestiegen — das war der Hauptblindspot, weil der Learner ohne korrekte Fehlerklassifikation keine Regeln ableiten konnte. Die Timeout-Rate ist von 49% auf 36% gesunken, getrieben durch die neue Regel "max 3 Dateien, unter 100 LOC pro Step". Die Regelbasis hat sich von 5 auf 10 verdoppelt, nachdem der Learner-Bug (Überschreiben statt Akkumulieren) behoben wurde.

Der Recent-Success von 28% zeigt, dass die letzten 50 Tasks fast doppelt so gut laufen wie der historische Durchschnitt. Das System lernt tatsächlich — aber langsam.

## 3. Was nicht funktioniert

**Registry-Druck (KRITISCH):** Die superheld-Registry allein ist 1.08 MB groß. Das verlangsamt Dashboard-Reads und triggert endlose "reduce registry pressure"-Tasks aus dem Self-Improve-Loop. Task-125 (Registry-Kompression) ist bereits gescheitert und geshelved. Manuelles `compact-registry.sh` ist erforderlich.

**Retry Churn (HOCH):** 70 Tasks haben zusammen 163 verschwendete Step-Attempts verbraucht. Task-127 erreichte Attempt 5 bei max_retries=2 durch 3 Re-Approval-Zyklen. Der `cumulative_attempts`-Fix existiert, ist aber nicht retroaktiv angewendet.

**Self-Improve Tasks scheitern am eigenen System:** Tasks 123, 124, 125 — alle vom Self-Improve-Engine generiert — sind alle gescheitert mit `unknown_persistent`. Das System versucht sich selbst zu reparieren, aber die Reparatur-Tasks sind zu komplex. Das ist ein Teufelskreis.

**Provider-Routing suboptimal:** Claude hat 80% Success bei Testing, aber 0% bei Code Quality und Learning. Codex hat 40% bei Auth, aber nur 9% bei UI. Die Routing-Tabelle nutzt diese Daten nicht aggressiv genug.

## 4. Umsetzbarkeit der aktuellen Tasks

### Pending Approval (1 Task)
- **task-133** "Improve retry failure classification coverage" — **UMSETZBAR und EMPFOHLEN.** Targeting 2 Dateien (orchestrator.sh, lib.sh), klar definiertes Ziel, moderate Komplexität.

### Approved aber wartend (14 Tasks)
14 Tasks sind approved, aber die Queue ist idle. Die meisten davon sind superheld-Projekt-Tasks (Android/KMP), die ohne Docker/SDK nicht lauffähig sind. Sie verbrauchen Registry-Kapazität ohne Execution-Chance.

### Geshelved (3 Tasks)
- task-125 (Registry Pressure) — gescheitert, manueller Eingriff nötig.
- task-132 (Strategy Saturation) — korrekt geshelved, basierte auf stale Metrics.
- task-126 (Work Buffer) — geshelved nach Failure-Threshold.

## 5. Empfohlene Modifikationen

### Sofort (höchster ROI)
1. **`compact-registry.sh` manuell ausführen** für superheld-Projekt, danach `sync-task-artifacts.py`. Bringt Registry von 1.08 MB auf ~130 KB.
2. **task-133 genehmigen** — Retry-Klassifizierung ist der wichtigste Hebel für den Learner.
3. **Provider-Routing updaten:** Learning-Kategorie von codex (7%) auf claude umrouten.

### Kurzfristig (Task-Design)
4. **Self-Improve-Tasks auf max effort=2 beschränken.** Kleinere Schritte, weniger Ambition.
5. **Android/superheld-Tasks einfrieren** bis Docker verifiziert oder SDK lokal verfügbar.
6. **Strategy-Cooldown für Failures auf 48h erhöhen** (aktuell 24h).

### Mittelfristig (Architektur)
7. **Learner aggressiver konfigurieren:** Von 10 auf 15-18 Regeln, Threshold von 3+ auf 2+ Tasks.
8. **Separate "maintenance lane"** für Self-Improve-Tasks mit höherem Timeout.
9. **Dashboard: Lazy-Loading** für Task-Registry gegen Performance-Druck.

## 6. Prognose

Die Success-Rate wird sich **nicht signifikant über 30% heben**, solange drei Blockaden bestehen: (1) Registry-Druck verursacht Feedback-Loops, (2) Android-Tasks ohne Environment verbrauchen Retry-Budget, (3) Self-Improve-Tasks scheitern am eigenen System.

Nach Umsetzung der Sofort-Maßnahmen ist eine Recent-Success-Rate von **35-40%** realistisch innerhalb der nächsten 50 Tasks.

**Fazit:** Das System lernt und verbessert sich messbar, aber es kämpft gegen selbsterzeugte Komplexität. Die wichtigsten Hebel sind Vereinfachung (kleinere Tasks, weniger Registry-Druck) und gezielte manuelle Eingriffe bei den drei identifizierten Blockaden.
