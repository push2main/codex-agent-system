# Fortschrittsbericht — 25. März 2026 (Scheduled Run)

## Zusammenfassung

Das System zeigt einen **langsamen, aber messbaren Aufwärtstrend** bei der Success Rate. Die Verbesserungen der letzten Self-Learning-Iterationen (Zombie Guard, Diagnostic Coverage, Timeout Guards) greifen teilweise, aber das **dominierende Problem sind weiterhin Zero-Step Timeouts** — Tasks die nie mit der Ausführung beginnen. Ohne eine Lösung dieses Problems wird die Success Rate nicht über ~30% steigen.

---

## Aktuelle Metriken

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Gesamt-Tasks | 522 | — |
| All-time Success Rate | 15% | Schlecht |
| Recent Success Rate (letzte 50) | 28% | Verbesserung (+13pp) |
| First-Pass Success Rate | 55% | Akzeptabel |
| Timeout Rate (gesamt) | 36% | Kritisch |
| Zero-Step Timeout Rate | 94% aller Timeouts | **Hauptproblem** |
| Zombie Tasks | 17 (151 verschwendete Slots) | Geblockt |
| Registry Pressure | 1.18 MB (superheld: 1.08 MB) | Kompaktierung nötig |
| Improvement Velocity | +1.73 pp/100 Tasks | Positiv |
| Diagnostic Coverage | 21% (recent: 30%) | Steigend |

## Trend-Analyse (Windows à 50 Tasks)

```
Window 1-50:    34% ████████████████░
Window 51-100:   4% ██
Window 101-150:  6% ███
Window 151-200:  4% ██
Window 201-250: 16% ████████
Window 251-300: 10% █████
Window 301-350: 14% ███████
Window 351-400: 12% ██████
Window 401-450: 22% ███████████
Window 451-500: 26% █████████████
Window 501-522: 23% ███████████░
```

**Trend: Aufwärts** — Die letzten 3 Windows liegen stabil bei 22-28%. Das ist eine klare Verbesserung gegenüber dem Mittelfeld (4-16%), aber die letzte Window zeigt eine leichte Stagnation wegen massiver Timeouts.

## Provider-Performance

| Provider | Recent Success | Stärke |
|----------|---------------|--------|
| Codex | 27% (6/22) | Documentation, simple implementations |
| Claude | 29% (8/28) | Testing (80%!), UI, Infrastructure |

Claude ist besonders stark bei **Testing-Tasks (80% Success)** und hat einen leichten Vorsprung insgesamt. Codex ist besser für Auth und Code-Quality.

## Hauptprobleme (priorisiert)

### 1. Zero-Step Timeouts — KRITISCH
**54 von 100 letzten Tasks** scheitern als Zero-Step Timeout. Diese Tasks starten nie mit der Ausführung. Alle 28 Timeouts in den letzten 50 Tasks sind Zero-Step. Mögliche Ursachen:
- Queue-Worker braucht zu lange für Setup/Context Loading
- Planungsphase überschreitet 60s-Cap, aber der Worker verbraucht trotzdem die volle Timeout-Dauer (600-900s)
- Zu große Task-Kontexte für das Superheld-Projekt (1.08 MB Registry)

### 2. Superheld Registry Pressure — HOCH
Die superheld tasks.json ist 1.08 MB groß und belastet jeden Dashboard-Read und jeden Queue-Worker-Start. Das verlangsamt alles.

### 3. Retry Churn — MITTEL
Retry Churn ist weiterhin detected. 70 Tasks hatten Loop Effort mit 163 Extra-Attempts. Die Guards greifen bei bekannten failure_kinds, aber neue Patterns entstehen.

### 4. Task Scope zu groß — MITTEL
Viele Superheld-Tasks sind zu ambitioniert (z.B. "Implement secure family chat E2E encrypted", "Migrate Android app from XML to Compose"). Solche Tasks brauchen viel mehr als 3-6 Steps und scheitern systematisch.

## Sind die aktuellen Tasks umsetzbar?

### Queue (3 Tasks):
- **task-130: Improve first-pass success rate** — Umsetzbar, da es Scripts betrifft die das System selbst kontrolliert
- **task-131: Break retry churn** — Umsetzbar, fokussiert auf orchestrator.sh
- **task-132: Reduce strategy saturation** — Umsetzbar, klar abgegrenzt

### Superheld Backlog:
Die meisten Superheld-Tasks sind **zu groß für das aktuelle System**. Tasks die funktioniert haben waren entweder dokumentationslastig (security architecture doc, DSAR generator, EU funding package) oder klar abgegrenzt (push notification adapter, WiFi checker). Die großen Feature-Tasks (Compose Migration, E2E Chat, Kubernetes Deployment) scheitern systematisch.

## Empfohlene Modifikationen

### System-Konfiguration:
1. **Registry Compaction für Superheld** — Die 1.08 MB müssen kompaktiert werden. Abgeschlossene und permanent gescheiterte Tasks aus dem aktiven JSON entfernen.
2. **Timeout-Diagnose verbessern** — Zero-Step Timeouts brauchen einen Early-Exit: Wenn nach 30s kein Step gestartet wurde, sofort abbrechen und diagnostischen Context speichern statt 600-900s zu warten.
3. **Queue-Worker Warm-Up messen** — Wie lange dauert es vom Worker-Start bis zum ersten Step? Wenn >60s, ist das die Root Cause.

### Task-Design:
4. **Superheld-Tasks aufteilen** — Große Feature-Tasks in 2-3 kleinere, atomare Tasks splitten. Statt "Implement secure family chat E2E encrypted" → (a) "Add chat data model to shared module", (b) "Create chat UI screens", (c) "Add E2E encryption layer".
5. **Max 3 Dateien pro Task** — Bereits als Regel vorhanden, aber nicht durchgesetzt. Tasks die >3 Dateien berühren müssen beim Planner rejected werden.
6. **Documentation/Config Tasks bevorzugen** — Diese haben deutlich höhere Success Rates als komplexe Code-Implementierungen.

### Metriken:
7. **Zero-Step Timeout separat tracken** — Eigene Metrik für "time_to_first_step" einführen, um die Root Cause zu isolieren.

## Fazit

Der Aufwärtstrend ist real aber fragil. Die Success Rate hat sich von ~5% auf ~25% verbessert, aber stagniert jetzt wegen Zero-Step Timeouts. Die drei größten Hebel sind: (1) Zero-Step Timeouts eliminieren, (2) Superheld Registry kompaktieren, (3) Tasks kleiner machen. Die queued Self-Improve Tasks (130-132) adressieren einige dieser Probleme. Wenn die Zero-Step Timeouts gelöst werden, ist eine Success Rate von 40-50% realistisch.
