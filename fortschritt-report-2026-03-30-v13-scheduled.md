# Fortschrittsbericht — 30. März 2026, v13 (Scheduled)

## Systemstatus: PIPELINE-DEADLOCK — Sofortmaßnahmen erforderlich

---

## Kennzahlen

| Metrik | Wert | Bewertung |
|---|---|---|
| Tasks gesamt (Archiv) | 1.103 | — |
| Aktive Registry | 11 (7 shelved, 4 completed) | leer |
| Queue | **0 Tasks** | KRITISCH |
| All-time Success Rate | 15% | stagnierend |
| Recent-50 | 0 completed, 30 shelved, 17 failed | **0% seit 27.3.** |
| First-Pass Rate (historisch) | 57–62% | gut (wenn Tasks laufen) |
| Timeout-Rate | 34% historisch, 44% aktuell | zu hoch |
| Zero-Step-Timeout-Rate | 90% der Timeouts | KRITISCH |
| Registry-Größe | 89 KB (aktiv) / 4.3 MB (Archiv) | gesund |
| Letzter erfolgreicher Task | 24. März | **6 Tage ohne Erfolg** |

---

## 1. Sind die bisherigen Tasks umsetzbar?

**Ja, grundsätzlich — aber die Pipeline steht komplett still.**

Die Evidenz: Am 24. März erreichte das System 67% Success Rate an einem Tag. Die 4 abgeschlossenen Tasks in der aktiven Registry (Kommentar-Updates, Planner/Learner-Tests) bestätigen, dass klar definierte, kleinteilige Tasks zuverlässig lösbar sind. Die First-Pass Rate von 57–62% ist solide.

Das Kernproblem ist nicht Task-Qualität, sondern Pipeline-Stillstand: Seit dem 29. März werden keine neuen Tasks generiert oder ausgeführt. Die letzten 50 archivierten Tasks zeigen 0 Completions — nur Shelves, Failures und Rejects.

---

## 2. Heben wir die Success Rate?

**Nein. Die Rate ist de facto auf 0% gefallen.**

| Zeitraum | Success Rate |
|---|---|
| 24. März (Peak) | 67% |
| 25. März | 28% |
| 27.–28. März | 0% (0/27) |
| 29.–30. März | 0 Tasks ausgeführt |

Die Self-Improve-Engine läuft im Leerlauf-Zyklus. Der Log von heute zeigt:
- `approved_tasks: 0`, `running_tasks: 0`, `queued_tasks: 0`
- `queue_starvation_detected: False` (sollte True sein!)
- Cooldown-Datei aktiv (Timestamp 1774864949 ≈ 30. März 12:02)
- `zero_step_timeout_rate: 0.9` — 90% aller Timeouts passieren bevor ein einziger Schritt ausgeführt wird

---

## 3. Diagnose: Drei verkettete Blocker

### Blocker A: Cooldown-Loop (sofort behebbar)
Die Datei `codex-logs/self-improve-superheld-cooldown` wird alle 600s erneuert. Die Engine wacht auf, findet nichts zu tun, setzt neuen Cooldown. Endlosschleife.

### Blocker B: Shelving-Spirale (Konfigurationsproblem)
Am 28. März wurde "Inventory current decision path for improve first-pass success rate" 19x hintereinander geshelved/restarted. Der Task-Generator erzeugt denselben Task immer wieder, er wird sofort als problematisch erkannt, geshelved, und neu generiert. Die letzten 20 Archiveinträge sind fast ausschließlich Varianten dieses einen Tasks.

### Blocker C: Provider-Routing suboptimal
Aktuelles Routing: Die meisten Kategorien → `codex` (19% Success). Dabei hat `codex-cli` 28% und `claude-code` 62.5%. Der Default-Provider ist der schwächste.

---

## 4. Empfohlene Modifikationen

### Sofort (Konfiguration — manueller Eingriff nötig)

1. **Cooldown-Dateien löschen**: Alle drei Cooldown-Files entfernen:
   - `codex-logs/self-improve-superheld-cooldown`
   - `codex-logs/self-improve-cooldown`
   - `codex-logs/self-improve-codex-agent-system-cooldown`

2. **Cooldown-Timer verkürzen**: Von 600s auf 120s, damit die Engine bei leerer Queue schneller reagiert.

3. **Queue-Starvation-Detection fixen**: Der Log zeigt `queue_starvation_detected: False` obwohl Queue seit 2 Tagen leer ist. Dieser Check ist offensichtlich defekt.

### Mittelfristig (System-Änderungen)

4. **Provider-Routing anpassen**: `codex-cli` oder `claude-code` als Default statt `codex`. Erwarteter Impact: +10–25pp Success Rate.

5. **Deduplizierungs-Guard im Task-Generator**: Bevor ein neuer Task generiert wird, gegen die letzten 50 shelved/failed Tasks prüfen. Gleicher Titel (normalisiert) → nicht generieren.

6. **Zero-Step-Timeout bekämpfen**: 90% der Timeouts passieren in der Planungsphase. Die CLAUDE.md-Regel "cap planning to 60s" wird offenbar nicht durchgesetzt. Härteres Enforcement nötig.

7. **Kategorien mit 0% Success pausieren**: security (0/24), ux (0/52), backend (0/12), architecture (0/12) — kein Budget mehr dafür aufwenden, bis Root-Cause gelöst.

### Langfristig (Architektur)

8. **Manueller Task-Kanal**: Die komplette Abhängigkeit von Self-Improve ist ein Single-Point-of-Failure. Template-basierte Tasks als Backup.

9. **Archiv-Kompaktierung**: 4.3 MB / 1.103 Einträge — Zombie-Tasks (85 Titel mit 3+ Failures) bereinigen.

---

## 5. Zusammenfassung

| Frage | Antwort |
|---|---|
| Tasks umsetzbar? | **Ja** — 62% First-Pass wenn sie laufen |
| Success Rate steigend? | **Nein** — 0% seit 6 Tagen, Pipeline steht |
| Modifikationen nötig? | **Ja, dringend** |

**Kerndiagnose:** Das System hat bewiesen, dass es funktioniert (67% am 24.3.). Das aktuelle Problem ist kein Qualitäts- sondern ein Infrastrukturproblem: Cooldown-Loop + Shelving-Spirale + fehlende Queue-Starvation-Erkennung haben die Pipeline in einen Deadlock gebracht. Ohne manuellen Eingriff (Cooldown löschen, Timer kürzen, Starvation-Detection fixen) wird sich dieser Zustand nicht selbst auflösen.

**Priorität 1:** Cooldown-Files löschen und Timer verkürzen.
**Priorität 2:** Provider-Routing auf codex-cli umstellen.
**Priorität 3:** Task-Deduplizierung gegen Shelving-Spiralen.
