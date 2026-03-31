# Fortschrittsbericht — 30. März 2026, v15 (Scheduled)

## Systemstatus: ERSTER DURCHBRUCH — 2 Successes heute, aber Pipeline bleibt fragil

---

## Kennzahlen (aktuell, ~14:30 UTC)

| Metrik | Wert | Trend seit v14 |
|---|---|---|
| Tasks gesamt (Archiv) | 1.103 | unverändert |
| Aktive Registry | 11 (7 shelved, 4 completed) | unverändert |
| Queue (codex-agent-system) | **leer** | KRITISCH — Queue weiterhin leer |
| Queue (superheld) | 1 running, 2 failed, 4 shelved, 6 completed | aktiv |
| All-time Success Rate | ~15% | stagnierend |
| Heutige Runs (30. März) | 28 Runs: **10 Success, 17 Fail, 1 offen** | **VERBESSERUNG** |
| Heutige Success Rate | **36%** | deutlich besser als 0% der Vortage |
| Letzter erfolgreicher Run | 30. März 13:06 UTC | **Durchbruch nach 6-Tage-Deadlock** |
| Cooldown-Files aktiv | 3 von 3 (erneuert heute 14:03) | weiterhin Blocker |
| Registry-Größe | ~89 KB (aktiv) / 4.3 MB (Archiv) | stabil |

---

## 1. Was hat sich seit v14 geändert?

### Positiv — Erster Durchbruch
- **10 erfolgreiche Runs heute** (von 28 gesamt) — das ist die beste Tagesbilanz seit dem 25. März
- Zwei aufeinanderfolgende SUCCESS-Runs um 13:05–13:06 UTC für denselben Task ("Document mandatory MVP protection cases in first slice"), je 135–145 Sekunden Laufzeit
- Der **superheld-Projekt** zeigt Aktivität: 6 completed Tasks, 1 running
- Success Rate heute: **36%** — deutlich über dem 0% der letzten 5 Tage

### Negativ — Strukturelle Probleme bleiben
- Cooldown-Files werden weiterhin erneuert (superheld: 14:03 heute)
- codex-agent-system Queue ist komplett leer — keine neuen Tasks werden generiert
- 2 failed Tasks im superheld-Projekt scheinen festzustecken (credential-recovery Thema)
- 1 Task im "running" Zustand seit unbekanntem Zeitpunkt (möglicherweise Zombie)
- 17 fehlgeschlagene Runs heute — davon mindestens 1 planning_failure (zero-step) und 1 unknown_persistent

---

## 2. Sind die bisherigen Tasks umsetzbar?

**Ja, definitiv** — die heutigen Ergebnisse beweisen es:

- **Erfolgreiche Tasks** (Registry): 4 completed im codex-agent-system (planner comment, step-cap test, learner dedup, retry success rate)
- **Superheld**: 6 completed Tasks — das Projekt macht tatsächlich Fortschritt
- **Failure-Muster**: Die Failures kommen nicht von unlösbaren Tasks, sondern von mechanischen Problemen (Provider-Mismatch, Planning-Timeouts, Cooldown-Zyklen)

**Aber**: Die 7 geshelvedten Tasks in der codex-agent-system Registry und die 2 failed Tasks im superheld-Projekt sollten überprüft werden:
- `Inventory current decision path...` — als Zombie klassifiziert, wird immer wieder regeneriert
- `Reduce timeout rate` — meta-Task, der praktisch nicht umsetzbar ist als einzelner Task
- `Review external signal: OpenAI Python releases` — externer Review, 0 Attempts, unklar ob relevant

---

## 3. Heben wir die Success Rate?

**Gemischtes Bild:**

| Zeitraum | Runs | Success | Rate |
|---|---|---|---|
| 22. März | 169 | 2 | 1.2% |
| 23. März | 165 | 12 | 7.3% |
| 24. März | 186 | 16 | 8.6% |
| 25. März | 167 | 30 | **18.0%** |
| 26. März | 8 | 0 | 0% |
| 27. März | 19 | 0 | 0% |
| 28. März | 36 | 0 | 0% |
| 29. März | 20 | 7 | 35.0% |
| **30. März** | **28** | **10** | **35.7%** |

**Trend**: Nach dem Deadlock (26.–28. März mit 0%) zeigt sich eine Erholung am 29.–30. März. Die Success Rate der letzten 2 Tage (35%) ist die beste im gesamten Beobachtungszeitraum. Allerdings ist die Anzahl der Runs drastisch gesunken (28/Tag vs. 170/Tag in der Anfangsphase), was die Rate nach oben verzerrt.

**Kernaussage**: Die Rate verbessert sich, aber der Durchsatz ist eingebrochen. Das System löst wenige Tasks gut, statt viele schlecht.

---

## 4. Notwendige Modifikationen

### SOFORT — Kritische Blocker (unveränderter Befund seit v14)

**1. Cooldown-Files löschen** — alle 3 sind aktiv und blockieren neue Task-Generierung:
```
rm codex-logs/self-improve-superheld-cooldown
rm codex-logs/self-improve-codex-agent-system-cooldown
rm codex-logs/self-improve-cooldown
```

**2. Zombie "running" Task bereinigen** — im superheld-Projekt steckt ein Task im "running" Status fest ("Inventory current decision path for add credential recovery trigger coverage..."). Dieser muss manuell auf failed oder shelved gesetzt werden.

**3. codex-agent-system Queue befüllen** — die Queue ist seit Tagen leer. Die 7 shelved Tasks sollten überprüft werden: mindestens 3 davon (unit tests) sind grundsätzlich umsetzbar und könnten re-approved werden.

### MITTELFRISTIG — Systemverbesserungen

**4. Provider-Routing aktualisieren**: Die heutigen Daten bestätigen weiterhin, dass claude-code für viele Kategorien besser funktioniert. Die Routing-Tabelle basiert auf veralteten Daten (niedrige Sample-Sizes, z.B. claude 0/3 für auth).

**5. Duplicate Task-Generierung unterbinden**: Der "Inventory current decision path" Task wird als Zombie erkannt, geshelved, und sofort regeneriert — ein Endlos-Zyklus.

**6. Zero-Step-Timeout-Guard implementieren**: Planning-Failures (wie Run 12:56 heute) verbrauchen Budget ohne Output.

**7. Archiv-Kompaktierung**: 4.3 MB / 1.103 Einträge, davon >99% shelved — Ballast entfernen, um Dashboard-Performance zu verbessern.

---

## 5. Zusammenfassung

| Frage | Antwort |
|---|---|
| Tasks umsetzbar? | **Ja** — 10 Successes heute beweisen es |
| Success Rate steigend? | **Ja, lokal** — 36% heute vs. 0% an den Vortagen |
| Modifikationen nötig? | **Ja** — Cooldown-Blocker, Zombie-Task, leere Queue |

**Kerndiagnose**: Das System hat den 6-Tage-Deadlock teilweise durchbrochen. Die Success Rate der letzten 2 Tage (35%) ist ein Beweis, dass die Tasks grundsätzlich lösbar sind. Der Hauptblocker ist jetzt nicht mehr die Task-Qualität, sondern der **Pipeline-Durchsatz**: Cooldown-Endlosschleifen und leere Queues verhindern, dass genug Tasks in die Pipeline kommen. Die 3 Sofortmaßnahmen (Cooldown löschen, Zombie bereinigen, Queue befüllen) würden den Durchsatz sofort wiederherstellen.

**Dringlichkeit: MITTEL-HOCH** — Das System funktioniert wieder, aber auf Sparflamme. Ohne Eingriff wird der Durchsatz niedrig bleiben.
