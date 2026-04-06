# Fortschrittsbericht — 2026-03-31 (v13, Scheduled)

**Generiert:** 2026-03-31 ~11:30 UTC, automatisierter Scheduled Run (Cowork)

---

## 1. Gesamtstatus: Hohe SR erreicht — Pipeline seit >48h blockiert

Das System hat sich von einer historischen Success Rate von ~4% (Lerntal, Tasks 51–200) auf stabile **82% in den letzten 50 Tasks** hochgearbeitet. Der Trend ist eindeutig positiv. Allerdings steht die Pipeline weiterhin still: **Cooldown-Deadlock in der Self-Improve-Logik** blockiert sowohl Task-Generierung als auch -Ausführung. Die Queues beider Projekte sind leer.

---

## 2. Kennzahlen-Übersicht

| Metrik | Wert | Trend |
|---|---|---|
| Tasks gesamt (all-time) | 686 | +2 seit letztem Report |
| All-time Success Rate | 21% | historisch belastet (irrelevant) |
| **Letzte 50 Tasks SR** | **82%** | ✅ stabil |
| First-Pass Success Rate | 81% | ✅ verbessert (war 62%) |
| Timeout-Rate (kumulativ) | 31% | keine neuen Timeouts |
| Zero-Step-Timeouts | 227 kumulativ, 0 neue | ✅ eliminiert |
| Retry-Klassifizierung | 100% (143/143) | ✅ |
| Registry-Größe | 278 KB | ✅ unter 512 KB Grenze |
| Queue-Status | **LEER** | ⛔ Deadlock |
| Zombie-Tasks | 20 | stabil, korrekt geshelved |
| Learning Rules | 10 aktiv | stabil |
| Learning Knowledge | 199 Einträge | ausreichend |

---

## 3. Trendverlauf (Iteration Windows)

| Window | Success Rate | Timeouts |
|---|---|---|
| 1–50 | 34% | 19 |
| 51–200 | 4–6% | 76 (Lerntal) |
| 201–300 | 10–16% | 57 |
| 301–400 | 12–14% | 17 |
| 401–500 | 22–26% | 49 |
| 501–600 | 10–14% | 31 |
| **601–650** | **58%** | **1** |
| **651–686** | **81%** | **1** |

Die letzten 86 Tasks zeigen einen klaren Durchbruch. Timeouts sind praktisch eliminiert (2 in 86 Tasks vs. 209 in den ersten 600).

---

## 4. Task-Registry Status

### Aktive Registry (codex-memory/tasks.json)
- **4 completed** — funktionieren wie erwartet
- **7 shelved** — davon 2 potenziell re-queue-fähig (Test context-clamp, Test classify-retry)
- **0 pending / 0 running / 0 queued** — Pipeline steht

### Archiv (tasks-archive.json): 1103 Tasks
- 196 completed + 4 done = **200 erfolgreich** (18.1%)
- 406 failed, 375 shelved, 121 rejected

### Projekt superheld
- 10/12 Tasks erfolgreich (83%) — sehr gut
- Bewährtes Muster: Dashboard-Verifikations-Tasks

---

## 5. Provider-Performance

| Provider | Stärkste Kategorien | Schwächste |
|---|---|---|
| codex | auth (70%), testing (36%) | code_quality (11%), learning (12%) |
| claude | testing (36%), general (19%) | auth (0%), code_quality (0%) |

Das Routing (claude → UI, codex → alles andere) ist korrekt und sollte beibehalten werden.

---

## 6. Sind die bisherigen Tasks umsetzbar?

**Ja.** Die 82% SR der letzten 50 Tasks bestätigt, dass das Gros der generierten Tasks machbar ist. Problematisch bleiben:

