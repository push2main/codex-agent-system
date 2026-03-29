# Fortschrittsbericht — 2026-03-26T21:10Z (Scheduled v8)

## TL;DR

Das System ist weiterhin **IDLE** — seit mindestens 3+ Stunden wird kein Task ausgeführt. Die 3 queued Tasks (130–132) werden nicht dispatched. Der Hauptblocker ist jetzt nicht mehr der Backlog-Deadlock (v23 gefixt), sondern ein **Queue-Gate + Dispatch-Deadlock**: Die Strategy-Loop blockiert sich selbst durch `loop_effort=true` und `retry_churn=true`, und der Queue-Worker picked die vorhandenen Tasks nicht auf.

---

## 1. Aktueller Systemzustand

| Metrik | Wert | Seit letztem Report |
|--------|------|---------------------|
| Pipeline-Status | **IDLE** | Unverändert |
| Laufende Tasks | 0 | Unverändert |
| Queued Tasks | 3 (task-130, 131, 132) | Unverändert |
| Pending Approval | 3 (task-012, 133, 134) | Unverändert |
| All-time Success | 15% (526 Tasks) | Unverändert |
| Recent Success (50) | 28% | Unverändert |
| Non-Timeout Success | 27% (+6.2pp/100) | Unverändert |
| Learned Rules | 19/20 | -1 (konsolidiert in v23) |
| Letzte Ausführung | ~2026-03-25T02:00Z | **>43 Stunden her** |

**Fazit: Kein einziger Task wurde seit dem letzten Report ausgeführt. Die Metriken sind identisch.**

---

## 2. Warum passiert nichts? — Diagnose

### Neuer Deadlock: Queue-Gate blockiert alles

Die Strategy-Loop loggt jede Minute denselben Eintrag:

```
Queue gate active: success_rate=0.1 queue_size=3 loop_effort=true retry_churn=true — skipping strategy run
```

**Ursache**: Die Health-Flags `loop_effort=true` und `retry_churn=true` in metrics.json sind **historische Artefakte** — sie basieren auf alten Execution-Daten (vor 43+ Stunden). Es gab seither keine neuen Ausführungen, aber die Flags wurden nie zurückgesetzt.

**Auswirkungskette**:
1. Health-Flags `loop_effort` + `retry_churn` sind true (historisch, nicht aktuell)
2. Queue-Gate in strategy-loop.sh sieht diese Flags → blockiert Strategy-Runs
3. Queue-Worker dispatched die 3 queued Tasks nicht (Dispatch scheint ebenfalls blockiert)
4. Ohne Task-Ausführung ändern sich die Flags nie → **Permanent-Deadlock**

### Zusätzlich: Self-Improve blockiert

```
self-improve: generated=0, submitted=0, reason=cooldown_active
```

Die Self-Improve-Pipeline generiert keine neuen Tasks, weil der Cooldown aktiv ist. Da die 3 queued Tasks nie ausgeführt werden, ändert sich auch daran nichts.

---

## 3. Sind die queued Tasks umsetzbar?

| Task | Beschreibung | Provider | Umsetzbar? |
|------|-------------|----------|------------|
| task-130 | Improve first-pass success rate | claude | **BEDINGT** — zu breit, müsste scope-reduziert werden |
| task-131 | Break retry churn | claude | **JA** — adressiert direkt einen der Health-Flags |
| task-132 | Reduce strategy saturation | claude | **BEDINGT** — strategy_saturation ist aktuell false, niedriger Impact |

**Empfehlung**: task-131 hat den höchsten unmittelbaren Impact, weil sein Erfolg direkt `retry_churn=true` auf `false` setzen könnte und damit den Queue-Gate-Deadlock teilweise löst.

---

## 4. Heben wir die Success-Rate?

**Theoretisch ja, praktisch nein** — weil keine Tasks ausgeführt werden.

Die Trenddaten zeigen klare Verbesserung bei den letzten aktiven Fenstern:
- Window 401–500: 24% (+12pp vs. Vorgänger)
- Non-Timeout Velocity: +6.2pp pro 100 Tasks
- Letzte 10 gemessene Tasks: 60% Erfolg

