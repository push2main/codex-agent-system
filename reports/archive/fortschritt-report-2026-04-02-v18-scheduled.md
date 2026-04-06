# Fortschrittsbericht — 2026-04-02 (v18, Scheduled)

## Systemstatus: Technisch stabil, produktiv eingefroren

Das System läuft fehlerfrei (keine Crashes, kein Registry-Pressure, keine Incidents), erzeugt aber seit dem 28. März keine neuen echten Tasks mehr. Die Pipeline ist faktisch tot.

---

## Kennzahlen im Überblick

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Gesamt-Successrate | 30% (all-time) | Durch frühe Fehlschläge belastet |
| Recent-50-Successrate | 96% | **Irreführend** — nur Smoke-Verify-Tasks |
| First-Pass-Successrate | 75% | Solide, aber Stichprobe klein (12 Tasks) |
| Timeout-Rate | 27% (212 von 774) | Hauptproblem |
| Zero-Step-Timeouts | 90% aller Timeouts | Planner verbraucht gesamtes Budget |
| Registry-Größe | 244 KB (Limit: 512 KB) | Gesund |
| Aktive Alerts | 2 (RETRY_CHURN high, LOOP_EFFORT warning) | Aufmerksamkeit nötig |
| Lernregeln | 5 von 20 Slots belegt | Unterdurchschnittlich |
| Self-Improve | **Blockiert (cooldown_active)** | Hauptblocker |

---

## Kernproblem: Self-Improve-Cooldown

Die `self-improve-automation-memory.json` ist effektiv leer (`automation_id: ""`, `source: "none"`, `external_sync_pending: true`). Der Self-Improve-Run meldet `cooldown_active` als dominanten Gating-Grund — es werden 0 Candidates detected, 0 generated, 0 submitted.

**Konsequenz:** Keine neuen Tasks werden generiert. Die Queue ist leer. Nur noch rotierende Verify-Tasks aus dem Superheld-Projekt laufen (3 identische Titel in Endlosschleife: Tasks 161–170).

---

## Task-Registries

### Codex-Agent-System (Hauptregistry)
- 11 Tasks total: **4 completed, 6 shelved, 1 pending**
- Shelved Tasks mit hohem Potenzial:
  - `task-002` (Test clamp_prompt_context, Impact 7, Effort 1) — gescheitert an review_rejection, Root-Cause behoben
  - `task-003` (Test classify_retry_failure, Impact 7, Effort 1) — gleicher Root-Cause, behoben
- Beide wären Quick Wins zum Unshelven

### Superheld-Projekt
- 10 Tasks: 8 completed, 1 failed, 1 running
- **Alle sind Varianten von 3 identischen Titeln** (Verify-Loops)
- Kein Fortschritt bei echten Features

---

## Provider-Performance

| Kategorie | Codex Success | Claude Success | Empfehlung |
|-----------|--------------|----------------|------------|
| Auth | 72% (29 Tasks) | 0% (3 Tasks) | Codex klar besser |
| UI | 40% (241 Tasks) | 15% (74 Tasks) | Codex besser |
| Testing | 57% (7 Tasks) | 36% (14 Tasks) | Codex besser |
| Infra | 38% (88 Tasks) | 13% (31 Tasks) | Codex besser |
| Code Quality | 11% (19 Tasks) | 0% (5 Tasks) | Beide schwach |

Claude-Provider zeigt durchgängig niedrigere Raten. Provider-Routing bevorzugt bereits Codex — korrekte Konfiguration.

---

## Sind die bisherigen Tasks umsetzbar?

**Ja, mit Einschränkungen:**

1. **Shelved Tasks task-002 und task-003** (Unit-Tests): Der Root-Cause (overly verbose steps >600 chars → review_rejection) wurde im Planner behoben. Diese Tasks haben Impact 7, Effort 1, Confidence 0.9 — sie sind die besten Kandidaten zum Unshelven und sollten beim nächsten Lauf erfolgreich sein.

2. **task-004** (Learner-Fix): Ebenfalls shelved, Impact 6, Effort 1. Adressiert direkt das Problem der niedrigen Lernrate (5/20 Regeln).

3. **task-011** (Improve Retry Success Rate): Bereits completed — Successrate stieg.

4. **Superheld-Tasks**: Die rotierenden Verify-Tasks sind technisch umsetzbar (sie laufen ja), aber produktiv wertlos. Sie verifizieren wiederholt dieselbe Funktionalität.

---

## Empfohlene Modifikationen

### Priorität HOCH (sofort)

1. **Self-Improve-Cooldown aufheben**: Die `self-improve-automation-memory.json` muss rehydriert werden. Ohne dies entstehen keine neuen Tasks und das System dreht sich im Leerlauf.

2. **Task-002 und Task-003 unshelven**: Beide haben Impact 7, Effort 1, und der Root-Cause (Step-Verbosity) wurde behoben. Erwartete Erfolgswahrscheinlichkeit: >80%.

3. **Zombie-Guard für Superheld-Verify-Loops aktivieren**: Die 3 rotierenden Verify-Titel (credential recovery, dashboard incident, inventory decision) sollten gesperrt werden (>5 Wiederholungen ohne neuen Erkenntnisgewinn).

### Priorität MITTEL

4. **Task-004 unshelven** (Learner-Fix): Erhöht die Lernrate und nutzt mehr der 20 verfügbaren Regelslots.

5. **External Signals auffrischen**: Letzte Aktualisierung 26. März (7 Tage stale). Auto-Refresh aktivieren.

6. **Metrics-Window-Bug fixen**: iteration_trend zeigt 0.00 über alle Fenster — vermutlich ein Berechnungsfehler, der das Monitoring blind macht.

### Priorität NIEDRIG

7. **Queue-Refill-Mechanismus**: Nach Cooldown-Aufhebung prüfen, ob neue Tasks automatisch generiert werden oder manuelles Seeding nötig ist.

8. **Code-Quality-Kategorie**: Beide Provider unter 11% — eventuell Tasks in dieser Kategorie vereinfachen oder die Kategorie-Definition schärfen.

---

## Fazit

Das System hat eine beeindruckende Verbesserungskurve hingelegt (+65 Prozentpunkte von der ersten auf die zweite Hälfte). Die technische Infrastruktur ist stabil und die gelernten Regeln wirken. Aber: **Die Pipeline ist eingefroren**. Der Self-Improve-Cooldown verhindert jede Weiterentwicklung. Die 96% Recent-Successrate ist ein Artefakt trivialer Verify-Loops, nicht echter Produktivität.

**Einzelne wichtigste Aktion:** Self-Improve-Cooldown aufheben und die zwei High-Impact-Shelved-Tasks (002, 003) reaktivieren. Damit würde echte Arbeit wieder anlaufen.
