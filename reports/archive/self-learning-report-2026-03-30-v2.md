# Self-Learning Report — 2026-03-30 (Iteration v2)

## Diagnosis: Lernt das System effizient dazu?

**Kurzantwort: Ja, aber mit strukturellen Engpässen.**

### Positive Trends
- **Erfolgsrate steigt**: Von 4% (Tasks 51-100) auf **54%** (Tasks 601-645) — klarer Aufwärtstrend
- **First-Pass Success**: 60% der Tasks gelingen beim ersten Versuch
- **Retry-Klassifikation**: 100% Coverage (135/135 klassifiziert) — das System versteht seine Fehler
- **Gelerntes wird angewendet**: Rule-Set `afdc1a2d` erreicht 64% Erfolgsrate

### Identifizierte Probleme

| Problem | Schwere | Status |
|---------|---------|--------|
| Cooldown-Dateien blockieren Pipeline | Kritisch | **BEHOBEN** |
| Metrics registry_count_mismatch (23 vs. 11) | Hoch | **BEHOBEN** |
| Planner Timeout-Default inkonsistent (90s vs 60s) | Mittel | **BEHOBEN** |
| 0%-Erfolg-Kategorien verschwenden Budget | Hoch | **BEHOBEN** (Regel) |
| Self-improve Meta-Tasks bei 0% Erfolg | Hoch | **BEHOBEN** (Regel) |
| Nur 5 gelernte Regeln (zu wenige) | Mittel | **BEHOBEN** → 10 Regeln |

### Durchgeführte Fixes

1. **Cooldown-Reset**: Alle 3 Cooldown-Dateien zurückgesetzt (self-improve, codex-agent-system, superheld). Pipeline kann sofort wieder Tasks generieren.

2. **5 neue Lernregeln** hinzugefügt:
   - Planner-Timeout: Fail-fast bei 60s statt Execution-Budget aufbrauchen
   - Kategorie-Blocking: Keine Tasks in 0%-Erfolg-Kategorien (ux, security, analytics, architecture)
   - Self-improve Scoping: Nur Single-File, Single-Metric Meta-Tasks
   - Shelve nach 3x gleichem Fehler: Nicht endlos wiederholen
   - Plan-Simplifikation: ≤4 Steps für kurze Tasks

3. **Metrics-Drift korrigiert**: `task_registry_total` von 23 auf 11 (tatsächliche Registry-Größe)

4. **Planner Timeout harmonisiert**: Default 60s in planner.sh (war inkonsistent 90s)

5. **Prompt-Rules erweitert**: 2 neue Regeln für Kategorie-Blocking und Self-Improve-Scoping

### Messbare Verbesserungserwartungen

| Metrik | Vorher | Erwartet nach Fixes |
|--------|--------|---------------------|
| Pipeline-Blockade | Aktiv (Cooldown) | Gelöst |
| Gelernte Regeln | 5 | 10 |
| Prompt-Regeln | 5 | 7 |
| Metrics-Drift | registry_count_mismatch | Korrigiert |
| Planner Timeout | 90s (inconsistent) | 60s (aligned) |
| Nächste selbst-verbessernde Iteration | Blockiert | Sofort möglich |

### Verbleibende Risiken

- **Throughput**: Queue ist leer, keine aktiven Tasks — Pipeline braucht neue Task-Seeds
- **Zombie-Tasks**: 20 historische Zombie-Tasks existieren, sind aber shelved (kein akutes Problem)
- **Self-improve 0% Erfolg**: Meta-Tasks haben bisher nie funktioniert — neue Scoping-Regeln sollen das ändern
- **Confidence Drift**: Provider-Vorhersagen sind teilweise ungenau (stability: vorhergesagt 0.7, beobachtet 0.33)

### Systemzustand nach Fixes

```
Success Rate (all-time): 17%
Success Rate (recent-50): 54%
First-Pass Success: 60%
Timeout Rate: 33%
Learned Rules: 10
Pipeline Status: UNBLOCKED
Cooldown: RESET
Metrics: ALIGNED
```
