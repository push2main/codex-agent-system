# Fortschrittsbericht — 2026-03-27 (Scheduled, v2)

## Zusammenfassung

Das System ist aktuell **blockiert**. Die Pipeline steht seit über 15 Stunden still. Ursache ist ein wiederkehrender Queue-Sync-Bug, der zum 5. Mal aufgetreten ist. Von 526 Gesamttasks wurde nur 1 erfolgreich abgeschlossen (task-004). Die Success-Rate liegt bei 15% gesamt, mit einer Regression auf 10% in den letzten 20 Tasks. 3 queued Tasks warten seit 3 Tagen auf Dispatch.

---

## 1. Aktueller Task-Status

| Status | Anzahl | Details |
|--------|--------|---------|
| Completed | 1 | task-004 (Cap pre-step planning budget) |
| Queued | 3 | task-130, 131, 132 — **blockiert seit 2026-03-24** |
| Pending Approval | 1 | task-133 (Improve retry success rate) |
| Failed | 3 | task-002, 009, 010 |
| Shelved | 12 | Duplikate, Zombies, resolved conditions |

**Fazit:** Nur 1 von 20 lokalen Tasks war erfolgreich. 3 Tasks hängen in der Queue, können aber nicht dispatcht werden.

---

## 2. Success-Rate Trend

| Window | Rate | Timeouts |
|--------|------|----------|
| Tasks 1-50 | 34% | 19 |
| Tasks 51-100 | 4% | 5 |
| Tasks 101-150 | 6% | 33 |
| Tasks 151-200 | 4% | 38 |
| Tasks 201-250 | 16% | 34 |
| Tasks 251-300 | 10% | 23 |
| Tasks 301-350 | 14% | 5 |
| Tasks 351-400 | 12% | 12 |
| Tasks 401-450 | 22% | 29 |
| Tasks 451-500 | 26% | 20 |
| Tasks 501-526 | 19% | 19 |

**Langfristiger Trend:** Leicht steigend (+4.4pp über Gesamtlaufzeit), aber mit starken Schwankungen. Der Anstieg von 4% → 26% (Window 51-500) zeigt, dass das Lernsystem grundsätzlich wirkt. Die letzte Window (501-526) zeigt allerdings einen Rückgang auf 19%.

**Non-Timeout Success Rate:** 27% — das ist der bereinigte Wert ohne Timeout-Failures. Steigt mit +6.2pp/100 Tasks.

---

## 3. Kritische Probleme

### 3.1 Queue-Sync-Bug (BLOCKER — 5. Wiederholung)

- `queues/codex-agent-system.txt` = **0 Bytes** (leer)
- `codex-queue/codex-agent-system.txt` = 3 Einträge (task-130, 131, 132)
- Workers lesen nur aus `queues/` → Tasks unsichtbar

Der v30 "Structural Fix" (Auto-Sync-Guard in strategy-loop.sh) ist zwar **im Code vorhanden** (Zeile 114-125), aber das Problem besteht weiterhin. Mögliche Ursachen:
1. Strategy-Loop läuft nicht (kein Trigger seit letztem Session-Ende)
2. Die Auto-Sync-Logik greift nur wenn die Loop tatsächlich iteriert
3. Kein persistenter Daemon — Fix funktioniert nur während aktiver Sessions

**Empfehlung:** Die Queue-Sync muss als **eigenständiges Cron-/Scheduled-Script** laufen, nicht als Teil der Strategy-Loop. Solange die Loop nicht aktiv ist, gibt es keine Sync.

### 3.2 Zero-Step-Timeout Rate: 94%

Von 237 Timeout-Failures scheitern 223 (94%) **bevor auch nur ein Schritt ausgeführt wird**. Das deutet darauf hin, dass die Planungsphase selbst zu lange dauert oder der Kontext zu groß ist.

**Empfehlung:**
- Planner-Kontext drastisch reduzieren (aktuell wird zu viel Registry/History geladen)
- Hard-Timeout für Planner auf 30s statt 60s senken
- Task-Beschreibungen auf maximal 1 Satz + 1 Datei beschränken

### 3.3 Pipeline-Stall seit 15+ Stunden

`pipeline_stale: true` seit 2026-03-26T12:17:56Z. Kein Task wurde seitdem erfolgreich dispatcht oder ausgeführt.

### 3.4 Zombie-Problem