- **Abstrakte Self-Improve-Tasks** ("Improve X rate"): 0% SR — zu breit, keine konkreten Dateiziele
- **Tasks mit ungeprüften Repo-Pfaden**: Hauptquelle für Fehlschläge (Learned Rule #1 + #2)
- **Code-Quality-Tasks**: 11% SR bei codex, 0% bei claude — schwierigste Kategorie

---

## 7. Heben wir die Success Rate?

**Ja, eindeutig.** Die Lernkurve ist real und die Verbesserungen sind systemisch:

| Maßnahme | Wirkung |
|---|---|
| Step-Cap (max 6) | Timeouts drastisch reduziert |
| Zombie-Guard (5+ Failures → Shelve) | 20 Endlos-Loops eliminiert |
| Retry-Klassifizierung | 100% Coverage (war 24%) |
| Zero-Step-Timeout-Fix | 227 → 0 neue |
| Pfad-Existenz-Checks | Reduced missing_source_file Fehler |

Der Sprung von 26% (Window 451–500) auf 81% (Window 651–686) ist real und reproduzierbar.

---

## 8. Blockade: Cooldown-Deadlock — Details

### Root Cause
`self-improve-run.json` zeigt alle drei Gating-Felder auf `cooldown_active`:
- `dominant_reason: cooldown_active`
- `analysis_reason: cooldown_active`
- `submission_reason: cooldown_active`

`self-improve-automation-memory.json` zeigt:
- `external_sync_pending: true` (wartet auf Sync der nie kommt)
- `source: none` (keine valide Quelle konfiguriert)
- `automation_id: ""` (nicht initialisiert)

### Auswirkung
- 0 Tasks generiert, 0 submitted, 0 detected
- Beide Queues leer (codex-agent-system + superheld)
- System läuft im Leerlauf: Orchestrator-Runs finden statt (heute 14+ Runs) aber ohne Tasks

---

## 9. Empfohlene Modifikationen

### KRITISCH — Sofort

1. **Cooldown-Deadlock auflösen**
   - In `self-improve-run.json`: Alle `cooldown_active` Werte auf `none` setzen
   - In `self-improve-automation-memory.json`: `external_sync_pending` auf `false`, `source` auf validen Wert setzen
   - Alternativ: Beide Dateien auf einen bekannten guten Zustand zurücksetzen

2. **Queue manuell befüllen**
   - Die 2 re-queue-fähigen shelved Tasks (Test context-clamp, Test classify-retry) als Validierungs-Canaries requeuen

### WICHTIG — Kurzfristig

3. **Cooldown-TTL einführen**
   - Max 2h Cooldown bei leerer Queue
   - Auto-Reset-Trigger wenn Queue >4h leer — verhindert erneuten Deadlock

4. **Self-Improve-Gating robuster machen**
   - `external_sync_pending` darf nicht unbegrenzt blockieren
   - Fallback: Wenn Source `none` ist, lokale Analyse statt External Signal nutzen

### EMPFOHLEN — Mittelfristig

5. **Task-Scope-Regeln verschärfen**
   - 1 Task = 1 Datei + 1 konkrete Änderung
   - Keine "Improve X" Tasks ohne konkreten Implementierungsplan
   - Vorvalidierung: Existieren die referenzierten Dateien?

6. **Code-Quality-Kategorie verbessern**
   - Aktuell 11% SR (codex) / 0% (claude) — schlechteste Kategorie
   - Engere Scopes, konkretere Anweisungen, Pfad-Checks

7. **Archiv-Kompaktierung**
   - 1103 Tasks im Archiv, davon 375 shelved + 121 rejected = 496 irrelevant
   - Cold-Archive dieser Einträge würde Leseperformance verbessern

---

## 10. System-Ampel

| Aspekt | Status |
|---|---|
| Success Rate (letzte 50) | ✅ GRÜN (82%) |
| First-Pass Rate | ✅ GRÜN (81%) |
| Lernkurve | ✅ GRÜN (steil aufwärts) |
| Zero-Step Timeouts | ✅ GRÜN (eliminiert) |
| Retry-Klassifizierung | ✅ GRÜN (100%) |
| Registry-Pressure | ✅ GRÜN (278 KB) |
| Incidents | ✅ GRÜN (0 aktiv) |
| **Pipeline-Betrieb** | ⛔ **ROT** (Deadlock) |
| **Self-Improve** | ⛔ **ROT** (Cooldown-Block) |
| Alerts | ⚠️ GELB (retry_churn + loop_effort) |

---

## 11. Fazit

**Das System funktioniert hervorragend wenn es läuft** — 82% SR, 81% First-Pass, Timeouts eliminiert. Die Lernmechanismen greifen nachweislich.

**Das akute Problem ist organisatorisch, nicht technisch:** Ein Cooldown-Deadlock blockiert die gesamte Pipeline seit >48h. Das System generiert keine neuen Tasks und führt keine aus, obwohl der Orchestrator regelmäßig läuft (14+ Runs heute).

**Handlungsempfehlung:** Cooldown-Reset durchführen (Priorität 1), dann systemische Absicherung gegen erneuten Deadlock einbauen (TTL-Cap). Die Tasks selbst sind umsetzbar — das Problem liegt in der Steuerungsschicht, nicht in der Ausführung.
