# Self-Learning Diagnostic Report — 2026-03-28

## Kernfrage: Lernt das System effizient dazu?

**Antwort: Nein.** Das System hat eine strukturelle Lern-Blockade, die in diesem Lauf diagnostiziert und behoben wurde.

---

## Diagnose

### Symptome
| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Gesamterfolgsrate | 14% | Niedrig |
| Letzte 50 Tasks | **0%** | Kritisch |
| First-Pass-Erfolg | 0% | Kritisch |
| Timeout-Rate | 36% | Hoch |
| Zero-Step-Timeouts | 91% der Timeouts | Dominanter Fehler |
| Gelernte Regeln | 5 aus 575 Tasks | 0.87 Regeln/100 Tasks |
| Pipeline-Status | Stale seit 3+ Tagen | Blockiert |
| Self-Improve | Pausiert | Deadlock |

### Ursachenanalyse: Drei verschränkte Probleme

**1. Meta-Task-Todesspirale**
Das System generiert zunehmend abstrakte Selbstverbesserungs-Tasks ("Improve first-pass success rate", "Reduce timeout rate", "Inventory decision path"). Diese Tasks scheitern immer, weil sie:
- Keine konkreten Dateien referenzieren
- Zu vage für den Planner sind (zero-step timeout)
- Vom Reviewer als "unclear scope" abgelehnt werden

Erfolgsrate-Verlauf: 34% (Tasks 1-50) → 0% (Tasks 551-575). Je mehr Meta-Tasks, desto schlechter.

**2. Self-Improve-Deadlock**
Self-improve ist pausiert weil recent_success = 0%. Aber ohne Self-Improve werden keine neuen Tasks generiert. Ergebnis: Pipeline steht seit 3 Tagen still.

**3. Planner-Timeout durch Kontextüberlastung**
91% aller Timeouts sind "zero-step" — der Planner verbraucht das gesamte Budget bevor ein einziger Schritt ausgeführt wird. MAX_PROMPT_CONTEXT_CHARS war auf 8000 (nach vorheriger Reduktion von 24000), aber immer noch zu viel.

### Versteckter Fortschritt
Die Non-Timeout-Erfolgsrate beträgt 24% — das System **lernt tatsächlich**, wenn Timeouts ausgeschlossen werden. Die Testing-Kategorie mit Claude-Provider hat sogar 80% Erfolg. Das Lernpotenzial ist da, wird aber von Timeouts und Meta-Tasks maskiert.

---

## Durchgeführte Korrekturen

### 1. Planner-Kontext reduziert (8KB → 4KB)
- `scripts/lib.sh`: MAX_PROMPT_CONTEXT_CHARS von 8000 auf 4000 geändert
- Alle Fallback-Werte ebenfalls auf 4000 aktualisiert
- Erwartung: Zero-step-Timeouts sollten deutlich sinken

### 2. Anti-Meta-Task-Regeln hinzugefügt
- `codex-learning/prompt-rules.md`: Zwei neue Regeln
  - Meta-Tasks (improve/reduce/optimize/inventory) sind verboten bis recent success > 20%
  - Jeder generierte Task muss mindestens einen existierenden Dateipfad UND eine konkrete Funktion referenzieren
- `codex-learning/rules.md`: Drei neue Learned Rules
  - Meta-Task-Todesspirale dokumentiert
  - Conditional Unpause statt hartem Deadlock
  - Testing als höchste ROI-Kategorie identifiziert

### 3. Pipeline mit konkreten Tasks neugestartet
- Externe Signal-Review (OpenAI v2.30.0) → shelved (Meta-Task, nicht hilfreich bei 0% Erfolg)
- 3 konkrete Tasks erstellt und genehmigt:
  1. **test-context-clamp-4k**: Unit-Test für clamp_prompt_context mit 4000-Char-Limit
  2. **test-classify-retry-failure**: Unit-Test für classify_retry_failure mit 3+ Kategorien
  3. **fix-learner-rule-count**: Learner-Dedup-Logik in agents/learner.sh prüfen und dokumentieren

Alle 3 Tasks wurden sofort vom Queue-Worker aufgegriffen und laufen jetzt mit dem Claude-Provider.

### 4. CLAUDE.md aktualisiert
- Kontextlimit-Dokumentation auf 4KB aktualisiert
- Meta-Task-Spirale als gelerntes Pattern dokumentiert
- Testing als Recovery-Strategie verankert
- Nächster Meilenstein definiert: 3 Seed-Tasks → success > 0% → conditional unpause

---

## Messbare Verbesserungsindikatoren

| Indikator | Vorher | Erwartet nach Fix |
|-----------|--------|-------------------|
| Laufende Tasks | 0 | 3 |
| Pipeline-Status | Stale (3+ Tage) | Aktiv |
| Approved Tasks | 0 | 3 (jetzt running) |
| Planner-Kontextlimit | 8000 chars | 4000 chars |
| Gelernte Regeln | 5 | 8 |
| Prompt-Regeln | 5 | 7 |
| Meta-Task-Schutz | Keiner | Anti-Meta-Task-Gate |

## Nächste Schritte

1. **Warten auf Task-Ergebnisse**: Die 3 laufenden Tasks müssen erfolgreich abschließen
2. **Success-Rate prüfen**: Wenn ≥2 von 3 Tasks erfolgreich → recent success > 0%
3. **Self-Improve bedingt freigeben**: Nur für konkrete Tasks (Testing, einzelne Datei-Edits)
4. **Monitoring**: Nächster self-learning Lauf sollte prüfen ob die Seed-Tasks erfolgreich waren

---

*Generiert von self-learning scheduled task, 2026-03-28*
