# Fortschrittsbericht — 29. März 2026 (Scheduled, v2)

## Systemstatus: DEADLOCK — Pipeline seit 5 Tagen inaktiv

Seit dem 25. März wurde kein einziger Task erfolgreich abgeschlossen. Das System befindet sich in einem mehrschichtigen Deadlock, der ohne manuellen Eingriff nicht lösbar ist.

---

## Kernmetriken

| Metrik | Wert | Bewertung |
|---|---|---|
| Total Tasks | 587 | nur Self-Improve-Versuche seit 25.03. |
| All-time Success Rate | 13% | unverändert |
| Recent Success Rate (letzte 50) | **0%** | seit 5+ Tagen |
| First-Pass Success | **0%** | kein einziger Task auf Anhieb erfolgreich |
| Timeout-Rate | 35% (206 Events) | 91% davon Zero-Step (Planner-Overhead) |
| Pipeline stale seit | 25. März 06:24 UTC | ~4,5 Tage |
| Running / Queued Tasks | 0 / 0 | Pipeline steht still |
| Task Registry | 9 Tasks (6 shelved, 3 failed) | kein aktiver Task |
| Zombie Tasks | 20 (166 verschwendete Slots) | unverändert |
| Self-Improve | PAUSIERT seit 28.03. | `self-improve-paused` File aktiv |
| Retry Churn | Aktiver Alert | Loop-Effort bei 3 Tasks |
| Improvement Velocity | -0.69pp / 100 Tasks | System verschlechtert sich |

### Success Rate Verlauf

```
Tasks   1- 50:  34%  ← früher Bereich, einfache Tasks
Tasks  51-100:   4%
Tasks 101-150:   6%
Tasks 151-200:   4%
Tasks 201-250:  16%
Tasks 251-300:  10%
Tasks 301-350:  14%
Tasks 351-400:  12%
Tasks 401-450:  22%
Tasks 451-500:  26%  ← historisches Maximum
Tasks 501-550:  10%  ← Regression
Tasks 551-587:   0%  ← seit ~5 Tagen, Totalausfall
```

---

## Sind die bisherigen Tasks umsetzbar?

### Nein — in der aktuellen Konfiguration nicht.

**Task Registry (9 Tasks):** Alle 9 Tasks sind entweder shelved (6) oder failed (3). Kein einziger ist in einem ausführbaren Zustand. Die letzten 6 Failures waren durchgängig `review_rejection` — der Planner erzeugt zu lange Step-Beschreibungen (>600 Zeichen), die vom Reviewer abgelehnt werden.

**Queue (codex-queue/):** 3 Tasks (130, 131, 132) warten seit dem 24. März. Sie werden **nie ausgeführt**, weil:
- Tasks in `codex-queue/*.json` abgelegt werden
- Workers aber aus `queues/codex-agent-system.txt` lesen
- Diese Datei ist **leer**
- → Kritischer Queue-Directory-Mismatch

**Provider-Performance:**

| Provider | Success Rate | Tasks | Status |
|---|---|---|---|
| claude-code | 62.5% | 8 | Historisch best, wird nicht genutzt |
| codex-cli | 28.4% | diverse | Nicht mehr aktiv |
| claude (aktuell) | 0-17% | 196 | Aktiver Provider, sehr schlecht |
| codex (aktuell) | 12-20% | 200+ | Aktiver Provider, schlecht |

Die historisch besten Provider (`claude-code` mit 62.5%) werden nicht mehr geroutet.

---

## Hebt sich die Success Rate?

**Nein. Klare, anhaltende Verschlechterung.**

- Gesamttrend: NOT IMPROVING (-4.0pp Delta erste vs. zweite Hälfte)
- Non-Timeout Velocity: -3.71pp pro 100 Tasks
- Bestes historisches Rule-Set (`afdc1a2d`): 63.6% bei 11 Tasks — aktuelle Rule-Sets: 0%
- Learner-Rate: nur 5 Rules aus 587 Tasks (0.85 pro 100 Tasks)

---

## Diagnose: 5 verkettete Blocker

