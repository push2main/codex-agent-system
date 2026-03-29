# Fortschrittsbericht — Codex Agent System
## 2026-03-28, 23:00 UTC (automatisiert, Update #2)

---

## 1. Systemstatus: BLOCKIERT — Coder-Agent crasht bei jeder Ausführung

Das System hat seit dem letzten Bericht (20:06 UTC) einen neuen Lauf mit 3 konkreten Seed-Tasks durchgeführt. **Alle 3 Tasks sind gescheitert** — aber diesmal ist die Ursache eindeutig identifiziert.

| Metrik | Wert | Δ seit letztem Report |
|---|---|---|
| Gesamt-Tasks | 581 | +6 Versuche |
| All-time Success Rate | 14% | unverändert |
| Recent Success Rate (letzte 50) | **0%** | unverändert |
| Timeout-Rate | 35% | leicht verbessert |
| Pipeline stale seit | 2026-03-25 | 3+ Tage |
| Aktive Tasks | 3 failed, 2 shelved | — |
| Queue | **leer** | drained |
| Retry-Churn | **aktiv** (HIGH severity) | neu erkannt |

---

## 2. Kritischer Befund: Shell-Escaping-Bug in coder.sh

**Alle 6 Ausführungsversuche (3 Tasks × 2 Retries) scheitern an identischem Fehler:**

```
coder.sh: line 650: unexpected EOF while looking for matching `'`
```

### Root Cause

In `agents/coder.sh`, Zeilen 569–630, wird der Coder-Prompt über ein **unquoted Heredoc** (`cat <<EOF`) aufgebaut. Die Variable `$STEP_TEXT` (Zeile 573 und 621) wird direkt interpoliert. Wenn der Step-Text Shell-Metazeichen enthält (einfache Anführungszeichen, Backticks, Dollar-Zeichen aus Funktionsnamen wie `clamp_prompt_context "$input"`), bricht die Bash-Parsing-Phase ab.

**Das ist ein systemischer Blocker.** Solange dieser Bug existiert, kann KEIN Task den Coder-Schritt durchlaufen.

### Betroffene Tasks

| Task | Versuche | Ergebnis | Evaluator-Befund |
|---|---|---|---|
| task-002: clamp_prompt_context Test | 2 | review_rejection | "function exists, task is feasible, coder failed to create file" |
| task-003: classify_retry_failure Test | 2 | review_rejection | coder crashed before file creation |
| task-004: learner.sh Kommentar-Fix | 2 | review_rejection | coder crashed before file creation |

---

## 3. Sind die Tasks umsetzbar?

**Ja — die Tasks selbst sind gut designt, das Problem liegt im System.**

- **Task-002** (clamp_prompt_context Test): Evaluator bestätigt Machbarkeit. Funktion existiert, Task ist klar definiert.
- **Task-003** (classify_retry_failure Test): Grundsätzlich machbar, aber Step-Prompt ist überladen (30+ Test-Cases in einem Step). Sollte auf 5–8 Kern-Kategorien reduziert werden.
- **Task-004** (learner.sh Fix): Trivial umsetzbar, aber mit niedrigem Impact auf die Success-Rate.
- **Task-001** (External Signal): Korrekt geshelved — Meta-Tasks helfen nicht bei 0%.
- **Task-005** (Queue-Buffer): Korrekt geshelved (Zombie: 26 Fehlversuche).

---

## 4. Success-Rate-Trend

| Fenster | Rate | Timeouts |
|---|---|---|
| Tasks 1–50 | 34% | 19 |
| Tasks 401–450 | 22% | 29 |
| Tasks 451–500 | 26% | 20 |
| Tasks 501–550 | 10% | 23 |
| Tasks 551–581 | **0%** | 4 |

**Improvement Velocity: −0.69pp pro 100 Tasks** — System verschlechtert sich.
Die "+1.7pp" Trendmeldung in CLAUDE.md ist irreführend (misst Gesamthälften, nicht aktuelle Richtung).

---

## 5. Empfohlene Modifikationen (priorisiert)

### KRITISCH — Muss sofort passieren

**1. Coder-Heredoc-Bug fixen** (`agents/coder.sh`, Zeilen 569–630)

Option A: Heredoc quoten und Variablen per `envsubst` einsetzen:
```bash
export STEP_TEXT TASK PLAN_JSON ...
PROMPT="$(envsubst < agents/coder-prompt.template)"
```

Option B: Prompt-Variablen über `printf` oder `jq` zusammensetzen statt Shell-Interpolation:
```bash
PROMPT="$(jq -rn --arg step "$STEP_TEXT" --arg task "$TASK" '...')"
```

Option C (Minimal): `$STEP_TEXT` vor Injection sanitieren:
```bash
SAFE_STEP="$(printf '%s' "$STEP_TEXT" | sed "s/'/'\\\\''/g")"
```

### HOCH — Nach dem Bug-Fix

**2. Step-Prompt-Länge begrenzen (max 500 Zeichen)**
- Task-003 hat einen Step mit 30+ Test-Cases — das überfordert sowohl Shell-Escaping als auch den Coder-Agenten.
- Komplexe Testdaten sollten in eine referenzierte Datei ausgelagert werden.

**3. Gescheiterte Tasks re-queuen**
- Nach dem Bug-Fix: task-002, task-003 (vereinfacht), task-004 erneut ausführen.
- Ziel: Mindestens 1 erfolgreicher Task als Beweis, dass die Pipeline wieder funktioniert.

### MITTEL — System-Verbesserungen

**4. Planner-Timeout separieren** — Zero-step-Timeouts (91%) zeigen, dass der Planner das Execution-Budget verbraucht. Separates Planner-Budget von 30s einführen.

**5. Learner-Dedup lockern** — Nur 5 Regeln aus 575 Tasks. Similarity-Threshold von 80% auf 90% erhöhen.

**6. CLAUDE.md Trend-Daten korrigieren** — "IMPROVING" entfernen, durch aktuelle Velocity-Daten ersetzen.

---

## 6. Fazit

**Das System hat einen konkreten, behebbaren Bug.** Im Gegensatz zum letzten Bericht, wo das Problem diffus war (Meta-Task-Loop, leere Outputs), gibt es jetzt einen klaren Einzelpunkt:

Der Shell-Escaping-Bug in `agents/coder.sh` blockiert ALLE Task-Ausführungen. Die heutigen Seed-Tasks (konkret, dateibezogen, single-objective) sind richtig designed und folgen den Learned Rules. Sie scheitern nicht am Task-Design, sondern an der kaputten Prompt-Injection im Coder.

**Nächster Schritt:** Den Heredoc-Bug fixen → Failed Tasks re-queuen → Erste Success messen → Dann weiter optimieren.

---
*Report generiert: 2026-03-28T23:00Z — automatisierter Fortschritts-Check*
*Vorheriger Report: 2026-03-28T20:06Z*
