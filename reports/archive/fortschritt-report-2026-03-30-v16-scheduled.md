# Fortschrittsbericht — 30. März 2026, v16 (Scheduled)

## Systemstatus: PIPELINE STALL — Queues leer, Cooldowns blockieren seit 111h

---

## Kennzahlen

| Metrik | Wert | Bewertung |
|---|---|---|
| Tasks gesamt (historisch) | 641 | — |
| All-time Success Rate | 17% | niedrig |
| Recent-50 Success Rate | 52% | **deutlich verbessert** |
| First-Pass Success Rate | 62% | **gut** |
| Letzte Window (601–641) | **54%** | **Bestwert aller Windows** |
| Timeout-Rate | 33% (210 von 641) | weiterhin hoch |
| Zero-Step-Timeouts | 227 (91% aller Timeouts) | **Hauptproblem** |
| Zombie Tasks | 20 (166 verschwendete Slots) | signifikanter Waste |
| Retry-Churn | aktiv erkannt | Loop-Effort: 8 Tasks, 12 Extra-Attempts |
| Queue codex-agent-system | **LEER** | KRITISCH |
| Queue superheld | **LEER** | KRITISCH |
| Cooldown-Alter | **~111 Stunden** | KRITISCH — seit 4,6 Tagen blockiert |
| Learned Rules | 5 | stabil |
| Knowledge Base | 199 Einträge | wächst |

---

## 1. Trend-Analyse: Success Rate über Zeit

Die Iteration-Windows zeigen einen klaren positiven Trend:

| Window | Rate | Timeouts |
|---|---|---|
| 1–50 | 34% | 19 |
| 51–100 | 4% | 5 |
| 101–150 | 6% | 33 |
| 151–200 | 4% | 38 |
| 201–250 | 16% | 34 |
| 251–300 | 10% | 23 |
| 301–350 | 14% | 5 |
| 351–400 | 12% | 12 |
| 401–450 | 22% | 29 |
| 451–500 | 26% | 20 |
| 501–550 | 10% | 23 |
| 551–600 | 14% | 8 |
| **601–641** | **54%** | **1** |

Das letzte Window (601–641) ist mit 54% und nur 1 Timeout der Bestwert. Die Improvement-Velocity liegt bei +2.92pp pro 100 Tasks. Non-Timeout Success Rate: 28% (steigend mit +4.43pp/100).

**Fazit: Die Success Rate steigt nachweislich**, besonders wenn Timeouts ausgeschlossen werden.

---

## 2. Sind die bisherigen Tasks umsetzbar?

**Ja, grundsätzlich schon.** Die letzten 41 Tasks zeigen 54% Erfolgsrate. Die Failure-Analyse der jüngsten 10 Einträge zeigt aber wiederkehrende Muster:

### Häufigste Failure-Typen (jüngste Failures):

1. **review_rejection** (7 von 10): Coder führt Edits durch, wo nur Inspektion verlangt war, oder verletzt Inspection-Boundaries
2. **missing_dependency** (3 von 10): Verification-Commands verwenden `python` statt `python3`, oder Schemas fehlen erwartete Properties

### Konkrete Probleme:
- **Inspection-vs-Edit Confusion**: Tasks die "Inspect only" verlangen, werden trotzdem editiert (task-018, task-028, task-023)
- **Python/Python3 Mismatch**: Verification-Steps verwenden `python` obwohl nur `python3` verfügbar ist (task-025)
- **Schema-Violations**: Edits fügen Properties ein, die `additionalProperties: false` verletzen (task-023)

---

## 3. Kritische Blocker

### BLOCKER 1: Cooldown-Deadlock (111 Stunden)
Alle drei Cooldown-Files sind seit ~4,6 Tagen aktiv:
- `self-improve-cooldown` (Timestamp: 1774503742)
- `self-improve-codex-agent-system-cooldown`
- `self-improve-superheld-cooldown`

