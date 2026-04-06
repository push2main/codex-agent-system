# Fortschritt-Report — 2026-04-01 v8 (Scheduled)

## Zusammenfassung

Das System befindet sich in einem **funktionalen Stillstand**: Die Execution-Engine arbeitet zuverlässig (94% SR historisch, Superheld 13/13 completed), aber der Feedforward-Mechanismus ist gebrochen. Beide Queues sind leer (0 Bytes), Self-Improve ist durch Cooldown blockiert, und der Task-Generator produziert ausschließlich Duplikate. Ohne manuellen Eingriff läuft das System im Leerlauf weiter.

## Kernkennzahlen

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| All-time SR | 25% (721 Tasks lt. metrics.json) | Historisch belastet |
| Recent-50 SR (CLAUDE.md) | 94% | Bezieht sich auf älteres Window |
| Archiv letzte 50 | 0 completed, 17 failed, 30 shelved, 2 rejected | KRITISCH |
| First-Pass SR | 76% | Nahe am 80%-Ziel |
| Timeout-Rate | 29% historisch, 0% aktuell | Gelöst |
| Aktive Registry | 11 Tasks: 4 completed, 7 shelved | Stagniert |
| Queues | Beide leer (0 Bytes), Tag 5+ | DEADLOCK |
| Superheld-Projekt | 13/13 Tasks completed | Abgeschlossen |
| Registry-Pressure | 289 KB (unter 512 KB Limit) | OK |

## Sind die Tasks umsetzbar?

### Aktive Registry — 11 Tasks

**4 Completed** (006, 007, 008, 011): Kleine Code-Quality/Testing-Tasks — erfolgreich.

**7 Shelved** — Bewertung:

| ID | Task | Umsetzbar? | Empfehlung |
|----|------|-----------|------------|
| 002 | Test context clamp 4K | Ja — klar definiert, einzelne Datei | Reaktivieren |
| 003 | Test classify_retry_failure | Ja — klar definiert | Reaktivieren |
| 004 | Fix learner rule count | Ja — einfacher Kommentar-Fix | Reaktivieren |
| 001 | Review OpenAI Python v2.30 | Nein — externer Signal, veraltet (26.03.) | Entfernen |
| 005 | System-work buffer | Nein — 348x dupliziert, Zombie | Permanent entfernen |
| 009 | Inventory cap pre-step | Nein — Meta-Task ohne konkretes Ziel | Entfernen |
| 010 | Reduce timeout rate | Veraltet — Timeout-Rate ist 0% | Entfernen |

### Archiv-Zombie-Muster (letzte 100 Tasks)

| Task-Familie | Wiederholungen | Status |
|-------------|---------------|--------|
| "Inventory: improve first-pass SR" | 21x | Alle shelved/failed |
| "Inventory: recover stale pipeline" | 13x | Alle shelved/failed |
| "Reduce timeout rate" | 10x | Alle shelved/failed |
| "Cap pre-step planning budget" | 6x | Alle shelved/failed |
| "Break retry churn" | 4x | Alle shelved/failed |

## Erhöhen wir die Success Rate?

**Nein — die Rate stagniert effektiv.**

Die Engine *kann* 94% SR liefern, wenn sie gute Tasks bekommt. Aber der Task-Generator ist defekt: Er produziert Duplikate, die sofort geshelved werden. Die Archiv-SR der letzten 50 (0% completed) zeigt klar, dass das Problem bei der Task-Generierung liegt, nicht bei der Execution.

Positiv: First-Pass SR ist von 73% auf 76% gestiegen. Die Learner-Rules (5 von 20 Slots belegt) und 199 Knowledge-Einträge wirken.

## Diagnose: Dreifach-Deadlock

