# Fortschrittsbericht — 2026-03-26T21:00Z (Scheduled Task v2)

## TL;DR

Das System **lernt messbar dazu** (Non-Timeout Velocity +6.8pp/100 Tasks), wird aber durch **Infrastruktur-Deadlocks blockiert**. Die Pipeline steht seit 36+ Stunden still. Drei konkrete Fixes sind nötig, bevor die Success-Rate weiter steigen kann.

---

## 1. Aktueller Systemstatus

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Pipeline | **IDLE seit ~36h** | KRITISCH |
| Laufende Tasks | 0 | Blockiert |
| Queued Tasks | 3 | Warten auf Dispatch |
| Pending Approval | 0 | — |
| All-time Success Rate | 15% (79/526) | Baseline |
| Recent Success Rate (50) | 28% | ↑ Aufwärtstrend |
| Non-Timeout Success | 27% | ↑ +6.8pp/100 |
| Timeout-Rate | 37% (197/526) | Hauptproblem |
| Learned Rules | 20/20 (voll) | Kapazitätsgrenze |
| Classification Coverage | 100% | Vollständig |
| Zombie Tasks (geshelved) | 18 | Waste eliminiert |

---

## 2. Sind die bisherigen Tasks umsetzbar?

### Aktive Tasks im Registry

| Task | Score | Umsetzbar? | Begründung |
|------|-------|------------|------------|
| task-002: Recover stale pipeline | 4.9 | **JA** | Adressiert den aktuellen Deadlock direkt |
| task-004: Cap pre-step planning budget | 4.9 | **JA, höchster Impact** | 94% der Timeouts = Zero-Step (Planner-Phase). Das ist DER Hebel |
| task-005: Improve first-pass success | 4.9 | **BEDINGT** | Zu breit formuliert, müsste in Einzelschritte gesplittet werden |
| task-007: Drain approved backlog | 2.8 | **NEIN, löschen** | Basiert auf falschem Signal (cross-project Metrik, lokal 0 approved) |

**Empfehlung:** task-004 zuerst ausführen (adressiert 94% der Timeouts), task-007 entfernen, task-005 in kleinere Schritte aufteilen.

---

## 3. Heben wir die Success-Rate?

**Ja, eindeutig.** Die Zahlen zeigen einen klaren Aufwärtstrend:

```
Window   Rate   Timeouts   Phase
1-50     34%    19         Initial (hohe Erwartungen, einfache Tasks)
51-100    4%     5         Crash (Provider-Routing-Krise)
101-200   5%    71         Tiefpunkt (Timeout-Dominanz beginnt)
201-300  13%    57         Recovery beginnt
301-400  13%    17         Stabilisierung, Timeout-Reduktion
401-500  24%    49         Starker Anstieg, Learning greift
501-526  19%    19         Leichter Rückgang (Pipeline-Deadlock)
```

**Kernaussage:** Die Non-Timeout Velocity von **+6.8pp pro 100 Tasks** ist der wichtigste Indikator. Das System wird bei jeder Iteration besser — wenn es Tasks tatsächlich ausführen kann. Der aktuelle Rückgang (501-526: 19%) ist durch den Pipeline-Stillstand erklärbar, nicht durch Qualitätsverlust.

---

## 4. Notwendige Modifikationen

### KRITISCH (Pipeline-Blocker)

**A) Auto-Approval aus Cooldown-Block herauslösen**
- **Problem:** Auto-Approval-Code liegt innerhalb des Timeout-Cooldown-Blocks in strategy-loop.sh. Wenn kein Cooldown aktiv ist, wird Auto-Approval nie ausgeführt.
- **Fix:** Auto-Approval als eigenständige Funktion VOR den Cooldown-Check ziehen. Muss immer laufen wenn `pipeline_stale=true` ODER `zero_queue` (0 approved + 0 running + 0 queued).
- **Impact:** Pipeline kann wieder starten.

**B) Zero-Queue Escape Hatch verifizieren**
- **Problem:** Iteration 21 hat einen Escape-Hatch für den Health-Gate-Deadlock implementiert (wenn queue=0 UND running=0, Health-Flags ignorieren).
- **Status:** Code geschrieben, bash -n validiert, aber noch nicht im laufenden System getestet.
- **Impact:** Verhindert zukünftige Deadlocks.