Das Lernsystem funktioniert. Die Regeln greifen. Aber die Pipeline steht still.

---

## 5. Notwendige Modifikationen

### KRITISCH: Deadlock brechen (Priorität 1)

**A) Health-Flag-Reset bei Pipeline-Stale**
- `loop_effort` und `retry_churn` müssen automatisch auf `false` gesetzt werden, wenn keine Task-Ausführung in den letzten N Stunden stattfand (z.B. 6h)
- Begründung: Historische Flags ohne neue Datenpunkte haben keinen diagnostischen Wert und blockieren nur

**B) Queue-Gate Escape-Hatch für Idle-Pipeline**
- Wenn `running_tasks=0` UND `queued_tasks>0` UND `last_execution > 6h ago`: Health-Gate temporär überspringen
- Die v21-Escape-Hatch-Implementation existiert im Code, ist aber offensichtlich nicht aktiv

**C) Queue-Worker muss unabhängig vom Strategy-Gate dispatchen**
- Der Queue-Worker sollte vorhandene `.txt`-Queue-Einträge abarbeiten, unabhängig davon, ob die Strategy-Loop geblockt ist
- Aktuell scheint der Dispatch-Pfad ebenfalls durch die Health-Flags blockiert

### HOCH: Metrics bereinigen (Priorität 2)

**D) Stale Health-Flags zurücksetzen**
- `retry_churn_detected: true` → `false` (basiert auf Daten >43h alt)
- `queue_starvation_detected: true` → `false` (es GIBT 3 queued Tasks)
- `loop_effort_detected: true` → `false` (keine aktuelle Loop-Aktivität)

**E) Pending-Approval Tasks freigeben oder shelven**
- task-012 (Cap pre-step planning budget): **Approven** — höchster Impact
- task-133 (Improve retry success rate): **Approven** — adressiert retry_churn
- task-134 (Refresh stale external signals): **Shelven** — niedrige Priorität

### MITTEL: Strukturelle Verbesserungen (Priorität 3)

**F) Auto-Approval-Bug fixen** (aus vorherigem Report, noch offen)
- Auto-Approval-Code liegt innerhalb des Cooldown-Blocks in strategy-loop.sh
- Muss als eigenständige Funktion VOR den Cooldown-Check

**G) Staleness-Tracking separieren**
- `last_successful_execution_at` separat tracken
- Ancillary-Prozesse (self-improve, compact-registry) dürfen Staleness-Timer nicht zurücksetzen

---

## 6. Prognose

| Szenario | Erwartung |
|----------|-----------|
| **Ohne Eingriff** | Pipeline bleibt permanent idle. Kein Fortschritt möglich. |
| **Health-Flags manuell resetten** | Kurzfristige Entsperrung, aber Deadlock kehrt zurück sobald ein Task fehlschlägt |
| **Escape-Hatch + Flag-Decay implementieren** | Nachhaltige Lösung. Pipeline kann sich selbst aus Idle-Zuständen befreien. Nächste 50 Tasks: ~30% Success erreichbar. |

---

## 7. Gesamtbewertung

Das codex-agent-system hat ein **nachweislich funktionierendes Lernsystem** — die Non-Timeout-Verbesserung von +6.2pp/100 Tasks und die 60%-Erfolgsrate der letzten 10 Tasks belegen das. Die 19 gelernten Regeln, 100% Failure-Klassifizierung und das Provider-Routing sind solide.

**Das Problem ist nicht die Task-Qualität oder das Learning, sondern die Pipeline-Infrastruktur.** Das System hat sich in einen Permanent-Deadlock manövriert, in dem historische Health-Flags (die auf längst veralteten Daten basieren) jede Aktivität blockieren. Die v23-Fixes haben den Backlog-Deadlock gelöst, aber einen neuen Queue-Gate-Deadlock offengelegt.

**Empfohlene Sofortmaßnahme**: Health-Flags manuell zurücksetzen UND einen Auto-Decay-Mechanismus implementieren, der Flags nach X Stunden ohne Aktivität automatisch cleared. Ohne diesen Eingriff bleibt das System auf unbestimmte Zeit blockiert.
