# Fortschrittsbericht — 2026-03-27 (v10, Scheduled)

## Systemstatus: BLOCKIERT — Pipeline im Deadlock seit >30h

Das System befindet sich in einem **strukturellen Stillstand**. Die Pipeline ist seit dem 26. März 12:17 Uhr als "stale" markiert und hat seitdem keine Tasks mehr ausgeführt. Der Grund ist ein seit v23 (4 Tage!) wiederkehrendes Problem, das trotz 4 dokumentierter Fixes nicht gelöst ist.

---

## Kernproblem: Queue-Directory-Deadlock (5. Wiederholung)

**Zustand jetzt:**
- `queues/codex-agent-system.txt` → **0 Bytes** (leer — das ist die Datei, die Worker lesen)
- `codex-queue/codex-agent-system.txt` → **762 Bytes** (3 Task-Einträge vorhanden — wird von Workern ignoriert)

**Warum die bisherigen Fixes nicht halten:**
Der v30-Fix fügte einen Auto-Copy-Guard in `strategy-loop.sh` ein. Aber: Wenn `pipeline_stale=true` ist, überspringt die Strategy-Loop die Task-Generierung — und der Guard läuft nur während aktiver Iterationen. Gleichzeitig werden die Tasks von den Queue-Workern als "orphaned" gelöscht, weil sie keine passenden Registry-Einträge finden. Das Ergebnis ist ein Teufelskreis:

1. `queues/` leer → Worker sehen nichts → kein Dispatch
2. Kein Dispatch → Pipeline bleibt stale
3. Pipeline stale → Strategy-Loop überspringt → Guard läuft nicht
4. Worker löschen "orphaned" Einträge aus `codex-queue/` → auch dort leer
5. Zurück zu 1.

**Empfehlung:** Der Queue-Sync-Guard muss **außerhalb** der Strategy-Loop laufen — z.B. als eigenständiger Cron-Job oder als Pre-Check im Worker-Startup. Alternativ: Die duale Queue-Architektur (`queues/` + `codex-queue/`) komplett eliminieren und auf ein einziges Verzeichnis konsolidieren.

---

## Metriken-Übersicht

| Metrik | Wert | Trend |
|--------|------|-------|
| Gesamt-Tasks | 526 | — |
| Erfolgsrate (all-time) | 15% | +4.4pp langfristig |
| Erfolgsrate (letzte 50) | 28% | ↑ |
| Erfolgsrate (letzte 20) | **10%** | ↓↓ Regression |
| Timeout-Rate | 37% (197/526) | — |
| Zero-Step-Timeout-Rate | **94%** | Kritisch |
| Non-Timeout-Erfolgsrate | 27% | +6.2pp/100 |
| Registry-Größe | 91 KB | OK (< 250 KB) |
| Gelernte Regeln | 12/20 | 8 Slots frei |
| Pipeline stale seit | **>30 Stunden** | Blockiert |

---

## Sind die aktuellen Tasks umsetzbar?

### Die 3 gequeueten Tasks:

**task-130: "Improve first-pass success rate"** (Priority 7, Provider: claude)
- Ziel: planner.sh optimieren (Prompt-Größe, Kontext-Qualität)
- **Bewertung: Grundsätzlich umsetzbar**, aber zu breit formuliert. "Improve planner context quality" hat kein klares Abbruchkriterium. Sollte in 1-2 konkrete, messbare Änderungen aufgesplittet werden (z.B. "Reduce planner system prompt to <4000 tokens").

**task-131: "Break retry churn"** (Priority 6, Provider: claude)
- Ziel: Exponential Backoff in orchestrator.sh
- **Bewertung: Gut umsetzbar.** Klar definiert, einzelne Datei, konkreter Mechanismus. Allerdings zeigt retry_churn_detected=false — das Problem existiert möglicherweise nicht mehr.

