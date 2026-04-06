# Self-Learning Audit — 2026-04-03

## Diagnosis: Lernt das System effizient dazu?

### Ja, aber mit klaren Schwächen

**Positiv (das System wird messbar besser):**
- Iteration trend zeigt dramatische Verbesserung: 4% → 97% Success Rate (tasks 51-784)
- Recent success rate: 98% (letzte 50 Tasks)
- First-pass success rate: 79%
- Improvement velocity: +10.4pp pro 100 Tasks
- Retry classification coverage: 100% (war 24% — massiv verbessert)

**Probleme (vor diesem Audit):**

| Problem | Auswirkung | Status |
|---------|-----------|--------|
| Nur 4 generische Learned Rules bei 784 Tasks | Lernen stagniert — Rate 0.51/100 Tasks | **BEHOBEN** → 12 Regeln, Rate 1.53/100 |
| Kandidaten-Regeln bleiben in rules-candidate.md stecken | 5 evidenzbasierte Regeln nie promotet | **BEHOBEN** → alle 5 promotet |
| Fallback-Learner produziert nur generische Regeln | Bei LLM-Ausfall kein kontextabhängiges Lernen | **BEHOBEN** → Fallback nutzt jetzt Failure-Category |
| review_rejection = 44% aller Retries (64/146) | Keine Regel adressiert die häufigste Fehlerart | **BEHOBEN** → Neue Regel + Scoped Rule für Reviewer |
| External Signals stale seit 8 Tagen | System reagiert nicht auf Upstream-Änderungen | Bekannt, auto_refresh=false |
| Automation Memory fehlt (continuity_status=missing) | Cross-Session-Lernen unterbrochen | Strukturell — braucht Codex-Installation |
| 20 Zombie Tasks verschwenden 166 Slots | Metriken verzerrt, All-time Rate gedrückt | Zombie-Guard existiert, filtert korrekt |

## Durchgeführte Fixes

1. **rules.md**: 4 → 12 Regeln (8 neue evidenzbasierte Regeln hinzugefügt)
2. **prompt-rules.md**: Synchronisiert mit den neuen Regeln
3. **CLAUDE.md**: Learned Rules Section aktualisiert mit allen 12 Regeln
4. **learner.sh**: Fallback-Funktion macht jetzt kontextabhängige Regeln basierend auf der dominanten Failure-Category
5. **scoped-rules.json**: Neue Scoped Rules für reviewer.sh, evaluator.sh und planner.sh
6. **metrics.json**: learning_rules_count und learning_rate aktualisiert
7. **rules-candidate.md**: Bereinigt — alle Kandidaten promotet

## Retry-Failure-Verteilung (alle 146 Records)

- review_rejection: 64 (44%) ← **jetzt mit Regel adressiert**
- timeout: 42 (29%) ← **Step-Duration-Tracking-Regel**
- step_not_completed: 18 (12%)
- missing_environment: 12 (8%) ← **Environment-Blocked-Regel**
- missing_dependency: 4 (3%)
- test_failure: 2
- andere: 4

## Empfehlungen für nächste Iteration

1. **auto_refresh für External Signals aktivieren** — Upstream-Änderungen werden sonst nie bemerkt
2. **Knowledge.json kompaktieren** — 199 Einträge, Duplikate wahrscheinlich
3. **review_rejection Root-Cause-Analyse** — 44% ist sehr hoch, die neue Diff-Hint-Regel muss auf Wirksamkeit geprüft werden
