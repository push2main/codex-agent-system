# Fortschrittsbericht — Codex Agent System
## Scheduled Run: 2026-03-28 (Nachmittag)

---

## Systemstatus: KRITISCH — Pipeline steht, 0% Recent Success

Das System ist technisch intakt (Diagnostik, Klassifizierung, Provider-Routing funktionieren), aber strategisch blockiert. Seit 4 Tagen wurde kein Task erfolgreich abgeschlossen. Self-Improve ist korrekt pausiert.

---

## Kernmetriken

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Erfolgsrate gesamt | 14% (81/575) | Schlecht |
| Erfolgsrate letzte 50 | 0% | Kritisch |
| First-Pass-Rate | 0% | Kritisch |
| Timeout-Rate | 36% | Hoch |
| Zero-Step-Timeouts | 91% aller Timeouts | Kritisch |
| Pipeline-Status | Stale seit 2026-03-24 | Kritisch |
| Registry-Druck | 70KB (gesund) | OK |
| Aktive Tasks | 1 (pending_approval) | Niedrig |
| Self-Improve | PAUSIERT | Korrekt |

---

## Sind die bisherigen Tasks umsetzbar?

### Kurz: Nein — die meisten Tasks im System sind zu abstrakt oder recycled.

**Konkret:**

1. **6 Meta-Tasks (146–151)** mit je 7 Versuchen sind nicht umsetzbar. Titel wie "Improve first-pass success rate" oder "Break retry churn" haben kein konkretes Zielfile und keinen testbaren Erfolgskriterium. Diese sollten endgültig geshelved werden.

2. **3x duplizierte "Reduce timeout rate" Tasks** mit unterschiedlichen IDs — der Zombie-Guard erkennt sie nicht, weil er auf Task-ID statt auf Titel-Ähnlichkeit prüft.

3. **1 umsetzbarer Task:** task-001 (Review OpenAI Python v2.30.0 Signal) — begrenzter Scope, konkretes Ziel, Effort 2. Dieser ist approvable.

4. **Historisch umsetzbar waren:** Tasks mit genau 1-2 Dateireferenzen und einem testbaren Bash-Kommando als Erfolgskriterium (z.B. `bash -n file.sh exits 0`).

---

## Warum steigt die Success-Rate nicht?

### Drei Kernprobleme blockieren den Fortschritt:

**Problem 1: Planner-Starvation (höchster Impact)**
- 91% aller Timeouts passieren VOR dem ersten Step
- Der Planner verbraucht das gesamte Timeout-Budget beim Planen
- Ursache: Oversized Context — strategy-loop.sh (181KB), orchestrator.sh (66KB), planner.sh (33KB) werden geparst
- MAX_PROMPT_CONTEXT_CHARS wurde auf 8KB reduziert, aber die Agent-Scripts selbst sind zu groß

**Problem 2: Self-Healing-Deadlock**
- System generiert Meta-Tasks zur Selbstverbesserung
- Diese Meta-Tasks scheitern mit derselben Rate wie reguläre Tasks
- 8 von 13 gescheiterten Tasks sind stability-category Self-Improvements
- System kann sich nicht selbst reparieren

**Problem 3: Strategy-Regeneration-Loop**
- Dieselben 3 Queue-Tasks werden nach 24h Cooldown neu generiert
- Duplicate-Detection versagt (unterschiedliche IDs, gleiche Titel)
- 24h Cooldown ist zu kurz für wiederholt gescheiterte Szenarien

---

## Empfohlene Modifikationen

### Sofort (P0) — System-Konfiguration

1. **Planner Hard-Timeout auf 45s senken** (von 60s) mit 2-Step-Fallback
   - Eliminiert geschätzt 91% der Zero-Step-Timeouts
   - Erwartete Success-Rate-Verbesserung: 0% → 15-20%
   - Datei: `agents/planner.sh`

2. **Retry-Limit von 7 auf 3 senken**
   - Daten zeigen: Tasks die nach 3 Versuchen scheitern, schaffen es auch nach 7 nicht
   - Spart Rechenzeit und verhindert Churn

3. **Zombie-Guard auf Titel-Ähnlichkeit umstellen** (statt ID-basiert)
   - Levenshtein-Distance oder Keyword-Overlap >70%
   - Verhindert die 3x-Duplikat-Situation

### Mittelfristig (P1) — Task-Design-Regeln

4. **Neue Learned Rule hinzufügen:**
   > "Tasks müssen genau 1-2 spezifische Dateien referenzieren. Tasks ohne Dateireferenz werden sofort rejected. Erfolgskriterium muss als einzelnes Bash-Kommando testbar sein."

5. **Strategy-Cooldown auf 72h erhöhen** für stability-category Tasks
   - Bricht den Regeneration-Loop

6. **Provider-Routing für stability-Tasks:** Route zu `claude` (62.5% Erfolg) statt `codex` (6.4%)

### Langfristig (P2) — Architektur

7. **Agent-Script-Größe reduzieren:** strategy-loop.sh (181KB) und lib.sh (334KB) sind zu groß für den Planner-Context. Modularisierung in kleinere Einheiten.

8. **Self-Improve erst re-enablen** wenn Recent Success Rate >10% erreicht ist (aktuell 0%).

---

## Gesamtbewertung

| Dimension | Note | Trend |
|-----------|------|-------|
| Diagnostik & Klassifizierung | A | Stabil |
| Infrastruktur | B | Stabil |
| Provider-Routing | C+ | Stabil |
| Task-Design-Qualität | D | Fallend |
| Execution Success | F | Fallend |
| Pipeline-Gesundheit | F | Stale |
| Recovery-Fähigkeit | D | Blockiert |

**Gesamtnote: D+** — Die Diagnostik-Qualität rettet das System vor einem F. Die Execution ist gebrochen, aber die Ursachen sind identifiziert und die Fixes sind konkret.

**Nächster Meilenstein:** Planner-Timeout-Cap implementieren und 3 konkrete Single-File-Tasks mit testbarem Erfolgskriterium erstellen. Ziel: >0% Recent Success Rate innerhalb der nächsten 10 Runs.

---

*Automatisch generiert — Scheduled Task "fortschritt-tasks-und-system"*