18 Zombie-Tasks haben 156 Ausführungsversuche verbraucht. Die Zombie-Guard-Regel (shelve nach 5+ Failures) existiert, aber Tasks werden trotzdem neu erstellt (z.B. 5x "Reduce timeout rate").

---

## 4. Sind die aktuellen Tasks umsetzbar?

### task-130: "Improve first-pass success rate" (queued, priority 7)
- **Ziel:** Planner-Kontext-Qualität verbessern in `agents/planner.sh`
- **Einschätzung: UMSETZBAR** — Einzelne Datei, klarer Scope. Erfordert aber funktionierende Queue.

### task-131: "Break retry churn" (queued, priority 6)
- **Ziel:** Exponential Backoff in `agents/orchestrator.sh`
- **Einschätzung: UMSETZBAR** — Klar definiert, eine Datei, technisch machbar.

### task-132: "Reduce strategy saturation" (queued, priority 4)
- **Ziel:** Generation-Cooldown in `scripts/strategy-loop.sh`
- **Einschätzung: UMSETZBAR MIT RISIKO** — Strategy-Loop ist komplex (400+ Zeilen), Änderungen könnten Seiteneffekte haben.

### task-133: "Improve retry success rate" (pending_approval)
- **Einschätzung: APPROVAL GEBEN** — Passt zum aktuellen Problemfeld.

**Gesamtbewertung:** Die 3 queued Tasks sind gut geschnitten (jeweils 1 Datei, spezifischer Scope) und prinzipiell umsetzbar — **aber sie können nicht starten**, weil die Queue nicht synchronisiert wird.

---

## 5. Empfohlene Modifikationen

### Sofort (Infrastruktur)

1. **Queue manuell synchronisieren** — Entries von `codex-queue/` nach `queues/` kopieren
2. **Scheduled Task für Queue-Sync** — Alle 5 Minuten prüfen und synchronisieren, unabhängig von Strategy-Loop
3. **task-133 approven** — Wartet auf Freigabe

### Kurzfristig (System-Konfiguration)

4. **Zero-Step-Timeout adressieren** — Planner-Timeout auf 30s senken, Kontextgröße begrenzen
5. **Dedup-Guard härten** — Vor Task-Erstellung gegen alle Titel prüfen (inkl. shelved), nicht nur aktive Tasks
6. **Pipeline-Stale-Alarm** — Nach 2h automatisch Queue-Health-Check triggern

### Mittelfristig (Architektur)

7. **Queue-Architektur vereinfachen** — Zwei parallele Queue-Verzeichnisse sind eine dauerhafte Fehlerquelle. Migration auf ein einziges Verzeichnis oder eine DB-basierte Queue.
8. **Planner-Kontext-Budget** — Hartes Token-Limit für den Planner-Input, um Zero-Step-Timeouts strukturell zu verhindern
9. **Worker-Health-Monitoring** — Wenn Tasks >48h in Queue stehen, automatischen Alert + Recovery

---

## 6. Metriken-Snapshot

```
Success Rate (gesamt):     15% (526 Tasks)
Success Rate (letzte 50):  28%
Success Rate (letzte 20):  10% (Regression!)
Non-Timeout Success:       27% (+6.2pp/100)
Timeout-Rate:              37%
Zero-Step-Timeout:         94%
Pipeline Stale:            JA (seit 15h)
Queue Sync:                BROKEN (5. Mal)
Learned Rules:             12/20 (8 frei)
Zombie Tasks:              18 (156 verschwendete Versuche)
```

---

## 7. Fazit

Das System hat **Fortschritte im Lernsystem** gemacht (Trend +4.4pp, Rule-Consolidation von 22→12, Classification-Coverage 100%), ist aber **operativ blockiert** durch den wiederkehrenden Queue-Sync-Bug. Die aktuellen 3 queued Tasks sind gut geschnitten und umsetzbar, aber sie kommen nicht zur Ausführung.

**Priorität 1:** Queue-Sync fixen und als unabhängigen Prozess absichern.
**Priorität 2:** Zero-Step-Timeout-Rate von 94% adressieren (Planner-Kontext reduzieren).
**Priorität 3:** task-133 approven und task-130/131/132 zur Ausführung bringen.

Ohne Fix des Queue-Sync-Problems wird sich an der Success-Rate nichts ändern, da keine neuen Tasks dispatcht werden können.
