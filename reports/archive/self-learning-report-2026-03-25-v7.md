# Self-Learning Efficiency Report — 2026-03-25T13:07Z

## Diagnose: Lernt das System effizient dazu?

**Kurz: Teilweise ja, aber mit drei kritischen Blindstellen.**

### Was funktioniert

- **Trendverbesserung bestätigt**: Erfolgsrate stieg von 4-6% (Tasks 51-200) auf 22-26% (Tasks 401-522). Die jüngsten 50 Tasks zeigen 28% Erfolg.
- **Zombie-Guard, Non-Retryable-Guard, Elapsed-Time-Guard**: Alle drei sind im Code durchgesetzt und verhindern nachweislich verschwendete Worker-Slots.
- **Retry-Klassifizierung**: Coverage von 13% auf 87% verbessert (54/62 Retries klassifiziert).
- **First-Pass Success**: 55% — erfolgreiche Tasks brauchen nur einen Versuch.

### Was NICHT funktioniert (3 Kernprobleme)

#### Problem 1: 42% der Failures sind diagnostisch blind
- **188 von 443 Failures** (97 `execution_failure` + 91 `step_failure`) haben KEINEN diagnostischen Text.
- Der Learner sieht nur "step_failure" ohne zu wissen WARUM — er kann daraus nichts lernen.
- **Ursache**: `failure_kind_tag` wurde nur gesetzt wenn `classify_failure` lief. Bei First-Attempt-Failures oder Steps die vor der Klassifizierung abbrechen, blieb der Tag leer.

#### Problem 2: Overscoped Tasks fressen 70% der Timeout-Kapazität
- **17 von 30 jüngsten Tasks** sind Timeouts (Ø 780s).
- Aufgaben wie "Implement comprehensive X with Y across all Z and W" sind strukturell zu breit für das Timeout-Budget.
- Das System generiert weiterhin solche Tasks, obwohl sie historisch <5% Erfolgsrate haben.

#### Problem 3: Learner-Regeln sind advisory-only und unwirksam
- `rule-effectiveness-report.json` zeigt **delta=-0.1** (Verschlechterung trotz neuer Regeln).
- Regeln wie "Keep tasks focused" sind nicht messbar und nicht im Code durchgesetzt.
- Der CLAUDE.md selbst sagt: "advisory-only rules have near-zero measurable impact" — aber der Learner produziert trotzdem weiter solche Regeln.

## Implementierte Fixes

### Fix 1: Retroaktive Failure-Klassifizierung (orchestrator.sh)
Wenn ein Step ohne vorherige `classify_failure`-Ausführung fehlschlägt, wird jetzt nachträglich aus coder/reviewer JSON-Output klassifiziert. Das eliminiert die 188 blinden `step_failure`/`execution_failure`-Einträge.

### Fix 2: Task Scope Gate (orchestrator.sh)
Neuer Pre-Planning-Check:
- Tasks mit >15 Wörtern UND ≥3 breiten Konjunktionen (`and`, `with`, `across`, `comprehensive`, `end-to-end`): Timeout auf 300s gekappt
- Tasks mit >20 Wörtern: Timeout um 25% reduziert
- Effekt: Overscoped Tasks scheitern schneller, Worker-Kapazität wird geschont

### Fix 3: Learner-Prompt verschärft (learner.sh)
Neue Anforderungen an Regeln:
- Müssen **konkrete Schwellenwerte** enthalten (z.B. "if word count > 15")
- Müssen **spezifische Code-Ziele** benennen (z.B. "in orchestrator.sh")
- Müssen **messbare Outcomes** beschreiben
- Explizite BAD/GOOD Beispiele im Prompt

### Fix 4: Neue Learned Rules
Drei neue code-durchgesetzte Regeln in `rules.md` und `CLAUDE.md` dokumentiert.

## Erwartete Wirkung

| Metrik | Vorher | Erwartet nach Fixes |
|--------|--------|-------------------|
| Blinde Failures (kein Diagnosetext) | 42% | <10% |
| Timeout-Waste (overscoped tasks) | 17/30 letzte Tasks | <8/30 |
| Learner-Regel-Wirksamkeit | delta=-0.1 | delta≥0 |
| Retry-Klassifizierung | 87% | >92% |

## Nächste Iteration sollte prüfen

1. Ob retroaktive Klassifizierung tatsächlich neue Failure-Kategorien produziert
2. Ob der Task Scope Gate false positives erzeugt (legitime komplexe Tasks fälschlich gekappt)
3. Ob die verschärften Learner-Regeln messbar besser korrelieren mit Erfolgsraten-Änderungen
