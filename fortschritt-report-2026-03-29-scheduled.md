# Fortschrittsbericht — 29. Marz 2026 (Scheduled)

## Systemzustand: STALLED — Pipeline seit 5+ Tagen tot

Seit dem letzten ausfuhrlichen Report (28. Marz, v6) hat sich am Kernproblem nichts geandert. Das System befindet sich weiterhin in einem stabilen Deadlock. Kein einziger Task wurde seit dem 25. Marz erfolgreich abgeschlossen.

---

## Kennzahlen

| Metrik | Wert | Trend |
|---|---|---|
| Total Tasks | 587 | +12 seit letztem Report (nur Self-Improve-Versuche) |
| All-time Success Rate | 13% | unverandert |
| Recent Success Rate (letzte 50) | **0%** | seit 5+ Tagen |
| First-Pass Success | **0%** | kein einziger Task auf Anhieb erfolgreich |
| Timeout-Rate | 35% (206 Events) | unverandert |
| Zero-Step Timeouts | 91% aller Timeouts | Planner-Overhead bleibt Hauptursache |
| Pipeline stale seit | 2026-03-25T06:24:53Z | ~4.5 Tage |
| Laufende Tasks | 0 | — |
| Queued Tasks | 0 (aktiv) | — |
| Task Registry | 57KB lokal / 124KB shared | unter 512KB Grenze |
| Zombie Tasks | 20 (166 verschwendete Slots) | unverandert |
| Retry Churn | aktiv (Alert) | — |
| Self-Improve | PAUSIERT seit 28.03. 10:29 UTC | durch `self-improve-paused` File |

### Verlauf der Success Rate nach Task-Fenstern

```
Tasks   1- 50:  34%  <- fruher Bereich, viele einfache Tasks
Tasks  51-100:   4%
Tasks 101-150:   6%
Tasks 151-200:   4%
Tasks 201-250:  16%
Tasks 251-300:  10%
Tasks 301-350:  14%
Tasks 351-400:  12%
Tasks 401-450:  22%
Tasks 451-500:  26%  <- historisches Maximum
Tasks 501-550:  10%  <- Regression
Tasks 551-587:   0%  <- aktuell, seit ~5 Tagen
```

Improvement Velocity: **-0.69pp pro 100 Tasks** (negativ, System verschlechtert sich).

---

## Sind die bisherigen Tasks umsetzbar?

### Kurzantwort: Nein — nicht im aktuellen Zustand.

**Task Registry (9 Tasks lokal):**
- 6 shelved, 3 failed
- Alle 6 letzten Failures waren `review_rejection` — der Planner erzeugt zu ausfuhrliche Step-Beschreibungen, die dann vom Reviewer abgelehnt werden
- Letzter Task-Update: 29. Marz 01:36 UTC (task-009, ebenfalls gescheitert)

**Queue (codex-queue/):**
- 3 Tasks warten seit dem 24. Marz (130, 131, 132)
- Diese werden **nie ausgefuhrt**, weil Workers aus `queues/` lesen, nicht aus `codex-queue/`
- Der Queue-Directory-Mismatch ist weiterhin der kritischste Bug

**Die 3 wartenden Tasks im Detail:**

1. **Task-130 (Improve First-Pass Success Rate)** — Konzeptionell richtig, aber der Task selbst scheitert am gleichen Problem, das er losen soll. Selbstreferenzieller Deadlock.

2. **Task-131 (Break Retry Churn)** — Teilweise obsolet. Zombie-Guard hat Churn bereits reduziert. `retry_churn_detected` ist allerdings wieder `true`, also weiterhin relevant.

3. **Task-132 (Reduce Strategy Saturation)** — Symptombehandlung. `strategy_saturation_detected = false` aktuell, also niedrige Prioritat.

---

## Hebt sich die Success Rate?

**Nein. Klare Verschlechterung.**

- Trend: NOT IMPROVING (-4.0pp erste vs. zweite Halfte)
- Non-Timeout Success Rate: 23% (uber alle 342 nicht-timeout Tasks) mit -3.71pp/100 Velocity
- Alle `self-improve` Tasks sind mit 0% Erfolgsrate gescheitert
- Provider-Performance: `codex-cli` 28.4%, `claude-code` 62.5%, aber `codex` und `claude` (aktuelle Provider) bei 0%

