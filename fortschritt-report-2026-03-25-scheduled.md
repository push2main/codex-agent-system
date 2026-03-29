# Fortschrittsbericht — 25. März 2026 (Scheduled Task)

## Gesamtbild

Das System zeigt einen **positiven Aufwärtstrend**, ist aber noch weit von einer stabilen Produktivlage entfernt. Die Kennzahlen im Überblick:

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| All-time Success Rate | 15% | Niedrig, aber historisch belastet |
| Recent Success Rate (letzte 50) | 28% | Deutliche Verbesserung |
| First-Pass Success | 55% | Gut — mehr als die Hälfte klappt beim ersten Versuch |
| Timeout-Rate | 36% (188 von 443 Failures) | Hauptproblem, aber verbessert |
| Zero-Step Timeouts | 94% aller Timeouts | Planer verbraucht gesamtes Budget |
| Retry Churn | Aktiv | Noch nicht gelöst |
| Registry Pressure | 1.152 KB (Threshold: 512 KB) | Zu hoch — superheld-Projekt dominiert |
| Learning Velocity | +1,73pp pro 100 Tasks | Langsam aber stetig |
| Diagnostic Coverage | 100% | Voll gelöst |
| Zombie Tasks | 17 (151 verschwendete Slots) | Alle gesperrt |

## Trendanalyse (50-Task-Fenster)

```
Tasks   1-50:  34%
Tasks  51-100:  4%
Tasks 101-150:  6%
Tasks 151-200:  4%
Tasks 201-250: 16%
Tasks 251-300: 10%
Tasks 301-350: 14%
Tasks 351-400: 12%
Tasks 401-450: 22%
Tasks 451-500: 26%
Tasks 501-522: 23%
```

Der Trend ist klar: nach einem tiefen Tal (4-6%) hat sich das System auf 22-28% stabilisiert. Die letzten 150 Tasks zeigen konsistent ueber 20%.

## Was funktioniert

1. **Self-Learning-Mechanik**: 4 Iterationen mit 14 konkreten Fixes, alle im Code enforced. Diagnostic Coverage von 0% auf 100%.
2. **Zombie Guard**: 17 Zombie-Tasks erkannt und dauerhaft gesperrt — verhindert 151 weitere verschwendete Slots.
3. **Capability Envelope Filter**: Blockiert Tasks, die historisch 0% Erfolgsrate haben.
4. **Registry Compaction (codex-agent-system)**: Von 1,18 MB auf 95 KB reduziert.
5. **Provider Routing**: Testing-Tasks auf Claude geroutet (80% Erfolg), alle anderen auf Codex.

## Aktuelle Probleme

### 1. Registry Pressure — superheld-Projekt (KRITISCH)
Das superheld-Projekt beansprucht 1.057 KB der 1.152 KB Gesamtpressure. Das codex-agent-system ist mit 95 KB kompaktiert, aber superheld wurde nie kompaktiert. Empfehlung: compact-registry.sh auf das superheld-Projekt anwenden.

### 2. Retry Churn (AKTIV)
70 Tasks mit insgesamt 163 Extra-Step-Attempts. Tasks werden wiederholt, obwohl die gleichen Fehler auftreten. Der Task "Break retry churn" ist approved aber noch nicht ausgefuehrt.

### 3. Timeout-Dominanz
36% aller Failures sind Timeouts, 94% davon Zero-Step (der Planer allein verbraucht das gesamte Budget). Die Scope-Gate- und Capability-Envelope-Fixes sind deployed, aber der Effekt ist noch nicht voll messbar.

### 4. Loop Effort
70 Tasks mit durchschnittlich 2,3 Extra-Versuchen pro Task verschwenden erhebliche Compute-Ressourcen.

## Sind die aktuellen Tasks umsetzbar?

### Lokale Registry (codex-agent-system): 14 Tasks
- 3 completed, 5 shelved, 2 failed, 2 approved, 2 pending_approval
- Die beiden approved Tasks ("Improve first-pass success rate", "Break retry churn") sind Meta-Tasks, die das System selbst verbessern sollen. Sie sind grundsaetzlich umsetzbar, setzen aber voraus, dass die Strategy keine neuen Timeout-anfaelligen Tasks generiert.

### Queue: 3 Tasks (alle superheld)
Alle drei (improve-first-pass, break-retry-churn, reduce-strategy-saturation) sind fuer superheld. Bevor diese laufen, sollte superheld kompaktiert werden.

### Pending Approval: 2 Tasks
- "Improve retry failure classification coverage" — Sinnvoll, 87% Coverage ist gut aber nicht perfekt.
- "Reduce timeout rate" — Das wichtigste offene Problem. Sollte genehmigt werden.

## Empfohlene Modifikationen

### Sofort noetig (System/Config)
1. **Superheld-Registry kompaktieren**: compact-registry.sh auf superheld anwenden, um Pressure von 1.057 KB auf ca. 50 KB zu reduzieren.
2. **"Reduce timeout rate" Task genehmigen**: Dies ist das Hauptproblem und blockiert echten Fortschritt.
3. **Timeout-Crisis Rule pruefen**: Die Regel existiert in rules.md, Code-Enforcement pruefen.

### Mittelfristig (Tasks)
4. **Retry-Churn-Breaker priorisieren**: 163 verschwendete Step-Attempts sind signifikant.
5. **Strategy-Generierung drosseln**: Neue Tasks generieren macht nur Sinn, wenn die bestehenden Queue-Tasks auch durchkommen.

### Systemarchitektur
6. **Planner-Context-Budget limitieren**: 94% Zero-Step Timeouts heisst, der Planner bekommt zu viel Kontext. Ein hartes Limit auf die Input-Groesse koennte die Timeout-Rate dramatisch senken.
7. **Provider-Routing Iteration**: "learning" Category hat nur 7% Success auf Codex — Claude testen.

## Fazit

**Das System lernt und verbessert sich nachweislich** (+1,73pp/100 Tasks, Trend von 4% auf 28%). Die Self-Learning-Mechanik funktioniert. Die groessten Hebel fuer den naechsten Sprung sind:

1. Registry-Pressure loesen (superheld kompaktieren)
2. Timeout-Rate unter 20% bringen (Planner-Context-Limit)
3. Retry-Churn eliminieren

Ohne diese drei Fixes wird die Success Rate bei ca. 25-30% stagnieren. Mit ihnen ist 40-50% realistisch innerhalb der naechsten 100 Tasks.
