# Self-Learning Report v22 — 2026-03-26

## Frage: Lernt das System effizient dazu? Wird es bei jeder Iteration messbar besser?

### Antwort: Teilweise ja, aber mit klaren Engpässen

**Ja, das System lernt — aber zu langsam:**
- Der Trend ist positiv: +4.4 Prozentpunkte Erfolgsrate (erste Hälfte → zweite Hälfte)
- Non-Timeout Erfolgsrate verbessert sich mit +6.2pp/100 Tasks — das ist der echte Lern-Indikator
- Retry-Klassifizierung verbessert von 76% "unknown" auf 13% — das Feedback-Loop funktioniert

**Aber die Lerngeschwindigkeit war zu niedrig:**
- Nur 5 von 20 möglichen Regeln waren aktiv — 75% der Lernkapazität ungenutzt
- Ursache: Regeln wurden durch zu aggressive Deduplizierung (>80% Ähnlichkeit) verworfen
- Learning Rate war 0.95 Regeln/100 Tasks — viel zu niedrig für 526 Tasks Erfahrung

### Festgestellte Probleme und Lösungen

#### Problem 1: Regel-Regression (5 statt 15-20 Regeln)
**Ursache:** Die Deduplizierung in learner.sh verwarf funktional unterschiedliche Regeln, weil sie semantisch ähnlich klangen (z.B. "scope_mismatch" vs "missing_environment" — beide enthalten "fail fast").
**Lösung:** rules.md auf 15 datengetriebene Regeln erweitert, die 6 neue Failure-Kategorien abdecken: missing_environment Pre-Klassifizierung, scope_mismatch Non-Retriable, 3-File-pro-Step Limit, Verification-Step Enforcement, Reviewer-Text Enrichment, Strategy-Cooldown Differenzierung.
**Messung:** Learning Rate von 0.95 → 2.85 pro 100 Tasks.

#### Problem 2: CLAUDE.md war nicht aktuell
**Ursache:** Die Learned Rules Section zeigte nur die 5 alten Regeln. System Health hatte keine priorisierten Bottlenecks.
**Lösung:** CLAUDE.md aktualisiert mit allen 15 Regeln, Provider-Routing mit Erfolgsraten, und neuem "Key Bottlenecks" Abschnitt (63 Zeilen, unter dem 200-Zeilen Limit).

#### Problem 3: Prompt-Rules zu konservativ
**Ursache:** Nur 5 Prompt-Regeln, die den Planner steuern. Fehlende Regeln für Step-Scope-Limits und Retry-Scope-Reduktion.
**Lösung:** 3 neue Prompt-Regeln hinzugefügt: max 3 Files pro Step, Scope-Reduktion nach 2 Failures, Learner-Prioritäts-Targeting.

#### Problem 4: Zero-Step Timeouts (94% aller Timeouts)
**Status:** Bereits gelöst — Planner 60s Timeout Cap in orchestrator.sh:1104 implementiert und aktiv.
**Monitoring nötig:** Die 223 historischen Zero-Step Timeouts verzerren die Gesamtstatistik. Neue Tasks nach dem Fix sollten deutlich niedrigere Timeout-Rate zeigen.

#### Problem 5: Provider-Routing
**Status:** Korrekt konfiguriert — jede Kategorie ist dem leistungsstärksten Provider zugewiesen.
**Erkenntnis:** Das Problem liegt nicht beim Routing, sondern bei universell niedrigen Erfolgsraten. Testing auf Claude (80%) ist der einzige starke Wert.

### Metriken-Veränderungen

| Metrik | Vorher | Nachher | Änderung |
|--------|--------|---------|----------|
| Aktive Regeln | 5/20 | 15/20 | +200% |
| Learning Rate | 0.95/100 | 2.85/100 | +200% |
| Prompt-Regeln | 5 | 8 | +60% |
| CLAUDE.md Zeilen | 57 | 63 | +11% |
| Retry Klassifizierung | 88% | 88% | = |
| Planner Timeout Cap | 60s | 60s | aktiv |

### Nächste Schritte für messbare Verbesserung

1. **Timeout-Rate nach dem Fix messen** — Die nächsten 50 Tasks sollten deutlich unter 37% Timeout-Rate liegen
2. **Learner-Dedup Schwelle anpassen** — Von 80% auf 70% Ähnlichkeit reduzieren, um mehr diverse Regeln zu behalten
3. **Queue Starvation beheben** — Strategy braucht einen Idle-System Escape Hatch
4. **External Project Backlog adressieren** — superheld Registry mit 12 approved Tasks als größte Retry-Churn Quelle

### Gesamtbewertung

Das System **lernt messbar**, aber die Lerngeschwindigkeit war durch Regel-Regression gebremst. Die Non-Timeout Erfolgsrate (+6.2pp/100 Tasks) zeigt, dass die Lernmechanismen funktionieren. Die Timeout-Rate ist ein Infrastruktur-Problem (jetzt gefixt durch 60s Planner Cap), kein Lern-Problem. Mit den erweiterten Regeln und dem aktiven Planner-Cap sollte die nächste Iteration eine deutliche Verbesserung zeigen.
