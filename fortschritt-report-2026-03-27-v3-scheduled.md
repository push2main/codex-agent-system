# Fortschrittsbericht — Codex Agent System
**Datum:** 2026-03-27T09:30:00Z, automatisch generiert (scheduled task)

---

## Status-Zusammenfassung

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Tasks gesamt ausgeführt | 526 | — |
| Erfolgsrate gesamt | 15% | Schwach |
| Erfolgsrate letzte 50 | 28% | Aufwärtstrend |
| Erfolgsrate letzte 20 | 10% | Rückfall (Timeout-Burst) |
| Timeout-Rate | 37% | Kritisch |
| Zero-Step-Timeouts | 94% aller Timeouts | Kernproblem |
| Registry | 20 Tasks (12 shelved, 3 failed, 1 completed, 3 queued, 1 pending) |
| Learned Rules | 12/20 (8 Slots frei) | Gesund |
| Pipeline | **BLOCKIERT** seit >39h | Kritisch |
| Strategy Loop | Läuft, aber wirkungslos (Queue Gate blockiert) | Kritisch |

---

## Kerndiagnose: Warum nichts vorangeht

### Der Teufelskreis (neu entdeckt — ROOT CAUSE)

Die bisherigen Reports (v1, v2) beschrieben das Symptom korrekt (Queue leer), aber nicht die tatsächliche Ursache. Hier ist der vollständige Ablauf, der sich **jede Minute** wiederholt:

1. **Strategy-Loop** erkennt: `queues/codex-agent-system.txt` ist 0 Bytes
2. **Strategy-Loop** kopiert alle 3 Einträge von `codex-queue/` nach `queues/` (v30 Guard funktioniert)
3. **Multi-Queue Worker** liest die Queue, versucht für jeden Task ein Lease zu claimen via `claim_task_lease()`
4. **`claim_task_lease` schlägt fehl** mit "task not found" — der Worker kann die Tasks nicht in der Registry matchen
5. **Worker entfernt die Tasks** aus `queues/` und schreibt sie auf die Stale-Blocklist
6. **Ergebnis:** Queue ist wieder 0 Bytes → Schritt 1 beginnt erneut

**Beweis:** Die Stale-Blocklist hat **520 Einträge** — exakt die gleichen 3 Tasks (130, 131, 132), die ca. 173× kopiert und sofort wieder gelöscht wurden. Der Log zeigt jede Minute: `"v30 queue-sync: copied"` gefolgt von `"Removed stale queued task without an actionable registry record"`.

### Warum `claim_task_lease` die Tasks nicht findet

Die wahrscheinlichste Ursache: Das Task-Matching in `claim_task_lease` vergleicht den Queue-Eintrag-Text (z.B. `[self-improve:critical] Improve first-pass success rate -- ...`) mit einem Feld in `tasks.json`, aber das Format stimmt nicht überein. Die Tasks existieren in der Registry als `queued`, aber der Lease-Claim-Algorithmus kann sie nicht zuordnen.

### Sekundärproblem: Strategy-Loop Gate blockiert trotzdem

Selbst wenn die Queue funktionieren würde, zeigt der Log:

```
Queue gate active: success_rate=0.1 queue_size=3(local)/0(global) ... — skipping strategy run
```

Die Strategy-Loop sieht `queue_size=3` (lokal) und blockiert weitere Strategy-Generierung — korrekt. Aber `queue_size=0(global)` zeigt, dass der globale Zähler nicht aktualisiert wird, was ein Symptom des gleichen Problems ist.

---

## Sind die Tasks umsetzbar?

**Ja, die 3 queued Tasks sind inhaltlich gut und korrekt scoped:**

1. **task-130: Improve first-pass success rate** (critical) — `agents/planner.sh`, 1 Datei, klar definiert
2. **task-131: Break retry churn** (high) — `agents/orchestrator.sh`, 1 Datei, klar definiert
3. **task-132: Reduce strategy saturation** (medium) — `scripts/strategy-loop.sh`, 1 Datei, klar definiert

