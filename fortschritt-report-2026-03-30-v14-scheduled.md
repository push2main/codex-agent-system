# Fortschrittsbericht — 30. März 2026, v14 (Scheduled)

## Systemstatus: PIPELINE-DEADLOCK — Keine Verbesserung seit v13

---

## Kennzahlen (aktuell, 13:07 UTC)

| Metrik | Wert | Trend seit v13 |
|---|---|---|
| Tasks gesamt (Archiv) | 1.103 | unverändert |
| Aktive Registry | 11 (7 shelved, 4 completed) | unverändert |
| Queue | **0 Tasks** | KRITISCH — seit 3+ Tagen leer |
| All-time Success Rate | 15% | stagnierend |
| Recent Success Rate | 22–26% (schwankend) | leicht fallend |
| First-Pass Rate (historisch) | 57–67% | gut (wenn Tasks laufen) |
| Timeout-Rate | 44% | unverändert |
| Zero-Step-Timeout-Rate | 90% der Timeouts | KRITISCH, unverändert |
| Registry-Größe | 228 KB (aktiv) / 4.3 MB (Archiv) | leichter Anstieg |
| Letzter erfolgreicher Task | 24. März | **6 Tage ohne Erfolg** |
| Cooldown-Files aktiv | 3 von 3 | Blocker aktiv |

---

## 1. Sind die bisherigen Tasks umsetzbar?

**Ja — wenn sie tatsächlich ausgeführt werden.** Die heutigen Runs (13:05–13:07 UTC) zeigen, dass Tasks grundsätzlich laufen können:

- **Run 13:05 (claude-code Provider)**: "Document mandatory MVP protection cases in first slice" — Step 1 wurde vom Evaluator als **success** bewertet. Step 2 (Verify) lief noch. Das zeigt: mit dem richtigen Provider (claude-code statt codex) gelingen Steps.
- **Run 12:53 (codex Provider)**: Gleicher Task, aber mit codex Provider — Step 1 scheiterte zweimal (coder lieferte kein Ergebnis, dann editierte statt nur zu inspizieren).

**Kernbefund:** Derselbe Task gelingt mit claude-code und scheitert mit codex. Das Provider-Routing ist der unmittelbare Hebel.

---

## 2. Heben wir die Success Rate?

**Nein. Das System ist seit 6 Tagen bei effektiv 0% Completions.**

| Zeitraum | Success Rate | Status |
|---|---|---|
| 24. März (Peak) | 67% | Funktionsbeweis |
| 25. März | 28% | Abfallend |
| 27.–28. März | 0% (0/27) | Deadlock-Beginn |
| 29.–30. März | 0 Completions | Pipeline steht |

Die Self-Improve-Engine loggt weiterhin alle 600s, generiert vereinzelt Tasks, aber:
- `queue_starvation_detected: False` obwohl Queue seit Tagen leer
- Cooldown wird nach jedem Zyklus erneuert
- Strategy-Board meldet "no changes needed"

---

## 3. Die drei verketteten Blocker (unverändert seit v13)

### Blocker A: Cooldown-Endlosschleife
Alle drei Cooldown-Files sind aktiv (zuletzt erneuert 13:01 UTC heute):
- `self-improve-superheld-cooldown` (30. März 13:01)
- `self-improve-codex-agent-system-cooldown` (30. März 02:15)
- `self-improve-cooldown` (26. März 06:42)

Die Engine wacht auf → findet leere Queue → setzt neuen Cooldown → schläft 600s → Endlosschleife.

### Blocker B: Shelving-Spirale
Task-Generator erzeugt denselben Task-Titel ("Inventory current decision path...") → wird als Zombie erkannt → geshelved → regeneriert. 99.6% des Archivs sind Shelves.

### Blocker C: Provider-Routing auf schwächsten Provider
Die heutigen Runs beweisen das Problem direkt:
- **codex** (Default): Step 1 scheitert, Evaluator gibt "fail"
- **claude-code**: Step 1 gelingt, Evaluator gibt "success"

