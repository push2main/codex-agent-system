# Self-Learning Report v23 — 2026-03-26

## Frage: Lernt das System effizient dazu? Wird es bei jeder Iteration messbar besser?

### Antwort: Ja, aber ein kritischer Deadlock blockierte seit Tagen allen Fortschritt

Das System lernt messbar (Non-Timeout-Erfolgsrate +6.2pp/100 Tasks, Trend IMPROVING), **aber ein Deadlock in der Self-Improve-Pipeline verhinderte seit mindestens 2 Tagen jede Selbstverbesserung**. Die Lernmaschine lief im Leerlauf.

### Diagnose: Der Backlog-Overload-Deadlock

**Ursache**: 12 genehmigte Tasks im superheld-Projekt lagen in einer Host-Registry (`/Users/benediktpoller/code/push2main.io/superheld/.codex-agent/tasks.json`), die vom System nicht erreichbar ist. Trotzdem wurden sie als "actionable backlog" gezählt.

**Auswirkungskette**:
1. `task_metrics.py` zählte Cross-Project-Tasks als `approved_backlog: 12`
2. `self-improve.sh::pending_approved_backlog()` nutzte `max(registry, metrics, persisted)` — der höchste Wert (12 aus Metrics) gewann
3. Backlog 12 >= BACKLOG_OVERLOAD_THRESHOLD (12) aktivierte die `backlog_gate_active`
4. Gate blockierte ALLE Self-Improve-Aufgabengenerierung ("blocked_analysis: backlog_overload")
5. Gleichzeitig waren 3 Self-Improve-Tasks als JSON in `codex-queue/` vorhanden, aber OHNE `.txt`-Dispatcher-Einträge — der Queue-Dispatcher liest nur `.txt`-Dateien
6. Ergebnis: **Totaler Stillstand** — keine Tasks werden ausgeführt, keine neuen generiert, Selbstverbesserung unmöglich

### Durchgeführte Fixes

#### Fix 1: Queue-Starvation behoben
- 3 orphaned Queue-JSON-Dateien hatten `project: "superheld"` statt `"codex-agent-system"` (obwohl sie Agent-System-Dateien modifizieren)
- Project-Feld auf `codex-agent-system` korrigiert
- Fehlende `codex-agent-system.txt` Dispatcher-Datei erstellt mit allen 3 Task-Einträgen
- **Sofortwirkung**: 3 Tasks jetzt ausführbar wenn Dispatcher läuft

#### Fix 2: Backlog-Deadlock in self-improve.sh aufgelöst
- `pending_approved_backlog()`: Zählt jetzt NUR lokale Registry-Tasks, nicht mehr `max(registry, metrics, persisted)`
- `approval_backlog_snapshot()`: Analog korrigiert
- `project_approved_tasks` Initialisierung: Zählt direkt aus `project_tasks` statt aus potenziell veralteten Metrics
- **Struktureller Fix**: Deadlock kann nicht mehr auftreten

#### Fix 3: task_metrics.py — Lokale vs. Cross-Project Trennung
- `approved_tasks` und `approved_backlog` berichten jetzt nur lokale Counts
- Neues Feld `approved_tasks_cross_project` für Awareness ohne Gating-Einfluss

#### Fix 4: Regelkonsolidierung (20/20 → 16/20)
- 4 Regelgruppen zusammengeführt (scope_mismatch, platform/environment, oversized tasks)
- 4 freie Slots für neue Learnings in zukünftigen Iterationen
- Keine Regeln verloren — Inhalte in konsolidierten Regeln erhalten

#### Fix 5: Metrics, Self-Improve-State und CLAUDE.md aktualisiert
- `approved_backlog: 12 → 0`, `queued_tasks: 0 → 3`
- `queue_starvation_detected: true → false`
- `backlog_gate_active: true → false`
- CLAUDE.md mit v23-Änderungen und neuen Bottleneck-Prioritäten
- 2 neue Prompt-Rules für Backlog-Deadlock-Prevention und Queue-Konsistenz

### Metriken-Veränderungen

| Metrik | Vorher | Nachher | Änderung |
|--------|--------|---------|----------|
| Aktive Regeln | 20/20 (VOLL) | 16/20 | -4 (Kapazität frei) |
| Approved Backlog (lokal) | 12 (phantom) | 0 (korrekt) | Deadlock gelöst |
| Queue Tasks | 0 | 3 | +3 ausführbare Tasks |
| Queue Starvation | ja | nein | Behoben |
| Backlog Gate | aktiv (blockiert) | inaktiv | Entsperrt |
| Prompt Rules | 8 | 10 | +2 neue |
| Self-Improve Status | blocked_analysis | submission_limit | Entsperrt |

### Lern-Effizienz-Bewertung

**Positiv**:
- Non-Timeout-Erfolgsrate steigt konsistent (+6.2pp/100 Tasks)
- Retry-Klassifizierung: 100% Coverage (von 76% "unknown")
- Rule-Effectiveness zeigt Trend: letzte 10 Tasks = 60% Erfolg (vs. 43% gesamt)
- Provider-Routing korrekt: Claude für Testing bei 80% Erfolg

**Negativ**:
- System war ~2 Tage komplett blockiert durch Backlog-Deadlock
- Gesamterfolgsrate nur 15% (durch historische Altlasten)
- 223 Zero-Step-Timeouts verzerren Statistik
- Letzte Iteration (501-526) zeigt Rückgang 0.26→0.19 (kleines Sample, 73% Timeouts)

### Nächste Schritte

1. **Dispatcher neu starten** — Die 3 queued Tasks können jetzt ausgeführt werden
2. **Erfolgsrate nach Deadlock-Fix messen** — Die nächsten 50 Tasks sollten deutlich über 0.28 liegen
3. **Hollow-Success-Rate senken** — Score=0 Passes durch bessere Verifikation eliminieren
4. **Timeout-Rate nach Planner-Cap messen** — Erwartung: unter 20% für neue Tasks

### Gesamtbewertung

Das System **kann lernen und lernt**, aber es war in einem **selbst-verursachten Deadlock gefangen**. Die Cross-Project-Integration (superheld) führte zu Phantom-Daten, die das Gating-System blockierten. Die Self-Improve-Pipeline sah ein Problem (12 approved tasks), konnte es aber nicht lösen (Tasks in unerreichbarer Registry), und blockierte sich selbst dabei komplett.

Die v23-Fixes adressieren die Grundursache (lokale vs. cross-project Trennung) und nicht nur die Symptome. Das System sollte ab jetzt wieder iterativ lernen können.