**task-132: "Reduce strategy saturation"** (Priority 4, Provider: claude)
- Ziel: strategy-loop.sh Cooldowns und Targets anpassen
- **Bewertung: Umsetzbar, aber niedriger Impact.** saturated_failed_tasks=0 und strategy_saturation=false — das Problem hat sich aufgelöst. Dieser Task ist obsolet.

**task-133: "Improve retry success rate"** (Pending Approval)
- **Bewertung: Duplikat von task-131.** Sollte abgelehnt und geshelved werden.

### Fazit Tasks:
- task-131 ist der einzige sofort sinnvolle Task
- task-130 braucht Umformulierung (konkreter, messbarer Scope)
- task-132 und task-133 sind obsolet/Duplikate

---

## Heben wir die Success Rate?

**Langfristig: Ja.** Die Trendlinie über 526 Tasks zeigt +4.4 Prozentpunkte Verbesserung und +1.36pp/100 Tasks Velocity. Die Non-Timeout-Erfolgsrate steigt sogar mit +6.2pp/100.

**Kurzfristig: Nein.** Die letzten 20 Tasks sind auf 10% abgestürzt (vs. 28% bei den letzten 50). Hauptursache: Eine Burst-Phase mit komplexen Superheld-Tasks (iOS-Notifications, Network-Scanner, Gamification), die fast alle am Timeout scheiterten.

**Das eigentliche Problem ist nicht die Task-Qualität, sondern der Stillstand:** Seit >30h wird kein einziger Task dispatched. Solange die Pipeline blockiert ist, verbessert sich nichts.

---

## Empfohlene Modifikationen

### 1. Queue-Architektur vereinfachen (KRITISCH)
**Problem:** Zwei Verzeichnisse (`queues/` und `codex-queue/`) mit unterschiedlichen Rollen sind die Wurzel des wiederkehrenden Deadlocks.
**Lösung:** Ein einziges `queues/`-Verzeichnis für alles. Task-JSONs und Dispatcher-Einträge am gleichen Ort. `codex-queue/` wird Symlink auf `queues/`.

### 2. Pipeline-Stale-Flag automatisch zurücksetzen
**Problem:** `pipeline_stale=true` seit >30h blockiert alles.
**Lösung:** Auto-Reset nach 6h wenn queued_tasks > 0. Oder: Worker prüfen direkt die Queue-Datei statt das Flag.

### 3. Obsolete Tasks aufräumen
- task-132 shelven (strategy_saturation=false, Problem gelöst)
- task-133 ablehnen (Duplikat von task-131)
- task-130 umformulieren: "Reduce planner system prompt below 4000 tokens in agents/planner.sh"

### 4. Zero-Step-Timeout-Rate adressieren
94% der Timeouts passieren vor dem ersten Schritt. Das deutet auf ein Planner-Problem hin: Der Planner verbraucht die gesamte Zeit mit Kontext-Loading, bevor er einen einzigen Step ausführt. Dies ist das größte Hebelproblem im System.

### 5. Superheld-Projekt isolieren
Die komplexen Superheld-Tasks (iOS, KMP, Compose) sind für den Großteil der jüngsten Timeout-Regression verantwortlich. Da keine lokale Toolchain vorhanden ist, sollten diese konsequent als `missing_environment` klassifiziert werden, statt Timeouts zu produzieren.

---

## Zusammenfassung

Das System hat in 4 Tagen echte Fortschritte gemacht: Die Langzeit-Erfolgsrate steigt, die Regelkonsolidierung (22→12) war erfolgreich, und die Retry-Klassifikation hat 100% Coverage erreicht. **Aber:** Alle diese Verbesserungen sind wirkungslos, solange die Pipeline durch den Queue-Directory-Deadlock blockiert bleibt. Das ist jetzt die 5. Wiederholung desselben Problems.

**Priorität 1:** Queue-Verzeichnisse konsolidieren (ein Verzeichnis statt zwei).
**Priorität 2:** Pipeline-Stale-Flag mit Auto-Reset versehen.
**Priorität 3:** Dann erst Tasks optimieren und dispatchen.

Ohne Fix von Priorität 1 und 2 dreht sich das System weiter im Leerlauf.