1. **Queue-Mismatch (P0):** Tasks landen in `codex-queue/`, Workers lesen aus `queues/`. Kein Task kann ausgeführt werden.

2. **Self-Improve pausiert (P0):** `self-improve-paused` File blockiert alle automatischen Reparaturversuche. Ohne manuelles Entfernen kein Fortschritt.

3. **Review-Rejection-Loop (P0):** Planner erzeugt zu verbose Step-Beschreibungen → Reviewer lehnt ab → 100% Failure-Rate. Fix in planner.sh wurde angeblich applied, aber nie verifiziert.

4. **Provider-Regression (P1):** Die aktuell gerouteten Provider (`claude`, `codex`) haben dramatisch schlechtere Erfolgsraten als `claude-code`. Das Routing muss korrigiert werden.

5. **Rule-Regression (P1):** Aktuelle Regeln performen bei 0%. Historisch beste Regeln (63.6%) wurden durch Self-Improve-Iterationen verschlechtert.

---

## Empfohlene Modifikationen

### Sofort erforderlich (manueller Eingriff)

**1. Queue-Directory-Mismatch fixen**
- Option A: Workers auf `codex-queue/` umstellen
- Option B: Queue-Writer auf `queues/codex-agent-system.txt` umstellen
- Option C: Sync-Bridge `codex-queue/*.json → queues/*.txt`
- → Dies ist der #1 Blocker. Ohne Fix bewegt sich nichts.

**2. Canary-Task manuell dispatchen**
- Einen minimalen Test-Task direkt in `queues/codex-agent-system.txt` platzieren
- Beispiel: `Add comment to line 1 of README.md`
- Damit verifizieren, ob die Execution-Chain überhaupt noch funktioniert

**3. Review-Rejection beheben**
- `MAX_STEP_CHARS` in planner.sh auf 400 reduzieren (aktuell vermutlich 600)
- Alternativ: Reviewer-Threshold erhöhen
- Den angeblichen Fix aus dem 28.03. Shelve-Kommentar verifizieren

**4. Self-Improve kontrolliert re-enablen**
- `codex-logs/self-improve-paused` entfernen
- Aber mit Scope-Einschränkung: max 1 File, max 3 Steps, Timeout 300s
- Nur nach erfolgreicher Canary-Ausführung

### Nach Pipeline-Entsperrung

**5. Provider-Routing auf `claude-code` umstellen**
- Für `code_quality` und `testing` Kategorien
- Historisch 62.5% vs. 0% bei aktuellen Providern

**6. Rule-Set Rollback**
- Auf den Stand von Rule-Set `afdc1a2d` zurücksetzen (63.6% Success Rate)
- Von dort kontrolliert iterieren statt blind Self-Improve laufen zu lassen

**7. Gesamt-Prompt-Budget einführen**
- Aktuell: MEMORY_CONTEXT, SOURCE_CONTEXT, SIMILAR_TASKS je 8KB (= bis zu 24KB)
- Empfehlung: Gesamtbudget 12KB für kombinierten Prompt
- Reduziert Zero-Step-Timeouts (91% aller Timeouts)

### Langfristig

**8. Automatischer Canary:** Bei stale >12h automatisch Minimal-Task dispatchen
**9. Pending-Approval-Timeout:** Auto-Shelve nach 6h
**10. Learner stärken:** 5 Rules aus 587 Tasks ist zu wenig — Accumulation-Rate verdoppeln

---

## Prognose

**Ohne Eingriff:** System bleibt auf unbestimmte Zeit bei 0% Recent Success Rate. Die Strategy-Loop dreht im Leerlauf (stale → escape → paused → repeat).

**Mit den 4 P0-Fixes:** Realistische Chance, die Pipeline in 1-2 Tagen wieder auf 10-15% Recent Success zu bringen. Danach kann das System mit Provider-Routing-Fix und Rule-Rollback potenziell das historische Maximum (26%) wieder erreichen.

**Kritischer Pfad:** Queue-Fix → Canary-Task → Review-Fix → Self-Improve re-enable → Provider-Routing → Rule-Rollback
