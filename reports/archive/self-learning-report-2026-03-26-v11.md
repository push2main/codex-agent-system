# Self-Learning Report — Iteration 11
**Date:** 2026-03-26T00:15:00Z
**Trigger:** Scheduled task (self-learning)

## Question: Lernt das System effizient dazu?

**Ja — das Lernen selbst funktioniert gut.** Die Non-Timeout-Erfolgsrate von 28% mit +6.8pp/100 Tasks Lerngeschwindigkeit bestätigt echtes Improvement. Die First-Pass-Success-Rate liegt bei 55%. Das System lernt messbar besser, wenn es nicht durch Timeouts oder Infrastructure-Bugs blockiert wird.

**Aber: Die Pipeline steht seit 17+ Stunden komplett still.** Nicht wegen schlechtem Lernen, sondern wegen zwei Infrastructure-Bugs.

## Identifizierte Probleme

### Problem 37: Queue Rehydration Infinite Loop (KRITISCH)
12 Superheld-Projekt-Tasks wurden in die codex-agent-system Queue geschrieben (falsches Projekt). Der Queue-Worker versucht sie zu leasen, findet sie nicht im lokalen Registry, entfernt sie — und der Reconciler fügt sie sofort wieder hinzu. Diese Endlosschleife lief 17+ Stunden mit ~100 Einträgen/Minute, erzeugte 200K+ Zeilen system.log, und verhinderte jede nützliche Arbeit.

**Ursache:** `read_registry()` liest Tasks aus allen Projekt-Registries (inkl. Superheld), aber die Projekt-Zuweisung defaultet auf "codex-agent-system" wenn der Task kein "project"-Feld hat.

### Problem 38: Strategy-Loop Daemon nicht aktiv
Kein einziger Strategy-Loop Log-Eintrag seit 2026-03-25T00:32:42Z. Der Daemon ist entweder gecrasht oder wurde nicht neu gestartet. Alle Iteration-10-Fixes (Staleness Escape, Cross-Project Isolation) sind im Code deployed, werden aber nie ausgeführt.

### Problem 39: Cross-Project Queue Contamination
Grundursache von Problem 37. Die `reconcile_approved_registry_tasks_to_queue()`-Funktion liest aus allen Registries, tagged aber Tasks nicht mit ihrem Quell-Projekt.

## Durchgeführte Fixes

1. **`read_registry()` Cross-Project Tagging** (lib.sh): Tasks aus Cross-Project-Registries bekommen jetzt `_source_project` aus project.json injiziert.

2. **Queue Rehydration Projekt-Fallback** (lib.sh): Die Projekt-Zuweisung nutzt jetzt `_source_project` als Fallback vor dem Default "codex-agent-system".

3. **Stale-Task Blocklist** (lib.sh + multi-queue.sh): Tasks die als "stale" entfernt werden, kommen auf eine Blocklist und werden nicht re-added. Blocklist wird bei Daemon-Neustart geleert.

4. **Queue Cleanup**: codex-agent-system Queue-Datei geleert, Blocklist mit den 12 betroffenen Tasks vorausgefüllt.

## Metriken

| Metrik | Wert | Trend |
|--------|------|-------|
| Gesamt-Tasks | 522 | Eingefroren (Pipeline still) |
| Erfolgsrate (gesamt) | 15% | — |
| Erfolgsrate (recent-50) | 28% | — |
| Non-Timeout Erfolgsrate | 28% | +6.8pp/100 ↑ |
| First-Pass Success | 55% | — |
| Timeout-Rate | 36% | — |
| Lernregeln | 20 | Am Maximum |
| Diagnostik-Abdeckung | 100% | — |
| Lokales Registry | 48KB | Gesund |
| Pipeline stale seit | 2026-03-25T07:27Z | 17+ Stunden |
| Queue-Loop Einträge | ~200K+ | Behoben |

## Bewertung

Das Lernsystem funktioniert effizient — das bestätigen die Velocity-Metriken konsistent seit mehreren Iterationen. Das Problem liegt nicht beim Lernen, sondern bei der operativen Infrastruktur:

1. **Cross-Project Isolation fehlte** komplett in der Queue-Schicht (jetzt gefixt)
2. **Daemon-Supervision fehlt** — wenn strategy-loop stirbt, gibt es keinen Watchdog

Die Iteration-10-Fixes waren logisch korrekt, konnten aber nie wirken weil der Strategy-Loop Daemon nicht lief. Iteration 11 behebt den Queue-Bug und räumt auf. Der Strategy-Loop Daemon muss auf dem Host neu gestartet werden.

## Nächste Prioritäten

1. Host-seitiger Neustart des Strategy-Loop Daemons (tmux/agentctl)
2. Validieren dass Superheld-Tasks korrekt in superheld.txt Queue landen
3. Watchdog/Process-Supervision für Strategy-Loop implementieren