```
                    ┌──────────────┐
                    │ Self-Improve │
                    │  BLOCKIERT   │
                    │ (Cooldown +  │
                    │ leere Memory)│
                    └──────┬───────┘
                           │ generiert keine Tasks
                           ▼
┌──────────────┐    ┌──────────────┐
│   Queues     │◄───│ Task-Generator│
│    LEER      │    │   DEFEKT     │
│  (Tag 5+)    │    │ (nur Duplikate│
└──────┬───────┘    │  die sofort   │
       │            │  shelved)     │
       │ kein Input └──────────────┘
       ▼
┌──────────────┐
│   Engine     │
│   IDLE       │
│ (94% bereit) │
└──────────────┘
```

### Root Causes:
1. **Self-Improve Cooldown** blockiert neue Analyse-Runs (`dominant_reason: cooldown_active`)
2. **Automation Memory leer** (`source: none`, `external_hydrated: false`) — kein Kontext für Task-Generierung
3. **Zombie-Guard zu schwach** — 348x "system-work buffer" Duplikat vor dem Shelving
4. **Superheld fertig** aber System versucht weiterhin Verifikations-Tasks (letzte Runs 109–118)

## Notwendige Modifikationen

### PRIORITÄT 1: Pipeline-Deadlock auflösen

| Maßnahme | Aufwand | Wirkung |
|----------|---------|---------|
| Queue-Starvation-Bypass: wenn Queue >24h leer AND Registry <3 pending → Cooldown überspringen | Mittel | Bricht den Zirkelschluss |
| Automation Memory rehydrieren (externe Signale, aktuelle Metriken laden) | Gering | Self-Improve bekommt Kontext |
| Zombie-Guard-Schwelle von 5 auf 3 senken + Titel-Hash gegen Archiv prüfen VOR Generierung | Gering | Stoppt Duplikat-Flut |

### PRIORITÄT 2: Superheld-Loop stoppen

Das Superheld-Projekt ist 13/13 completed. Trotzdem laufen Verifikations-Tasks weiter (letzter Run: `20260401-070125`, Duration 241s).

Maßnahme: Projekt als "completed" markieren, aus aktiver Rotation nehmen.

### PRIORITÄT 3: Task-Diversität sicherstellen

Der Generator braucht neue Arbeit. Optionen:
- Neues Projekt registrieren (z.B. weiteres Repo)
- External-Signal-Sources aktualisieren (letzte Aktualisierung: 26.03.)
- Learner-Rules-Slots besser nutzen (5/20 belegt)
- First-Pass SR von 76% → 80% als konkretes Ziel mit definierten Tasks

### PRIORITÄT 4: CLAUDE.md-Metriken korrigieren

Die CLAUDE.md meldet 94% Recent-50 SR, aber das Archiv zeigt 0% für die tatsächlich letzten 50 Tasks. Die Metrik-Berechnung muss gegen das Archiv validiert werden, nicht nur gegen die aktive Registry.

## System-Gesundheit

| Komponente | Status | Handlungsbedarf |
|------------|--------|----------------|
| Execution Engine | Gesund (94% wenn gefüttert) | Keiner |
| Task Registry | 91 KB, kein Pressure | Bereinigung der 7 Shelved |
| Queues | LEER (Tag 5+) | KRITISCH — Deadlock |
| Self-Improve | BLOCKIERT (Cooldown) | Bypass implementieren |
| Automation Memory | LEER | Rehydrieren |
| Task-Generator | DEFEKT (nur Duplikate) | Titel-Dedup + neue Quellen |
| Superheld-Projekt | 13/13 completed | Aus Rotation nehmen |
| Provider-Routing | Funktional | OK |
| Learner | 5/20 Rules, 199 Knowledge | Untergenutzt |
| External Signals | Stale (seit 26.03.) | Aktualisieren |

## Fazit

Die Engine funktioniert hervorragend — das Problem ist ausschließlich der **Feedforward-Mechanismus**. Das System hat sich selbst in einen Deadlock manövriert, in dem es keine neuen sinnvollen Tasks generieren kann. Die drei kritischsten Eingriffe sind: (1) Queue-Starvation-Bypass um den Cooldown-Zirkelschluss zu brechen, (2) Superheld als abgeschlossen markieren, (3) Automation Memory rehydrieren. Ohne mindestens Maßnahme 1 bleibt das System dauerhaft im Leerlauf.
