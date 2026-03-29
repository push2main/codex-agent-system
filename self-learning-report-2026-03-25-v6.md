# Self-Learning Analysis Report — 2026-03-25 v6

## Frage: Lernt das System effizient dazu? Wird es bei jeder Iteration messbar besser?

### Antwort: Teilweise ja, aber drei strukturelle Probleme bremsen den Lernfortschritt

Das System zeigt einen **positiven Trend** (success rate stieg von 4-6% auf 22-28% in den letzten 100 Tasks), aber drei Code-Level-Probleme verhindern effizientes Lernen:

## Diagnose

| Metrik | Wert | Problem |
|--------|------|---------|
| All-time success rate | 15% | Zu niedrig |
| Recent success rate (letzte 50) | 28% | Verbesserung erkennbar |
| First-pass success rate | 55% | Akzeptabel |
| Zero-step timeout rate | **94%** | **Kritisch** — Planner verbraucht das gesamte Timeout-Budget |
| Registry pressure | 1.18 MB | **Kritisch** — superheld-Projekt allein 1.08 MB |
| Loop effort waste | 70 Tasks, 163 extra Versuche | Signifikant |
| Zombie tasks | 17 Tasks, 151 verschwendete Slots | 29% aller Runs verschwendet |
| Strategy follow-ups für missing_env | Ungeblockt | Erzeugt unlösbare Tasks |

## Durchgeführte Fixes

### Fix 1: Planner Timeout 90s → 60s
**Datei:** `agents/orchestrator.sh`
**Problem:** 94% aller Timeouts sind Zero-Step-Timeouts — der Planner verbraucht das gesamte Budget.
**Lösung:** Planner-Cap von 90s auf 60s reduziert. Erfolgreiche Plans brauchen typisch <30s; die extra 30s verzögerten nur die Fehlererkennung.

### Fix 2: Strategy Non-Retryable Failure Filter
**Datei:** `agents/strategy.sh`
**Problem:** Strategy generierte Follow-up-Tasks für Failures mit `missing_environment`, `missing_platform` und `timeout` — diese scheitern immer wieder am gleichen Umgebungsproblem.
**Lösung:** Neue Funktion `task_last_failure_kind()` + Filter in `prioritized_failed_candidates()`. Tasks mit nicht-behebbaren Failure-Kinds werden übersprungen.

### Fix 3: Elapsed-Time Guard im Step Loop
**Datei:** `agents/orchestrator.sh`
**Problem:** Der Orchestrator konnte still in ein Timeout laufen ohne dass klar war, wo die Zeit verbraucht wurde.
**Lösung:** Vor jedem Step wird geprüft, ob >80% des Timeout-Budgets verbraucht sind. Falls ja, wird sofort abgebrochen mit einer klassifizierbaren Fehlermeldung (`failure_kind=timeout`).

### Fix 4: Rules & CLAUDE.md aktualisiert
**Dateien:** `codex-learning/rules.md`, `CLAUDE.md`
**Problem:** Dokumentation war nicht synchron mit den Code-Änderungen.
**Lösung:** Neue Regeln dokumentiert, System Health Sektion aktualisiert.

## Erwartete Auswirkungen

1. **Weniger Zero-Step-Timeouts:** Planner-Timeout 60s statt 90s bedeutet schnelleres Fail-Fast
2. **Weniger verschwendete Slots:** Strategy generiert keine Follow-ups mehr für unlösbare Environment-Failures
3. **Bessere Fehlerklassifikation:** Elapsed-Time Guard produziert klare, klassifizierbare Timeout-Fehler
4. **Schnellerer Lernzyklus:** Weniger Rauschen in den Metriken = klarere Signale für den Learner

## Verbleibendes Problem: Registry Pressure

Die superheld-Registry (1.08 MB) ist nicht aus diesem Sandbox erreichbar (`/Users/benediktpoller/code/push2main.io/superheld/.codex-agent/tasks.json`). Das `compact-registry.sh` Script existiert und kann per-Projekt compacten, muss aber lokal auf dem Host ausgeführt werden:

```bash
cd ~/code/codex-agent-system && bash scripts/compact-registry.sh
```

## Validierung

- `bash -n orchestrator.sh` → OK
- `ast.parse(strategy.sh Python)` → OK
- Alle 4 Änderungen durch grep verifiziert
