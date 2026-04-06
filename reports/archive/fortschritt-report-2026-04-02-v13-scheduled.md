# Fortschritt-Report — 2026-04-02 v13 (Scheduled)

## Systemstatus: STABIL, LEERLAUF — Keine Veränderung seit v12

---

### Kennzahlen-Snapshot

| Metrik | Wert | Bewertung |
|---|---|---|
| Tasks gesamt (historisch) | 767 (Metrics) / ~1.100+ (Archiv) | Umfangreiche Historie |
| Zentrale Registry | 11 Tasks (4 completed, 7 shelved) | Keine offenen Tasks |
| Superheld Registry | 14 Tasks (alle completed, Smoke-Rotation) | Kein produktiver Output |
| Registry Größe | 91 KB + 213 KB = ~304 KB | Unter 512 KB Limit |
| Queue | **Leer** (0 queued, 0 running) | Kein Material |
| Recent Success Rate (last 50) | **98%** | Irreführend — nur Smoke-Tasks |
| All-time Success Rate | **29%** | Historisch belastet, stagniert |
| First-pass Success Rate | **83%** | Gut, aber aktuell keine echten Tasks |
| Timeout Rate | **28%** | Anhaltend problematisch |
| Self-Improve State | `cooldown_active` | **Blockiert** |
| External Signals | `stale` (letzte: 25. März) | Inaktiv |
| Alerts | 2 aktive (retry_churn HIGH, loop_effort WARNING) | Persistierend |

---

## 1. Aktueller Fortschritt

**Seit v12 (heute früher) hat sich nichts verändert.** Das System ist seit ca. 5–6 Tagen im funktionalen Leerlauf.

Letzte echte Implementierungs-Erfolge waren am 29. März (task-006 bis task-011). Seitdem:

- Superheld-Projekt rotiert 3 Smoke-Verification-Tasks (trigger-aware credential recovery, dashboard incident id, inventory decision path) in Endlosschleife — alle completed mit score=0
- Die zentrale Queue ist leer, der Self-Improve-Mechanismus ist durch `cooldown_active` blockiert
- 7 von 11 zentralen Tasks sind geshelved, 4 completed — keine pending oder approved Tasks

### Iteration-Trend (historisch)

| Window | Success Rate | Timeouts |
|---|---|---|
| 1–100 | 19% | 24 |
| 101–200 | 5% | 71 |
| 201–300 | 13% | 57 |
| 301–400 | 13% | 17 |
| 401–500 | 24% | 49 |
| 501–600 | 12% | 31 |
| **601–700** | **72%** | **2** |
| **701–767** | **97%** | **0** |

Der Trend zeigt eine massive Verbesserung ab Window 601+, allerdings mit dem Vorbehalt, dass die letzten ~100 Tasks vorwiegend Smoke-Tests sind.

---

## 2. Sind die bisherigen Tasks umsetzbar?

### Abgeschlossene Tasks (4/11) — JA
- task-006 (syntax-check-planner): Erledigt
- task-007 (verify-step-cap): Erledigt nach 3 Attempts
- task-008 (fix-learner-comment): Erledigt nach 3 Attempts
- task-011 (improve-retry-success-rate): Erledigt nach 1 Attempt

### Geshelved Tasks (7/11) — Differenziert:

| Task | Status | Empfehlung |
|---|---|---|
| task-010 (reduce-timeout-rate) | 0 Attempts, geshelved | **Reaktivierbar** — relevanter Verbesserungs-Task |
| task-002 (test-context-clamp) | 2 Fehlversuche | Reformulieren oder verwerfen |
| task-003 (test-classify-retry) | 2 Fehlversuche | Reformulieren |
| task-004 (fix-learner-rule-count) | 2 Fehlversuche | **Obsolet** — task-008 hat Ähnliches erledigt |
| task-005 (system-work-buffer) | Auto-shelved | Analyse-Task, kann entfernt werden |
| task-009 (inventory-decision-path) | Auto-shelved | Duplikat der Smoke-Tasks |
| task-001 (external-signal-openai) | Auto-shelved | Signal veraltet, entfernen |

### Provider-Leistung (historisch)

**Codex** ist durchgehend besser als **Claude**:
- Codex auth: 72% vs Claude auth: 0%
- Codex testing: 57% vs Claude testing: 36%
- Codex UI: 39% vs Claude UI: 15%
- Codex infra: 36% vs Claude infra: 13%

