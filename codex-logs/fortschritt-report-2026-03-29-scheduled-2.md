# Fortschrittsbericht — Codex Agent System
## 2026-03-29 (zweiter Scheduled Check)

---

## Gesamtbewertung: DEADLOCK — Manueller Eingriff erforderlich

Das System hat seit 4 Tagen (2026-03-25) keinen einzigen Task erfolgreich abgeschlossen. Die Pipeline steht, die Queue ist de facto leer, und der zentrale Blocker kann vom System nicht selbst behoben werden.

---

## 1. Kennzahlen-Übersicht

| Metrik | Wert | Bewertung |
|---|---|---|
| Total Tasks | 587 | — |
| All-time Success Rate | 13% (81/587) | Schlecht |
| Recent Success Rate (letzte 50) | **0%** | KRITISCH |
| First-Pass Success Rate | 0% | KRITISCH |
| Timeout-Rate | 35% (206 Timeouts) | Hoch |
| Zero-Step-Timeouts | 91% aller Timeouts (224/245) | Planung frisst das ganze Budget |
| Zombie Tasks | 20 (166 verschwendete Slots) | Korrekt geshelved |
| Pipeline stale seit | 2026-03-25 (4+ Tage) | BLOCKIERT |
| Retry-Churn | Aktiv | 3 Tasks im Loop |
| Trend (Velocity) | −0.69pp pro 100 Tasks | Verschlechtert sich |

### Historischer Verlauf (Success Rate pro 50-Task-Fenster)

```
 1–50:   34% ████████████████  (Anfangsphase, einfache Tasks)
51–100:   4% ██
101–150:  6% ███
151–200:  4% ██                (Tiefpunkt Phase 1)
201–250: 16% ████████          (Recovery nach Fixes)
251–300: 10% █████
301–350: 14% ███████
351–400: 12% ██████
401–450: 22% ███████████       (Self-Improve-Welle)
451–500: 26% █████████████     ← PEAK
501–550: 10% █████             (Regression)
551–587:  0%                   ← DEADLOCK
```

**Non-Timeout Success Rate: 23%** — Das zeigt: Wenn Tasks die Planung überleben, ist das System durchaus fähig. Der Flaschenhals liegt vor der eigentlichen Codeausführung.

---

## 2. Root Cause: Warum 0%?

### Primärer Blocker: Shell-Escaping-Bug in coder.sh (UNGEFIXT)

**Ort:** `agents/coder.sh`, Zeile 569
**Problem:** Unquotierter Heredoc (`cat <<EOF` statt `cat <<'EOF'`) interpoliert `$STEP_TEXT` und andere Variablen direkt. Wenn Task-Prompts Shell-Metazeichen enthalten (Backticks, Dollar-Zeichen aus Funktionsnamen wie `$input`, Anführungszeichen), bricht das Bash-Parsing ab.

**Konsequenz:** 100% der Tasks crashen im Coder-Schritt. Das System kann den Bug nicht selbst fixen, da es den Coder bräuchte, um Code zu schreiben — ein Henne-Ei-Problem.

### Sekundäre Probleme (teilweise bereits behoben)

| Problem | Status | Fix vom 29.03 |
|---|---|---|
| Planner-Steps zu lang (1000-2000+ Zeichen) | ✅ Behoben | MAX_STEP_CHARS=600 eingeführt |
| Dedup-Threshold zu aggressiv (80%) | ✅ Behoben | Auf 65% gesenkt |
| Pipeline-Recovery-Mechanismus fehlt | ✅ Behoben | 3 Seed-Tasks erstellt |
| Learner-Regeln zu wenige (5 aus 587 Tasks) | ⏳ Offen | Dedup-Fix sollte helfen |
| Zero-Step-Timeouts (91%) | ⏳ Offen | Planner/Execution Budget trennen |
| Task-Deduplizierung fehlt | ⏳ Offen | Title-Hash-Check nötig |

---

## 3. Sind die aktuellen Tasks umsetzbar?

### Im Registry (tasks.json): 8 Tasks

| Task | Typ | Status | Design-Qualität | Umsetzbar? |
|---|---|---|---|---|
| task-002: clamp_prompt_context Test | Test | Shelved | Gut — single file, klare Kriterien | Ja, nach Coder-Fix |
| task-003: classify_retry_failure Test | Test | Shelved | Überarbeitung nötig (30+ Cases) | Ja, mit vereinfachtem Prompt |
| task-004: learner.sh Kommentar | Edit | Shelved | Trivial | Ja |
| task-006: Planner MAX_STEP_CHARS Doku | Edit | Failed | Einfach | Ja |
| task-007: Step-Cap Validierung | Test | Failed | Gut | Ja |
| task-008: Learner-Kommentar Fix | Edit | Failed | Trivial | Ja |