Das Routing-Log zeigt: `Provider selection: base=codex effective=claude-code` — der Override auf claude-code funktioniert für manche Tasks, aber die Mehrheit geht noch über codex.

---

## 4. Empfohlene Modifikationen (priorisiert)

### SOFORT — Manueller Eingriff nötig

**1. Cooldown-Files löschen** (30 Sekunden Aufwand):
```
rm codex-logs/self-improve-superheld-cooldown
rm codex-logs/self-improve-codex-agent-system-cooldown
rm codex-logs/self-improve-cooldown
```

**2. Default-Provider auf claude-code umstellen** in `codex-learning/provider-routing.json`:
Die heutigen Runs liefern den A/B-Beweis. Gleicher Task: codex → fail, claude-code → success.

**3. Cooldown-Timer von 600s auf 120s reduzieren** in `scripts/lib.sh`:
Bei leerer Queue muss die Engine schneller reagieren, nicht 10 Minuten warten.

### MITTELFRISTIG — Systemänderungen

**4. Queue-Starvation-Detection reparieren**: Meldet `False` obwohl Queue seit 3 Tagen leer. Offensichtlich defekter Check.

**5. Task-Titel-Deduplizierung**: Vor Generierung gegen letzte 50 shelved/failed Tasks prüfen. Normalisierter Titel-Match → nicht regenerieren.

**6. Zero-Step-Timeout bekämpfen**: 90% aller Timeouts passieren in der Planungsphase. Die CLAUDE.md-Regel "cap planning to 60s" wird nicht durchgesetzt. Der PLANNING_TIMEOUT_SECONDS Wert muss im Orchestrator tatsächlich als harter Kill implementiert werden.

**7. Kategorien mit 0% Success pausieren**: security (0/24), ux (0/52), backend (0/12), architecture (0/12).

### LANGFRISTIG

**8. Manueller Task-Kanal**: Template-basierte Tasks als Backup, damit Self-Improve nicht der Single-Point-of-Failure ist.

**9. Archiv-Kompaktierung**: 1.103 Einträge, 4.3 MB, davon 99.6% Shelves — Ballast entfernen.

---

## 5. Was hat sich seit dem letzten Report (v13) geändert?

**Positiv:**
- Neue Runs heute (13:05–13:07) zeigen, dass das System noch lebt und Tasks verarbeiten kann
- claude-code Provider liefert Step-1-Success für einen Task, der mit codex scheiterte → klarer Provider-Routing-Beweis

**Negativ:**
- Kein einziger Task vollständig abgeschlossen seit v13
- Cooldown-Files weiterhin aktiv, werden laufend erneuert
- Strategy-Board erkennt kein Problem ("no changes needed")
- Registry wächst leicht (211→228 KB) durch neue shelved Tasks

**Unverändert:**
- Queue leer, 0 approved Tasks, 0 running Tasks
- Alle drei Blocker (Cooldown, Shelving, Provider) weiterhin aktiv
- Timeout-Rate bei 44%, Zero-Step bei 90%

---

## 6. Zusammenfassung

| Frage | Antwort |
|---|---|
| Tasks umsetzbar? | **Ja** — heute bewiesen mit claude-code Provider |
| Success Rate steigend? | **Nein** — 0% seit 6 Tagen, Pipeline steht |
| Modifikationen nötig? | **Ja, dringend** — 3 manuelle Eingriffe (je 30s) |

**Kerndiagnose:** Das System kann Tasks lösen (claude-code Provider: Step 1 success heute), aber die Pipeline ist durch drei mechanische Blocker lahmgelegt. Ohne manuellen Eingriff (Cooldown löschen, Provider umstellen, Starvation-Detection fixen) wird sich der Deadlock nicht selbst auflösen. Die empfohlenen Sofortmaßnahmen erfordern zusammen weniger als 5 Minuten manuellen Aufwand.

**Dringlichkeit: HOCH** — Jeder weitere Tag ohne Eingriff verschwendet Rechenzeit in leeren Cooldown-Zyklen ohne jeglichen Output.