### HOCH (Performance)

**C) Staleness-Tracking separieren**
- **Problem:** Ancillary-Prozesse (self-improve, compact-registry) schreiben in den Task-Log und setzen damit den Staleness-Timer zurück, obwohl kein echter Task-Fortschritt stattfindet.
- **Fix:** `last_successful_execution_at` separat tracken, unabhängig von Log-Timestamps.
- **Impact:** Deadlock-Erkennung wird zuverlässiger.

**D) Provider-Health prüfen**
- **Problem:** 1044x "claude print failed" Fehler im Log. Falls der Claude-Provider nicht erreichbar ist, scheitern alle Tasks die über Claude geroutet werden.
- **Fix:** Provider-Health-Check vor Task-Dispatch; automatischer Fallback auf alternativen Provider.

### MITTEL (Optimierung)

**E) Learned Rules konsolidieren**
- **Status:** 20/20 Slots voll. Einige frühe Regeln sind durch spätere Infrastruktur-Fixes obsolet geworden.
- **Fix:** Regelset auditieren, obsolete Regeln entfernen, Platz für neue Learnings schaffen.

**F) Cooldown-Deduplication**
- **Problem:** Timeout-Cooldown re-armed sich alle 5 Minuten basierend auf denselben historischen Log-Einträgen.
- **Fix:** `last_cooldown_trigger_marker` tracken, Re-Arming mit gleicher Marker-ID überspringen.

---

## 5. Systemarchitektur-Bewertung

| Komponente | Status | Note |
|-----------|--------|------|
| Learning-Algorithmus | ✅ Funktioniert | +6.8pp/100, 198 Knowledge-Items |
| Failure Classification | ✅ 100% Coverage | War 24%, jetzt vollständig |
| Provider Routing | ✅ Aktiv | 8 Kategorien korrekt geroutet |
| Zombie Guard | ✅ Effektiv | 18 Tasks geshelved, 156 Retry-Slots gespart |
| Auto-Approval | ❌ Defekt | Cooldown-Bug blockiert Pipeline |
| Health Gates | ⚠️ Deadlock-anfällig | Escape-Hatch implementiert, ungetestet |
| Staleness Detection | ⚠️ Unzuverlässig | Log-Aktivität ≠ Task-Fortschritt |
| Self-Improve | ⚠️ 0% Erfolg | Single-File-Regel hinzugefügt, ungetestet |
| External Signals | ⚠️ Stale | Letzte Aktualisierung 3 Tage alt |

---

## 6. Prognose

**Wenn Fixes A+B deployed werden:**
- Pipeline startet innerhalb von Minuten
- task-004 (Planning-Budget-Cap) kann ausgeführt werden
- Erwarteter Impact: Timeout-Rate sinkt von 37% auf ~15-20%
- Gesamt-Success-Rate steigt auf ~25-30%

**Ohne Fixes:**
- Pipeline bleibt auf unbestimmte Zeit blockiert
- Keine neuen Tasks werden ausgeführt
- Success-Rate stagniert bei 15% all-time

**Mittelfristig (nächste 100 Tasks):**
- Mit Planning-Budget-Cap: Non-Timeout Success ~35%+ erreichbar
- Mit Provider-Health-Fix: Weitere 5-10pp möglich
- Realistisches Ziel: 30-35% Gesamt-Success-Rate

---

## Fazit

Das codex-agent-system hat ein **funktionierendes Lernsystem** aufgebaut — die Daten belegen das eindeutig. Der Engpass liegt nicht bei der Task-Qualität oder dem Learning, sondern bei **zwei konkreten Infrastruktur-Bugs** (Auto-Approval-Cooldown-Bug und Health-Gate-Deadlock). Die Fixes aus Iteration 21 adressieren beide Probleme, sind aber noch nicht im laufenden System aktiv. Priorität 1 ist das Deployment dieser Fixes, danach die Ausführung von task-004 (Planning-Budget-Cap) als höchstem Impact-Task.