Kategorien mit 0% Erfolgsrate bei beiden Providern: security, architecture, performance.

---

## 3. Heben wir die Success Rate?

**Nein — die Rate stagniert.**

- All-time: 29% (unverändert)
- Recent (50): 98% — aber ausschließlich Smoke-Tasks
- Letzte echte Code-Änderung: ca. 29. März
- Kein neues Lernmaterial: Self-Improve blockiert, External Signals stale

Die 5 Learned Rules in CLAUDE.md sind sinnvoll und haben zur Verbesserung in Window 601–700 beigetragen, aber ohne neue Tasks gibt es nichts zu verbessern.

---

## 4. Notwendige Modifikationen

### KRITISCH: Self-Improve Cooldown zurücksetzen

**Problem:** `self-improve-run.json` zeigt `dominant_reason: "cooldown_active"`. Detected=0, Generated=0, Submitted=0. Das System generiert seit Tagen keine neuen Verbesserungs-Tasks.

**Aktion:** In `codex-learning/self-improve-run.json` den Cooldown-State zurücksetzen oder die Cooldown-Logik in den relevanten Agents so anpassen, dass nach einer stabilen Phase (z.B. 3+ Tage ohne Fehler) automatisch neue Tasks generiert werden.

### KRITISCH: Queue mit echten Tasks befüllen

**Problem:** Queue ist leer, keine approved Tasks, keine pending Tasks.

**Optionen:**
1. **task-010 reaktivieren** (reduce-timeout-rate) — hochrelevant, 0 bisherige Attempts
2. **Neue Feature-Tasks** einspeisen für Kategorien mit guter Erfolgsrate (testing: 57%, auth: 72%, UI: 39%)
3. **External-Signal-Quellen** aktualisieren (letzte Aktualisierung: 26. März)

### HOCH: Smoke-Rotation begrenzen

**Problem:** 14 Superheld-Tasks, alle completed, rotieren endlos. Heute allein 5 Smoke-Runs ohne Code-Output.

**Aktion:** Max-Wiederholungsrate nach 3+ konsekutiven Erfolgen auf 1x/Tag oder weniger beschränken.

### MITTEL: Archiv-Hygiene

- Registry: 304 KB (unter 512 KB Limit, aber wachsend)
- 7 geshelved Tasks in zentraler Registry — 4 davon obsolet (task-001, -004, -005, -009), können archiviert werden
- 20 historische Zombie-Tasks blockieren verwandte neue Tasks

### NIEDRIG: Provider-Routing optimieren

Claude-Provider ist bei allen Kategorien signifikant schlechter. Empfehlung: Claude nur noch für explizite UI-Tasks verwenden, alles andere an Codex routen.

---

## 5. Zusammenfassung

| Aspekt | Status | Handlungsbedarf |
|---|---|---|
| System-Stabilität | Sehr gut (keine Crashes, keine Pressure) | Keiner |
| Echte Wertschöpfung | **Null seit ~5 Tagen** | **KRITISCH** |
| Success Rate (real) | Stagniert bei 29% | Neue Tasks nötig |
| Self-Improve | Blockiert (Cooldown) | **Cooldown-Reset** |
| Task-Queue | Leer | **Tasks einspeisen** |
| Smoke-Rotation | Endlos, ohne Output | Begrenzung |
| Alerts | 2 aktive (retry_churn, loop_effort) | Werden sich mit neuen Tasks auflösen |

**Fazit:** Der Systemzustand ist seit v12 unverändert. Technisch stabil, aber funktional im Stillstand. Die drei Sofortmaßnahmen bleiben:

1. **Self-Improve-Cooldown zurücksetzen** — damit neue Tasks generiert werden können
2. **Echte Tasks in die Queue** — task-010 reaktivieren, neue Tasks aus erfolgreichen Kategorien
3. **Smoke-Rotation begrenzen** — Ressourcenverschwendung stoppen

Ohne diese manuellen Eingriffe wird der Leerlauf unbegrenzt fortbestehen. Das System hat bewiesen, dass es bei geeigneten Tasks eine 97%+ Success Rate erreichen kann (Window 701–767), aber es fehlt an Material zum Verarbeiten.