### Beste historische Rule-Sets (zum Vergleich):
- `afdc1a2d`: 63.6% (11 Tasks) — wurde abgelost
- `422daf81`: 50% (12 Tasks) — fruher Bereich
- Aktuelle Rule-Sets: durchgehend 0%

---

## Notwendige Modifikationen

### P0 — Sofort erforderlich (manueller Eingriff)

**1. Queue-Directory-Mismatch fixen**
- Tasks landen in `codex-queue/*.json`, Workers lesen aus `queues/*.txt`
- Ohne diesen Fix kann kein Task ausgefuhrt werden
- Fix-Optionen: (a) Worker auf `codex-queue/` umstellen, (b) Queue-Writer auf `queues/` umstellen, (c) Sync-Bridge einbauen

**2. Self-Improve kontrolliert re-enablen**
- `codex-logs/self-improve-paused` entfernen
- Aber nur mit Scope-Einschrankung: max 1 File, max 3 Steps, Timeout 300s
- Oder: Einen manuellen Test-Task direkt in `queues/codex-agent-system.txt` platzieren

**3. Review-Rejection-Schleife brechen**
- 6 von 6 letzten Failures sind `review_rejection`
- Ursache: Planner erzeugt Step-Beschreibungen >600 Zeichen, Reviewer lehnt ab
- Laut Shelve-Notes wurde ein Fix in `planner.sh` angewendet, aber der ist noch nicht verifiziert
- Nachste Aktion: MAX_STEP_CHARS in planner.sh validieren (auf 400 reduzieren?)

### P1 — Nach Pipeline-Entsperrung

**4. Provider-Routing korrigieren**
- `codex` und `claude` Provider haben 0% Erfolg (13 bzw. 25 Tasks)
- `claude-code` hatte 62.5% (8 Tasks) — warum wird dieser nicht mehr verwendet?
- Provider-Routing muss auf `claude-code` fur code_quality und testing Tasks umgestellt werden

**5. Rule-Set Rollback evaluieren**
- Das System hatte mit fruherem Rule-Set `afdc1a2d` eine 63.6% Success Rate
- Aktuell 0% — die Regelanderungen seit dem Hohepunkt haben die Performance zerstort
- Empfehlung: Rules auf den Stand von `afdc1a2d` zuruecksetzen und von dort iterieren

**6. Context-Additiv-Problem prufenb**
- MEMORY_CONTEXT, SOURCE_CONTEXT, SIMILAR_TASKS werden einzeln auf 8KB gekappt
- Zusammen konnen sie 24KB+ ergeben und Zero-Step-Timeouts verursachen
- Gesamtbudget fur kombinierten Prompt einfuhren

### P2 — Langfristig

**7. Canary-Task-Mechanismus**: Wenn stale >12h, automatisch einen minimalen Task dispatchen
**8. Pending-Approval-Timeout**: Auto-Shelve nach 6h fur externe Signal-Tasks
**9. Learner-Accumulation-Rate verbessern**: Nur 5 Rules aus 587 Tasks (0.85/100 Tasks)

---

## Diagnose-Zusammenfassung

Das codex-agent-system befindet sich in einem mehrschichtigen Deadlock:

1. **Queue-Mismatch**: Tasks werden nie ausgefuhrt (codex-queue vs. queues)
2. **Self-Improve pausiert**: Keine automatische Reparatur moglich
3. **Review-Rejection-Loop**: Selbst wenn Tasks ausgefuhrt werden, scheitern sie am Reviewer
4. **Provider-Regression**: Aktive Provider (codex, claude) bei 0% — historisch bessere Provider (claude-code) werden nicht genutzt
5. **Rule-Regression**: Aktuelle Regeln performen deutlich schlechter als fruhere Versionen

**Prognose ohne Eingriff**: Das System bleibt auf unbestimmte Zeit bei 0% Recent Success Rate. Die Strategy-Loop dreht im Leerlauf (`stale -> escape -> paused -> repeat`), ohne dass Tasks zur Ausfuhrung kommen.

**Empfehlung**: Manueller Eingriff an P0-Punkten 1-3 ist zwingend erforderlich. Insbesondere der Queue-Mismatch muss zuerst gelost werden. Danach sollte ein einzelner handgeschriebener Mini-Task (z.B. "Add comment to line 1 of README.md") als Canary durch die Pipeline geschickt werden, um zu verifizieren, dass die Ausfuhrungskette funktioniert.
