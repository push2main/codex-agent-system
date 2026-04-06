# Self-Learning Report — Iteration 16
**Date:** 2026-03-26T06:15:00Z
**Type:** Scheduled task (autonomous)

## Leitfrage: Lernt das System effizient dazu?

**Ja — das Lernsignal ist stark, aber die Pipeline war 22+ Stunden blockiert.**

### Effizienz-Metriken

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Gesamte Erfolgsrate | 15% | Niedrig (historisch belastet) |
| Letzte 50 Tasks | 28% | Deutlich verbessert |
| Non-Timeout-Erfolgsrate | 28% (287 Tasks) | **Echtes Lernsignal** |
| Non-Timeout-Velocity | +6.8 pp/100 Tasks | **4× stärker als Gesamt** |
| Gesamt-Velocity | +1.73 pp/100 Tasks | Positiv |
| Trend-Fenster | 4% → 23-26% | **Klar aufwärts** |
| Zero-Step-Timeouts | 94% aller Timeouts | Hauptproblem |
| Pipeline-Stillstand | 22+ Stunden | **Kritisch** |

### Identifizierte Probleme

**Problem 54: Auto-Approval nur im Cooldown-Block erreichbar.**
Die Iteration 15 platzierte Auto-Approval in `if [ "$now_epoch" -lt "$cooldown_until" ]`. Ohne aktiven Cooldown (keine kürzlichen Timeouts = keine Cooldown-Datei) wurde der Block nie betreten. Die 4 `pending_approval`-Tasks warteten 22+ Stunden auf Genehmigung, die nie kam.

**Problem 55: Claude-Provider komplett defekt (1045+ Fehler).**
Tasks mit `execution_provider: "claude"` scheitern in <2 Sekunden. Task-002 wurde auto-approved, scheiterte aber sofort (6 Sekunden inklusive Retry). Provider-Routing berücksichtigt Provider-Gesundheit nicht.

**Problem 56: rules.md nicht synchron mit CLAUDE.md.**
Nur 5 generische Regeln statt der 20+ operativen Regeln aus Iterationen 9-15.

### Durchgeführte Fixes

1. **Auto-Approval jetzt UNCONDITIONAL** in strategy-loop.sh — läuft als erster Schritt jedes Zyklus, nicht mehr im Cooldown-Block
2. **Task-004 manuell auto-approved** mit `codex`-Provider statt `claude` — Pipeline unblockiert
3. **Diagnostik-Logging** in lib.sh reconcile und strategy-loop Auto-Approval hinzugefügt
4. **Provider-Routing** für verbleibende pending Tasks von claude auf codex umgestellt
5. **rules.md aktualisiert** mit 3 neuen operativen Regeln
6. **CLAUDE.md aktualisiert** mit Iteration 16 Assessment

### Architekturelles Muster

Iterationen 9-16 zeigen ein wiederkehrendes Meta-Muster: **Recovery-Mechanismen werden in bedingte Blöcke platziert, die genau dann inaktiv sind, wenn Recovery benötigt wird.**

- Iteration 9: Timeout-Crisis-Gate blockiert neue Tasks → keine neuen Tasks = Gate nie aktualisiert
- Iteration 10: Queue-Gate blockiert Strategy → keine Tasks = Gate bleibt aktiv
- Iteration 13: Auto-Approval im Reconcile → Reconcile-Writes werden überschrieben
- Iteration 15: Auto-Approval im Cooldown-Block → kein Cooldown = kein Auto-Approval
- **Iteration 16: Neues Prinzip: RECOVERY MUSS UNCONDITIONAL SEIN**

### Nächste Prioritäten

1. Claude-Provider auf Host-Seite untersuchen (warum 1045+ Fehler?)
2. Prüfen ob Task-004 erfolgreich mit codex-Provider ausgeführt wird
3. Provider-Health-Check in Routing-Logik einbauen (>100 Fehler → automatisch wechseln)
4. Timeout-Rate reduzieren (38% aller Tasks) — Haupthebel für Gesamtverbesserung
