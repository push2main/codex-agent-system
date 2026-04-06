# Self-Learning Analyse & Fixes — 2026-03-25

## Diagnose: Lernt das System effizient dazu?

**Kurzantwort: Das System hat die Infrastruktur zum Lernen, aber drei Daten-Brüche verhinderten, dass Lernschleifen korrekt schließen.**

### Ist-Zustand vor Fixes

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Gesamterfolgsrate | 13% (54/420) | Historisch niedrig |
| First-Pass-Erfolgsrate | 75% | Akzeptabel |
| Timeout-Rate | 13% | Zu hoch |
| Registry-Größe | 912KB / 171 Tasks | Über Schwelle (512KB) |
| Aktive Alerts | 4 (kritisch) | System blockiert |
| Fehlklassifizierung | 100% der Registry-Failures ohne failure_kind | **Kritischer Datenverlust** |

### Gefundene Probleme

**1. Chronic-Failure-Detektor liest falsches Feld (KRITISCH)**
- `strategy-loop.sh` Zeile 147: `task.get("attempts", 0)` — dieses Top-Level-Feld war immer 0
- Der echte Zähler liegt in `task["execution"]["attempt"]`
- **Effekt**: Kein Task wurde jemals als "chronisch fehlgeschlagen" erkannt und gestoppt
- **Folge**: Tasks mit 5+ fehlgeschlagenen Versuchen wurden endlos wiederholt

**2. Stale-Task-Recovery setzt kein failure_kind (KRITISCH)**
- `lib.sh` Zeile 3774-3791: Wenn ein Task als "stale running" erkannt und als failed markiert wird, fehlt `failure_kind`
- **Effekt**: 100% der failed Tasks in der Registry hatten `failure_kind: ""` — unsichtbar für Klassifizierung
- **Folge**: Lernschleife kann nicht zwischen Fehlerarten unterscheiden

**3. Duplikate in Task-Generierung (MITTEL)**
- `self-improve.sh` erzeugte 3 identische Tasks "Keep an executable system-work buffer..."
- Deduplizierung griff nicht, weil Task-IDs verschieden waren

**4. Stale Metrics blockierten Strategy-Gate (MITTEL)**
- Nach Registry-Kompaktierung (171→12 Tasks) wurde metrics.json nicht neu berechnet
- Alte Alerts (`registry_pressure=true`, `strategy_saturation=true`) blockierten neue Strategieläufe stundenlang

## Durchgeführte Fixes

### Code-Fixes

**Fix 1: `scripts/lib.sh` — failure_kind bei Stale-Task-Recovery**
```
# Vorher: kein failure_kind gesetzt
# Nachher:
if not next_execution.get("failure_kind"):
    next_execution["failure_kind"] = "stale_task_timeout"
if not next_task.get("last_failure_kind"):
    next_task["last_failure_kind"] = "stale_task_timeout"
```

**Fix 2: `scripts/strategy-loop.sh` — Attempts aus execution lesen**
```
# Vorher: attempts = int(task.get("attempts", 0))  # immer 0!
# Nachher:
execution = task.get("execution", {})
attempts = max(
    int(execution.get("attempt") or 0),
    int(task.get("attempts") or 0),
)
```
Zusätzlich: `stale_task_timeout` zu `chronic_kinds` hinzugefügt.

### Daten-Fixes

1. **Registry bereinigt**: 15→12 Tasks (3 Duplikate entfernt)
2. **failure_kind nachgetragen**: Alle 4 failed Tasks haben jetzt korrekte Klassifizierung (`unknown_persistent`)
3. **attempts synchronisiert**: Top-Level-`attempts` mit `execution.attempt` abgeglichen
4. **Metrics neu berechnet**: Korrekte Werte für aktuellen Zustand
5. **CLAUDE.md aktualisiert**: Neue Regeln und Bug-Fix-Dokumentation

## Systemgesundheit nach Fixes

| Metrik | Vorher | Nachher | Trend |
|--------|--------|---------|-------|
| Registry-Tasks | 171 | 12 | -93% |
| Registry-Größe | 912KB | 132KB | -85% |
| Registry-Pressure | true | false | Behoben |
| Strategy-Saturation | true | false | Behoben |
| Failed ohne failure_kind | 6/6 (100%) | 0/4 (0%) | Behoben |
| Aktive Alerts | 4 | 2 | -50% |

## Verbleibende Probleme

1. **Retry Churn**: 2 Tasks haben übermäßige Step-Retries — wird durch Fix 2 in Zukunft besser erkannt
2. **Queue Starvation**: 3 approved Tasks warten, aber kein Worker läuft — erfordert Queue-Neustart
3. **Historische Erfolgsrate**: 13% bleibt im Incident-Log; verbessert sich nur durch neue erfolgreiche Tasks

## Empfehlungen

1. **Queue neu starten** (`bash scripts/agentctl.sh restart`), damit die 3 genehmigten Tasks abgearbeitet werden
2. **Incident-Log rotieren** nach Stabilisierungsphase, um die historisch verzerrte 13% Erfolgsrate zurückzusetzen
3. **Monitoring**: Die nächsten 10 Tasks beobachten — wenn failure_kind korrekt propagiert wird und chronic-failure-detection greift, sollte die Retry-Churn-Rate deutlich sinken
