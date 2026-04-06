# Fortschritt-Report — 2026-04-02 v11 (Scheduled)

## Systemstatus: STABIL, LEERLAUF — Handlungsbedarf bei Task-Generierung

---

### Kennzahlen-Snapshot

| Metrik | Wert | Bewertung |
|---|---|---|
| Tasks gesamt (Archiv) | 1103 | Umfangreiche Historie |
| Aktive Registry (zentral) | 11 Tasks (4 completed, 7 shelved) | Keine offenen Tasks |
| Superheld Registry | 12 Tasks (alle completed) | Leer, keine Arbeit |
| Recent Success Rate (last 50) | **98%** | Hoch, aber irreführend |
| All-time Success Rate | **29%** | Historisch belastet |
| First-pass Success Rate | **80%** (CLAUDE.md) / 100% (self-improve) | Gut |
| Timeout Rate | 26-28% | Weiterhin Problem |
| Zero-step Timeout Rate | **89%** | Kritisch — Planung frisst Budget |
| Registry Größe | 91 KB (zentral) + 180 KB (superheld) = 271 KB | Unter 512 KB Limit |
| Queue | **Leer** | Keine Tasks wartend |
| Self-Improve State | `cooldown_active` | **Blockiert** |
| External Signals | `stale` | Nicht aktiv |

---

## 1. Sind die bisherigen Tasks umsetzbar?

**Die abgeschlossenen Tasks waren umsetzbar — aber es gibt keine neuen.**

Die 4 completed Tasks in der zentralen Registry (task-006 bis task-011) wurden erfolgreich umgesetzt:
- `syntax-check-planner` — Dokumentation des MAX_STEP_CHARS=600 Gates
- `verify-step-cap` — Test für Planner Step-Längen-Limit
- `fix-learner-comment` — Learner Dedup-Threshold Dokumentation
- `improve-retry-success-rate` — Retry-Erfolgsrate verbessert

Die 7 shelved Tasks sind **nicht mehr umsetzbar ohne Intervention**:
- 3 Tasks wegen `zombie_guard` (5+ Fehlversuche) → dauerhaft gesperrt
- 1 Task auto-shelved wegen Duplikat
- 3 Tasks nach je 2 Versuchen gescheitert

Im **Superheld-Projekt** rotieren seit Tagen nur 3 Smoke-Verification-Tasks:
1. `verify-dashboard-incident-id-field-in-smoke-flow` — endlos wiederholt
2. `verify-trigger-aware-credential-recovery` — endlos wiederholt
3. `inventory-current-decision-path` — endlos wiederholt

Alle enden erfolgreich (score=0), produzieren aber **keinerlei Code-Changes oder PRs**.

---

## 2. Heben wir die Success Rate?

**Numerisch ja — inhaltlich nein.**

| Fenster | Success Rate | Realitätscheck |
|---|---|---|
| All-time | 29% | Historisch belastet durch Anlaufphase |
| Recent 50 | 98% | Nur Smoke-Verifikation, keine echten Tasks |
| Q4 (letzte 132) | 98% | Trend stabil, aber hollow |

Die 98% Success Rate ist ein **Artefakt der Smoke-Rotation**: Das System führt nur noch Tasks aus, die per Design nicht fehlschlagen können. Echte Implementierungs-Tasks (die das System verbessern könnten) werden nicht mehr generiert.

**Archiv-Analyse der letzten 100 Tasks:**
- 16 completed, 30 failed, 44 shelved, 8 rejected
- Letzte echte Aktivität mit variablen Outcomes: bis 28. März
- Seit 29. März: zunehmend monotone Rotation

---

## 3. Diagnose: Warum steht das System still?

### Problem 1: Self-Improve dauerhaft im Cooldown
- `self-improve-run.json`: `state: "none"`, `dominant_reason: "cooldown_active"`
- 0 detected, 0 generated, 0 submitted improvements
- Keine neuen Tasks werden vorgeschlagen

### Problem 2: Queue komplett leer
- `codex-queue/codex-agent-system.txt`: leer
- 0 queued, 0 running, 0 backlog
- Kein Material für den Orchestrator

### Problem 3: External Signals inaktiv
- Status: `stale`
- 0 frische externe Signale
- Letzte Quelle: "OpenAI Python releases" — veraltet

### Problem 4: Zombie-Tasks nicht aufgelöst
- 20 Zombie-Tasks (5+ wiederholte Fehlversuche) laut CLAUDE.md
- Diese blockieren potenziell verwandte neue Tasks

### Problem 5: Zero-Step Timeouts extrem hoch (89%)
- Von allen Timeouts sind 89% Zero-Step — der Planner verbraucht das gesamte Budget bevor der erste Step ausgeführt wird
- CLAUDE.md empfiehlt 60s Cap für Planning, aber der Effekt ist unklar

---

## 4. Empfohlene Modifikationen

### SOFORT: Cooldown zurücksetzen
Der Self-Improve-Mechanismus muss reaktiviert werden. In `codex-learning/self-improve-run.json` den Cooldown-State zurücksetzen oder die Cooldown-Logik anpassen, damit nach einer stabilen Phase (98% Success) neue Verbesserungen generiert werden.

### KURZFRISTIG: Smoke-Rotation begrenzen
Die 3 Smoke-Tasks sollten eine maximale Wiederholungsrate erhalten (z.B. 1x/Tag statt alle 90 Minuten). Vorschlag: Nach 3 aufeinanderfolgenden Erfolgen → 24h Pause.

### KURZFRISTIG: Neue Tasks einspeisen
Optionen:
- Manuell Feature-Tasks in die Queue einspeisen
- External-Signal-Quellen aktualisieren und reaktivieren
- Task-Generierungs-Schwellen senken

### MITTELFRISTIG: Provider-Routing evaluieren
Aktuelle Routing-Regeln zeigen niedrige Success Rates für beide Provider:
- `codex`: 11-72% je Kategorie (beste: auth 72%, testing 57%)
- `claude`: 0-36% (durchgehend schlechter)
Empfehlung: Routing-Regeln mit aktuelleren Daten aktualisieren.

### MITTELFRISTIG: Zero-Step Timeout beheben
89% Zero-Step-Timeout-Rate ist inakzeptabel. Der 60s Planning-Cap aus CLAUDE.md muss verifiziert und ggf. härter durchgesetzt werden.

---

## 5. Zusammenfassung

| Aspekt | Status | Handlungsbedarf |
|---|---|---|
| Stabilität | Sehr gut | Keiner |
| Success Rate (numerisch) | 98% | Metrik ist irreführend |
| Echte Wertschöpfung | **Null seit ~5 Tagen** | **KRITISCH** |
| Self-Improve | Blockiert (Cooldown) | Cooldown-Reset nötig |
| Task-Queue | Leer | Neue Tasks einspeisen |
| External Signals | Stale | Reaktivieren |
| Smoke-Rotation | Endlos, ressourcenintensiv | Begrenzung einführen |
| Zero-Step Timeouts | 89% | Planning-Budget-Cap durchsetzen |

**Fazit:** Das System ist technisch stabil, aber seit ~5 Tagen funktional im Stillstand. Die 98% Success Rate maskiert, dass keine echten Code-Änderungen oder Verbesserungen stattfinden. Der Self-Improve-Cooldown ist die Hauptblockade — ohne manuellen Reset oder Konfigurationsanpassung wird sich der Leerlauf fortsetzen. Die Empfehlung lautet: **(1)** Cooldown zurücksetzen, **(2)** Smoke-Rotation begrenzen, **(3)** neue Feature-Tasks einspeisen.
