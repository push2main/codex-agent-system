# Fortschrittsbericht — Codex Agent System (Scheduled Task)
**Datum:** 2026-03-28 | **Typ:** Automatischer Scheduled Check

---

## 1. Status-Übersicht

| Kennzahl | Wert | Trend |
|----------|------|-------|
| Tasks gesamt | 546 | +1 seit letztem Report |
| Erfolgsrate (all-time) | 14% | Stagniert |
| Erfolgsrate (letzte 50) | 10% | Rückgang von 12% |
| First-Pass-Rate | 40% (2/5) | Niedrig |
| Timeout-Rate | 36% | Unverändert |
| Zero-Step-Timeouts | 223 (94% aller Timeouts) | Hauptblocker |
| Pipeline-Status | **STALE seit 25.03.** | 3 Tage inaktiv |
| Aktive Alerts | retry_churn (HIGH), loop_effort (WARN), queue_starvation | Kritisch |

## 2. Sind die bisherigen Tasks umsetzbar?

**Nein — die 3 verbleibenden Queue-Tasks sind in ihrer jetzigen Form nicht lösbar.**

Die Queue enthält exakt 3 Tasks, die alle das gleiche Muster zeigen:

1. **"Improve first-pass success rate"** — zu abstraktes Ziel, kein konkreter Code-Change definiert
2. **"Break retry churn"** — richtige Diagnose, aber der Lösungsansatz ("implement exponential backoff") ist ein Multi-File-Refactor, der das Planner-Budget sprengt
3. **"Reduce strategy saturation"** — selbstreferenzieller Task (Strategy soll sich selbst drosseln)

Alle drei referenzieren große Shell-Dateien (planner.sh=33KB, orchestrator.sh=66KB, strategy-loop.sh=181KB) und verlangen komplexe Änderungen. Der Planner braucht allein 60s um den Plan zu erstellen und kommt nie zur Ausführung.

**12 shelved + 13 failed + 0 running = das System steht vollständig still.**

## 3. Wird die Success Rate gehoben?

**Nein, aktuell nicht.** Der Trend ist rückläufig:

- Window 451-500: **26%** (bester Wert nach Anfangsphase)
- Window 501-546: **11%** (aktueller Einbruch)
- Letzte 50: **10%** (unter dem All-Time-Schnitt von 14%)

Die 5 gelernten Rules haben kurzfristig geholfen (Window 451-500), aber der Effekt ist verpufft. Ursache: die Rules adressieren Symptome (scope_mismatch, stale counts), aber nicht die Kernprobleme (Planner-Overhead, abstrakte Task-Generierung).

## 4. Diagnose: Drei Kernprobleme

### Problem A: Selbstheilungs-Deadlock
Das System generiert Meta-Tasks ("Improve X", "Reduce Y"), die genauso komplex sind wie die originalen Tasks. 8 von 13 failed Tasks sind stability-Kategorie. Das System kann sich nicht selbst reparieren, weil die Reparatur-Tasks an denselben Problemen scheitern.

### Problem B: Planner-Starvation (94% Zero-Step-Timeouts)
223 von 237 Timeouts passieren, bevor auch nur ein Schritt ausgeführt wird. Der Planner verbraucht das gesamte Budget mit Plan-Erstellung. Selbst der existierende 60s-Cap greift nicht, weil der Planner beim Parsen großer Dateien (strategy-loop.sh=181KB!) das Budget überzieht.

### Problem C: Strategy Regeneration Loop
Die Queue-Stale-Blocklist und die Queue zeigen dieselben 3 Tasks, die immer wieder regeneriert werden. Der Strategy-Cooldown (24h) ist zu kurz — nach 24h generiert die Engine denselben unlösbaren Task erneut.

## 5. Empfohlene Modifikationen

### Sofort (manuell, kein Code-Change nötig)

1. **Alle 13 failed Meta-Tasks shelven** — sie blockieren die Pipeline und sind nicht lösbar
2. **Die 3 Queue-Tasks durch konkrete Micro-Tasks ersetzen**, z.B.:
   - "In agents/planner.sh: PLAN_TIMEOUT_SECONDS von 60 auf 30 ändern"
   - "In agents/orchestrator.sh: MAX_RETRIES von 2 auf 1 für stability-Tasks ändern"
   - "In scripts/strategy-loop.sh: COOLDOWN_HOURS von 24 auf 72 ändern"

### System-Konfiguration

3. **Planner-Budget halbieren (60s → 30s)** mit hartem 2-Step-Fallback. Lieber ein simpler Plan, der ausgeführt wird, als ein perfekter Plan, der nie fertig wird.
4. **Strategy-Cooldown verdreifachen (24h → 72h)** für stability-Tasks, um den Regeneration Loop zu brechen.
5. **Neue Learned Rule hinzufügen:**
   > "Tasks dürfen maximal 1 Datei referenzieren und das Erfolgskriterium muss als einzelner bash-Befehl prüfbar sein (z.B. 'bash -n file.sh exits 0'). Abstrakte Ziele ('improve X rate') sofort als scope_mismatch ablehnen."

### Architektur (mittelfristig)

6. **Strategy Engine auf datei-bezogene Micro-Changes umstellen:** Statt "Improve first-pass success rate" → "In agents/planner.sh Zeile 142: if-Guard für Timeout >30s einfügen"
7. **Provider claude für stability-Tasks bevorzugen** (62.5% Success vs. codex 6.4%) — aktuell werden fast alle stability-Tasks an codex geroutet, der dafür schlechter geeignet ist.

## 6. Fazit

**Das System hat eine solide Diagnostik-Infrastruktur**, aber es steckt seit 3 Tagen in einem Deadlock. Die Success Rate fällt (10% vs. 14% all-time), die Pipeline steht still, und die Queue enthält nur unlösbare abstrakte Tasks.

**Ohne manuellen Eingriff wird sich nichts ändern.** Die drei konkreten Sofort-Maßnahmen (failed Tasks shelven, Micro-Tasks einspeisen, Planner-Budget halbieren) könnten die Pipeline innerhalb eines Tages wieder in Bewegung bringen.

| Priorität | Maßnahme | Erwarteter Effekt |
|-----------|----------|-------------------|
| P0 | Failed Meta-Tasks shelven + Pipeline clearen | Pipeline entblockieren |
| P1 | Planner-Budget 60s→30s + 2-Step-Fallback | Zero-Step-Timeouts um ~50% senken |
| P1 | Strategy-Cooldown 24h→72h für stability | Regeneration Loop brechen |
| P2 | Micro-Task Design Rule als Learned Rule | Langfristig bessere Task-Qualität |
| P2 | Provider-Routing: stability→claude | Success-Rate für stability heben |