Diese Tasks adressieren die drei wichtigsten Bottlenecks des Systems. Sie scheitern nicht an ihrer Qualität, sondern an der Infrastruktur-Blockade.

---

## Heben wir die Success Rate?

**Langfristig: Ja.** Die Non-Timeout-Erfolgsrate steigt (+6.2pp pro 100 Tasks), Learned Rules sind effektiv, Classification Coverage ist bei 100%.

**Kurzfristig: Nein.** Die Pipeline ist seit 39+ Stunden blockiert. Kein einziger Task wurde in dieser Zeit ausgeführt. Die letzte 20-Task-Erfolgsrate liegt bei 10% — ein Rückfall.

---

## Empfohlene Modifikationen (nach Priorität)

### 1. KRITISCH: `claim_task_lease` Matching fixen

Das ist der **einzige Fix**, der die Pipeline entsperrt. Der Lease-Claim muss die Queue-Einträge korrekt den Tasks in `tasks.json` zuordnen können.

**Konkreter Ansatz:** Das Queue-Eintrag-Format enthält den vollen Task-Text (`[self-improve:critical] Improve first-pass success rate -- ...`). Die `claim_task_lease` Funktion muss diesen Text parsen und den Task-Titel extrahieren, um ihn gegen `tasks.json` zu matchen. Vermutlich wird aktuell ein anderes ID-Format erwartet (z.B. `task-130` statt des vollen Textes).

### 2. HOCH: Stale-Blocklist leeren

Die Blocklist hat 520 Einträge und wächst jede Minute um 3. Nach dem Lease-Fix muss sie geleert werden (`rm codex-logs/queue-stale-blocklist.txt`), da die Blocklist sonst verhindert, dass die reparierten Tasks dispatched werden (Iteration 11 Fix prüft die Blocklist vor dem Dispatch).

### 3. MITTEL: Claude Provider Status prüfen

Der letzte Report erwähnte 1.179× `"claude print failed"`. Alle 3 queued Tasks nutzen Provider `claude`. Selbst nach Queue-Fix könnten sie am Provider scheitern. Die Provider-Konnektivität muss vor dem Queue-Fix verifiziert werden.

### 4. NIEDRIG: Monitoring für den Copy-Delete-Cycle

Die Strategy-Loop sollte erkennen, wenn die gleichen Tasks innerhalb von 10 Minuten 5× kopiert und gelöscht werden, und einen Alert setzen statt still weiterzulaufen.

---

## System-Konfiguration: Was ist gesund, was nicht?

| Komponente | Status | Notizen |
|-----------|--------|---------|
| Learned Rules (12/20) | Gesund | 8 Slots frei, gute Konsolidierung in v30 |
| Provider Routing | Gesund | Korrekte Zuordnung claude/codex |
| Registry Pressure | Gesund | 157KB / 512KB |
| Retry Classification | Gesund | 100% Coverage |
| Self-Improve Gating | Korrekt blockiert | Cooldown aktiv, kein Overload |
| Queue Sync Guard (v30) | **Funktioniert, aber nutzlos** | Copy klappt, Worker löscht sofort |
| `claim_task_lease` | **Defekt** | Task-Matching schlägt fehl |
| Multi-Queue Worker | **Im Leerlauf** | Findet keine claimable Tasks |
| Pipeline | **Blockiert** | 39+ Stunden ohne Task-Ausführung |

---

## Fazit

Das System hat gute Regeln, gut formulierte Tasks und eine gesunde Lerninfrastruktur — aber eine einzige defekte Funktion (`claim_task_lease`) blockiert seit fast 2 Tagen jeglichen Fortschritt. Die v29 und v30 Fixes adressierten das Symptom (leere Queue-Datei), nicht die Ursache (Worker löscht Tasks sofort nach dem Kopieren, weil Lease-Matching fehlschlägt).

**Priorität 1:** `claim_task_lease` debuggen und das Task-ID-Matching zwischen Queue-Einträgen und Registry fixen.
**Priorität 2:** Stale-Blocklist leeren und Provider-Konnektivität sicherstellen.
**Priorität 3:** Erst danach die 3 Improvement-Tasks (130–132) ausführen lassen.