**Auswirkung**: `self-improve-run.json` zeigt `dominant_reason: cooldown_active`. Keine neuen Tasks werden generiert. Beide Queues sind vollständig leer. Die Pipeline ist de facto tot.

### BLOCKER 2: Leere Queues
Sowohl `codex-agent-system.txt` als auch `superheld.txt` sind komplett leer. Ohne neue Task-Generierung (blockiert durch Cooldowns) kann nichts ausgeführt werden.

### BLOCKER 3: Zero-Step-Timeouts dominieren
91% aller Timeouts (227 von ~250) sind Zero-Step — der Planner verbraucht das gesamte Budget bevor ein Step ausgeführt wird. Das ist der größte einzelne Failure-Mode.

---

## 4. Empfohlene Modifikationen

### SOFORT (manueller Eingriff nötig):

**A) Cooldown-Files löschen:**
```bash
rm codex-logs/self-improve-cooldown
rm codex-logs/self-improve-codex-agent-system-cooldown
rm codex-logs/self-improve-superheld-cooldown
```
Dies ist der wichtigste einzelne Schritt. Ohne ihn bleibt die Pipeline stehen.

**B) strategy-timeout-cooldown.state prüfen und ggf. löschen:**
```bash
rm codex-logs/strategy-timeout-cooldown.state
```

### SYSTEM-KONFIGURATION:

**C) Planner: Inspection-Steps klarer formulieren:**
Die häufigste Failure-Ursache (review_rejection wegen Edit statt Inspection) ließe sich durch eine explizitere Planner-Instruktion reduzieren:
- Regel vorschlagen: "Steps mit 'Inspect only' oder 'Expected: you identify' dürfen KEINE Datei-Edits enthalten. Der Coder muss das Ergebnis als Text-Output liefern, nicht als File-Change."

**D) Verification-Commands: python → python3:**
Mehrere Tasks scheitern, weil `python` nicht verfügbar ist. Die Planner-Prompts sollten `python3` als Default verwenden.

**E) Zero-Step-Timeout Guard (bereits in CLAUDE.md als Regel):**
Die 60s Planning-Cap Regel existiert in CLAUDE.md, wird aber offenbar nicht durchgesetzt. Der Planner braucht ein hartes Timeout.

### TASK-QUALITÄT:

**F) Zombie-Tasks endgültig blockieren:**
20 Zombie-Tasks verschwenden Kapazität. Die Zombie-Guard-Regel (5+ Failures → shelve) existiert, aber "Inventory current decision path" wird trotzdem regeneriert. Der Generator muss Zombie-Titel in einer Blocklist führen.

**G) Provider-Routing auf aktuelle Daten aktualisieren:**
Die Routing-Daten basieren auf kleinen Sample-Sizes (z.B. claude 0/3 für auth). Mit 641 Tasks sollte ein Refresh der Routing-Statistiken durchgeführt werden.

---

## 5. Gesamtbewertung

| Aspekt | Status | Trend |
|---|---|---|
| Success Rate | 54% (letztes Window) | ↑ stark steigend |
| Task-Qualität | mittel — Inspection/Edit-Confusion | → stagnierend |
| Pipeline-Durchsatz | **0** (Queues leer) | ↓ gestoppt |
| Self-Learning | funktional, 199 Knowledge-Einträge | → stabil |
| Timeout-Rate | 33% gesamt, **1 im letzten Window** | ↑ verbessert |

**Kernaussage**: Das System hat sich qualitativ stark verbessert (54% Success im letzten Window vs. 4–6% in der Mitte). Aber die Pipeline steht seit 4,6 Tagen komplett still wegen Cooldown-Deadlock. Der wichtigste Schritt ist das Löschen der Cooldown-Files, damit neue Tasks generiert und ausgeführt werden können. Danach sollten die Planner-Instruktionen für Inspection-Steps verschärft und der python→python3 Mismatch behoben werden.
