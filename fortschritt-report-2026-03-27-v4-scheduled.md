# Fortschrittsbericht — 2026-03-27 (Scheduled Run v4)

## Kurzfassung

Das System macht **langfristig Fortschritt** (Success-Rate von 4% auf 28% in den letzten 50 Runs), ist aber aktuell **blockiert durch ein wiederkehrendes Infrastruktur-Problem**: Die Live-Queue (`queues/`) ist leer, obwohl 3 Tasks bereitstehen. Die Pipeline steht seit **>17 Stunden** still. Ohne Fix können keine Tasks dispatched werden.

---

## 1. Aktuelle Lage

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| All-time Success Rate | 15% (526 Runs) | Baseline |
| Recent-50 Success Rate | 28% | Aufwärtstrend |
| Recent-20 Success Rate | 10% | Regression (Timeout-Burst) |
| Non-Timeout Success Rate | 27% (+6.2pp/100) | Steigend |
| Pipeline Status | **STALE seit 17h** | KRITISCH |
| Queued Tasks | 3 (task-130, 131, 132) | Bereit, aber blockiert |
| Pending Approval | 1 (task-133) | Wartet seit 11.5h |
| Registry | 20 Tasks (12 shelved, 3 failed, 1 completed) | Gesund (31% Pressure) |
| Learned Rules | 12/20 (8 Slots frei) | Gesund nach v30-Konsolidierung |

## 2. Kritischer Blocker: Queue-Directory-Mismatch (5. Mal!)

**Das Kernproblem:** Workers lesen aus `queues/codex-agent-system.txt` — diese Datei ist **0 Bytes**. Die 3 bereiten Tasks stehen in `codex-queue/codex-agent-system.txt` (762 Bytes). Dieses Problem tritt nun zum **5. Mal** auf (v23, v24, v29, v30, jetzt).

**Warum der Fix nicht hält:** Der in v30 eingebaute "queue-sync guard" in `strategy-loop.sh` kopiert zwar automatisch von `codex-queue/` nach `queues/`, aber offenbar läuft der Strategy-Loop selbst nicht aktiv — und damit greift der Guard nie. Das ist ein Henne-Ei-Problem: Der Guard repariert die Queue nur, wenn der Loop läuft, aber der Loop startet keine Tasks, wenn die Queue leer ist.

**Empfohlene Modifikation:** Der Queue-Sync muss **außerhalb** des Strategy-Loops laufen — entweder als eigenständiger Cron-Job oder als Pre-Check in `multi-queue.sh` (dem Worker-Dispatcher). So wird die Queue auch repariert, wenn der Strategy-Loop idle ist.

## 3. Sind die 3 queued Tasks umsetzbar?

| Task | Ziel | Dateien | Machbar? | Anmerkung |
|------|------|---------|----------|-----------|
| **task-130** — First-pass Success Rate verbessern | Planner-Context-Qualität erhöhen | `agents/planner.sh` | **Ja** | Single-file, klar scopiert, Provider: claude |
| **task-131** — Retry-Churn brechen | Exponential Backoff, identische Errors skippen | `agents/orchestrator.sh` | **Ja** | Single-file, konkreter Fix, hohe Impact-Erwartung |
| **task-132** — Strategy-Saturation reduzieren | Generation-Cooldown, Duplikat-Pruning | `scripts/strategy-loop.sh` | **Ja, mit Vorbehalt** | Risiko: Strategy-Loop-Änderungen können den Guard aus v30 beeinflussen |

**Fazit:** Alle 3 Tasks sind umsetzbar und korrekt scopiert (single-file, jeweils ≤3 Steps). Sie folgen den Learned Rules. task-131 hat das höchste Impact-Potenzial.

## 4. Task-133 (Pending Approval): Bewertung

**"Improve retry success rate"** — zielt auf `agents/orchestrator.sh` + `scripts/lib.sh` (2 Dateien).

**Problem:** Die Learned Rules sagen: Multi-file self-improve Tasks haben 0% Success. Dieser Task sollte entweder auf eine Datei reduziert oder in zwei Tasks gesplittet werden, bevor er approved wird.

**Empfehlung:** Task-133 auf `agents/orchestrator.sh` only reduzieren (dort liegt der Retry-Logic-Kern). `lib.sh`-Änderungen als separaten Follow-up-Task.

## 5. Success-Rate-Trend: Analyse

```
Window   | Rate  | Timeouts | Trend
---------|-------|----------|------
  1- 50  | 34%   |    19    | Anfangs-Bonus (einfache Tasks)
 51-100  |  4%   |     5    | Absturz (komplexe Tasks)
101-200  |  5%   |    71    | Timeout-Krise
201-300  | 13%   |    57    | Erholung beginnt
301-400  | 13%   |    17    | Timeout-Problem gelöst
401-500  | 24%   |    49    | Deutlicher Aufwärtstrend
501-526  | 19%   |    19    | Leichte Regression (superheld-Tasks)
```

**Langfristiger Trend: POSITIV** (+4.4pp über 526 Runs, +1.36pp/100 Tasks). Die Non-Timeout Success Rate steigt sogar mit +6.23pp/100. Das System lernt, aber es muss **aktiv laufen**, um zu lernen.

## 6. Empfohlene Modifikationen

### Sofort (Infrastruktur-Fix)
1. **Queue-Sync aus Strategy-Loop extrahieren** → eigener Mechanismus in `multi-queue.sh` oder als Cron
2. **Pipeline-Stale-Watchdog** → wenn `pipeline_stale` > 6h, automatisch Queue-Repair + Worker-Restart triggern
3. **Task-133 auf Single-File reduzieren** → nur `agents/orchestrator.sh`, dann approven

### Kurzfristig (Task-Qualität)
4. **Dispatch-Reihenfolge:** task-131 (Retry-Churn) → task-130 (First-pass) → task-132 (Saturation)
5. **Worker-Health-Check** einbauen: Wenn alle 4 Worker-Lanes >30min idle, Alert + Auto-Restart

### Mittelfristig (System-Design)
6. **Dual-Queue-Architektur abschaffen** → eine einzige Queue-Datei, die sowohl von Dispatchern als auch Workern verwendet wird. Das eliminiert die Synchronisations-Probleme permanent.
7. **Cooldown-Logik überdenken** → Self-Improve-Cooldown + Pipeline-Stale + leere Queue erzeugen Triple-Lock (diagnostiziert in v29), die das System für Stunden lahmlegt.

## 7. Gesamtbewertung

| Aspekt | Status | Note |
|--------|--------|------|
| Task-Design & Scoping | Gut (nach v28-v30 Fixes) | Rules werden befolgt |
| Provider-Routing | Gut (Testing 80%, Auth 40%) | Stabil |
| Learned Rules | Gut (12/20, konsolidiert) | 8 Slots für neue Learnings |
| Queue-Infrastruktur | **Kritisch** | 5. Wiederholung desselben Bugs |
| Worker-Dispatch | **Blockiert** | Seit 17h kein Task ausgeführt |
| Self-Improve-Loop | **Blockiert** | Cooldown + Stale + leere Queue |
| Langfristiger Trend | Positiv | +4.4pp, System lernt wenn es läuft |

**Kernaussage:** Das System hat die richtigen Tasks, die richtigen Rules und die richtige Strategie — aber es kann sie nicht ausführen, weil die Infrastruktur (Queue-Sync) wiederholt versagt. Der wichtigste nächste Schritt ist nicht ein neuer Task, sondern ein **struktureller Fix der Queue-Architektur**, idealerweise durch Vereinheitlichung auf ein einziges Queue-Verzeichnis.