### In Queue (codex-queue/): 3 Tasks

| Task | Typ | Priority | Umsetzbar? |
|---|---|---|---|
| task-130: First-Pass Success verbessern | Self-Improve | 7 | Zu abstrakt, aufteilen |
| task-131: Retry-Churn brechen | Self-Improve | 6 | Konzeptionell ok, aber Meta-Task |
| task-132: Strategy-Saturation reduzieren | Self-Improve | 4 | Meta-Task, niedrige Priorität |

**Bewertung:** Die 3 Seed-Tasks (002, 004, 006–008) sind gut designt und nach einem Coder-Fix direkt umsetzbar. Die Queue-Tasks (130–132) sind Meta-Tasks und sollten erst nach einer Proof-of-Life-Phase re-priorisiert werden.

---

## 4. Empfohlene Aktionen (priorisiert)

### KRITISCH — Manueller Eingriff (Henne-Ei-Problem)

**1. Heredoc-Bug in coder.sh fixen**

Zeile 569 ändern von:
```bash
PROMPT="$(cat <<EOF
```
zu:
```bash
PROMPT="$(cat <<'CODER_PROMPT_EOF'
```
(und entsprechend das schließende `EOF` in Zeile 630 zu `CODER_PROMPT_EOF`)

Dann alle Variablen-Referenzen ($STEP_TEXT, $TASK, etc.) durch vorherige Zuweisung und `envsubst` oder nachträgliches `sed`-Replacement ersetzen. Alternative (einfacher): Die Variablen vorher in temporäre Dateien schreiben und per `cat` einlesen.

**Achtung:** Dieser Fix muss manuell erfolgen. Das System kann ihn nicht selbst durchführen.

### HOCH — Direkt nach dem Fix

**2. Shelved Tasks re-queuen** (task-002, task-004, task-008 zuerst)
- Ziel: Mindestens 1 Success als Proof-of-Life
- task-003 vorher vereinfachen (Step-Prompt auf 5–8 Kategorien reduzieren)

**3. Planner-Timeout vom Execution-Timeout trennen**
- Aktuell teilen sich Planung und Ausführung ein 300s-Budget
- Separates 30s Planner-Budget würde Zero-Step-Timeouts drastisch reduzieren

### MITTEL — Systemverbesserungen

**4. Task-Deduplizierung einbauen** (Title-Hash vor Erstellung)

**5. Emergency Brake lockern** — Aktuell blockiert sie bei 0% + negativer Velocity ALLE Neuerstellung. Ein manueller Override für Seed-Tasks wäre sinnvoll.

---

## 5. Konfigurationsbewertung

| Parameter | Aktuell | Empfehlung |
|---|---|---|
| MAX_PROMPT_CONTEXT_CHARS | 4000 | ✅ OK (von 8000 reduziert) |
| MAX_STEP_CHARS | 600 | ✅ OK (neu eingeführt) |
| PLAN_MAX_STEPS | 6 | ✅ OK |
| TASK_TIMEOUT | 300s | ⚠️ Planner-Budget abtrennen |
| ZOMBIE_FAILURE_THRESHOLD | 5 | ✅ OK |
| MAX_RULES | 20 | ✅ OK |
| Dedup-Threshold (Learner) | 65% | ✅ OK (von 80% gesenkt) |
| Emergency Brake | Aktiv | ⚠️ Manuellen Override für Seeds erlauben |
| Approval Mode | Manual | ✅ OK für jetzige Phase |

---

## 6. Fazit

**Das Codex Agent System hat strukturell gutes Potenzial** (Non-Timeout Success Rate 23%, historischer Peak bei 26%), steht aber seit 4 Tagen in einem Deadlock, den es nicht selbst lösen kann.

**Was funktioniert:** Task-Design hat sich verbessert (konkret, dateibezogen), Anti-Meta-Task-Gate filtert abstrakte Tasks, Zombie-Guard verhindert endlose Wiederholungen, Step-Cap verhindert überladene Prompts.

**Was nicht funktioniert:** Der Coder-Heredoc-Bug (Zeile 569) crasht 100% der Ausführungen. Ohne manuellen Fix bleibt das System dauerhaft bei 0%.

**Nächster Schritt:** Heredoc-Bug manuell fixen → Seed-Tasks re-queuen → Proof-of-Life → Self-Improve reaktivieren.

---

*Report generiert: 2026-03-29 — automatisierter Scheduled Task (Run 2)*
*Vorheriger Report: 2026-03-29T00:07Z*
