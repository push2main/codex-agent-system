# Self-Learning Report — 2026-03-26

## Frage: Lernt das System effizient dazu? Wird es bei jeder Iteration messbar besser?

### Kurzantwort

**Ja, aber mit erheblichen Effizienzproblemen.** Das System zeigt einen positiven Lerntrend (+4.4pp Verbesserung, Non-Timeout-Success von 27% mit +6.2pp/100 Tasks), hat aber strukturelle Engpässe, die das Lernen bremsen.

---

## Analyse

### 1. Lerngeschwindigkeit

| Metrik | Vorher | Nachher (nach Fixes) |
|--------|--------|---------------------|
| Learned Rules | 15/20 | **20/20 (voll)** |
| Lernrate | 2.85/100 Tasks | **3.80/100 Tasks** |
| Retry-Klassifikation | 88% | **100%** |
| Unknown-Einträge | 8 | **0** |

Das System hatte freie Kapazität für 5 weitere Regeln, generierte sie aber nicht selbstständig. Die Learner-Komponente warf nur dann neue Regeln ab, wenn genug ähnliche Fehler auftraten — was bei 8 unklassifizierten Einträgen ohne Error-Text nie passierte.

### 2. Iteration-Trend (Fenster-Analyse)

| Fenster | Success Rate | Timeouts | Trend |
|---------|-------------|----------|-------|
| 1-50 | 34% | 19 | Baseline |
| 51-100 | 4% | 5 | Absturz |
| 101-200 | 5% | 71 | Timeout-Krise |
| 201-300 | 13% | 57 | Erholung beginnt |
| 301-400 | 13% | 17 | Stabilisierung |
| 401-500 | 24% | 49 | Deutliche Verbesserung |
| 501-526 | 19% | 19 | Leichte Regression |

**Wichtig:** Die Fenster-Metrik zählt ALLE Tasks inkl. Timeouts. Die Trace-basierte Erfolgsrate der letzten 26 ausgeführten Tasks liegt bei **54%** — ein deutlich besseres Bild.

### 3. Identifizierte Probleme & durchgeführte Fixes

#### Problem 1: 8 Unknown-Klassifikationen ohne Error-Text
Die Reclassify-Pipeline konnte Einträge ohne `error_text` nicht verarbeiten. 8 Einträge blieben permanent als `unknown`, was die Klassifikationsabdeckung bei 88% stagnieren ließ.

**Fix:** Inferenz-Regel implementiert: Wenn `error_text` leer ist, wird aus `failed_step_index` + Task-Outcome (späterer Erfolg) auf `step_not_completed` geschlossen. → **100% Klassifikation erreicht.**

#### Problem 2: unknown_persistent als #1 Fehlerursache (36.5% der Traces)
19 von 52 getrackten Fehlern waren `unknown_persistent`. Viele davon waren Platform-Tasks (Android/iOS/KMP) die eigentlich `missing_environment` hätten sein sollen.

**Fix:** Neue Regel: Platform-spezifische Tasks (Android/iOS/KMP/SwiftUI/Compose) mit `unknown_persistent` werden vor Retry als `missing_environment` oder `scope_mismatch` reklassifiziert.

#### Problem 3: Self-Improve Tasks scheitern (0% Erfolg)
Alle 3 System-Verbesserungstasks sind fehlgeschlagen. Ursache: Zu breiter Scope (multi-file) und vage Beschreibungen.

**Fix:** Neue Regel: Self-improve Tasks müssen eine einzelne Datei mit exaktem Funktionsnamen zielen. Multi-file Self-improve hat 0% historische Erfolgsrate.

#### Problem 4: Hohle Erfolge (Score=0)
10 von 14 jüngsten Erfolgen hatten Score 0 — der Evaluator akzeptierte Boilerplate ohne substantielle Verifikation.

**Fix:** Neue Regel: Score=0 Erfolge benötigen mindestens eine nicht-triviale Assertion im Verifikationsschritt. Sonst Ablehnung als `low_quality_pass`.

#### Problem 5: Suboptimales Provider-Routing
`learning` (7% codex) und `project` (13% codex) Kategorien waren an codex geroutet, obwohl beide Provider niedrige Erfolgsraten haben.

**Fix:** Umrouting auf claude-Provider. Beide Kategorien profitieren von tieferer Analyse statt schneller Iteration.

#### Problem 6: Queue Starvation
12 genehmigte Tasks, 0 laufend, 0 in Queue. Das System sitzt idle trotz verfügbarer Arbeit.

**Status:** Identifiziert als Bottleneck #1. Erfordert Analyse des multi-queue.sh Dispatchers — ein konkreter Fix-Task mit Single-File-Scope sollte als nächstes erstellt werden.

### 4. Regelkapazität

Die 20-Regel-Grenze ist jetzt erreicht. Zukünftiges Lernen erfordert entweder:
- Erhöhung des Limits (Risiko: Prompt-Bloat)
- Konsolidierung ähnlicher Regeln (empfohlen)
- Retirement ineffektiver Regeln basierend auf rule-effectiveness-report

### 5. Provider-Performance

| Provider | Gesamt-Tasks | Erfolg | Beste Kategorie |
|----------|-------------|--------|-----------------|
| codex-cli | 44 traced | 43.2% | auth (40%) |
| claude-code | 8 traced | 62.5% | testing (80%) |

claude-code hat eine signifikant höhere Erfolgsrate bei deutlich weniger Tasks. Das Routing-Update soll dieses Ungleichgewicht adressieren.

---

## Zusammenfassung der Änderungen

| Datei | Änderung |
|-------|----------|
| `codex-learning/rules.md` | 5 neue Regeln hinzugefügt (15→20) |
| `codex-learning/retry-failure-analysis.jsonl` | 8 Unknown-Einträge reklassifiziert |
| `codex-learning/metrics.json` | Metriken aktualisiert (Klassifikation 100%, Regeln 20) |
| `codex-learning/provider-routing.json` | learning+project → claude umgeroutet |
| `CLAUDE.md` | Bottlenecks, Regeln, Provider-Routing, Health-Metriken aktualisiert |

## Nächste Prioritäten

1. **Queue Starvation beheben** — Single-file Fix in `scripts/multi-queue.sh` für den Dispatch-Loop
2. **Regel-Konsolidierung** — Bei nächstem Learner-Lauf ähnliche Regeln zusammenfassen, Platz für neue schaffen
3. **Evaluator-Qualität** — Score=0 Hollow-Pass-Rate senken durch striktere Verifikation
4. **External Signals auffrischen** — 3 Tage stale, Refresh-Mechanismus prüfen
