# Fortschritt-Report — 2026-03-31 (v21, Scheduled)

## Zusammenfassung

Das System befindet sich in einem **stabilen aber inaktiven Zustand**. Die Execution Engine funktioniert hervorragend (85% First-Pass SR, 88% Recent-50 SR), doch seit dem 28.03. werden keine neuen Tasks generiert. Der Self-Improve-Loop ist durch einen Dreifach-Deadlock blockiert (defekte Automation-Memory, leere Queue, permanenter Cooldown). Die bisherigen 7 shelved Tasks sind **großteils nicht mehr umsetzbar** — 6 von 7 sind obsolet oder beziehen sich auf bereits gelöste Probleme.

---

## Kernkennzahlen

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| All-time SR | 23% (701 Tasks) | Historisch belastet |
| Recent-50 SR | **88%** | Sehr gut |
| First-Pass SR | **85%** | Stabil |
| Superheld-Projekt SR | **94%** (16/17 completed) | Spitzenwert |
| Timeout-Rate | 30% kumulativ, <2% aktuell | Gelöst |
| Registry | 334 KB, 11 Tasks (4 done, 7 shelved) | Kein Pressure |
| Queue | Leer seit 28.03. | Kritisch |
| Aktive Alerts | 2 (retry_churn, loop_effort) | Historisch, nicht akut |
| Heutige Runs | 53 | Learner aktiv, aber idle |
| Prompt Rules | 5 aktive Regeln | Funktionieren |
| Learning Knowledge | 199 Einträge | Umfangreich |

---

## Sind die bisherigen Tasks umsetzbar?

**Nein, großteils nicht.** Von 11 Tasks im aktiven Registry:

**4 Completed** (erledigt, kein Handlungsbedarf):
- planner.sh MAX_STEP_CHARS Kommentar (Score: 4.75)
- Planner Step-Länge Test (Score: 6.3)
- learner.sh Dedup-Kommentar (Score: 3.8)
- Retry Success Rate Improvement (Score: 4.2)

**7 Shelved** — davon nur 1 potenziell umsetzbar:
- 2x Unit-Tests für nicht-existente Funktionen (missing_source_file) → **obsolet**
- 1x learner.sh Dedup-Threshold Kommentar → **umsetzbar**, aber trivial
- 1x External Signal Review (OpenAI Python v2.30.0) → **obsolet**, kein Actionable
- 1x Queue-Buffer-Konzept → **überholt** durch aktuelle Architektur
- 1x Planning-Budget Inventarisierung → **bereits gelöst**
- 1x Timeout-Reduction → **erledigt** (47% → <2%)

---

## Heben wir die Success Rate?

**Ja — die Verbesserung ist real und nachhaltig.**

Der Trend über die gesamte Laufzeit zeigt eine klare Lernkurve:

| Window | Success Rate | Timeouts |
|--------|-------------|----------|
| Tasks 1-100 | 4-34% | 24 |
| Tasks 101-300 | 4-16% | 105 (Timeout-Krise) |
| Tasks 301-500 | 12-26% | 66 |
| Tasks 501-600 | 10-14% | 31 |
| Tasks 601-650 | **58%** | 1 |
| Tasks 651-700 | **86%** | 1 |

Die Haupttreiber der Verbesserung:
1. **Inventory-First Pattern** eliminiert missing_source_file Fehler vor Execution
2. **5 Learned Rules** in prompt-rules.md verhindern bekannte Failure-Patterns
3. **Zero-Step Timeout Elimination** (227 historische → 0 aktuelle)
4. **Retry Classification Coverage** bei 100% (von 24% zu Beginn)

---

## Automation-Memory Deadlock (unverändert seit v20)

Das Kernproblem bleibt bestehen:

```json
{
  "source": "none",
  "external_hydrated": false,
  "external_sync_pending": true
}
```

Der Self-Improve-Loop kann keinen gültigen Kontext erkennen → generiert keine neuen Tasks → Queue bleibt leer → Cooldown blockiert permanent. Die 53 heutigen Runs produzieren nur Learner-Output, aber keine neuen Task-Generierungen.

---

## Empfohlene Modifikationen (priorisiert)

### 1. KRITISCH — Automation-Memory reparieren
Die `self-improve-automation-memory.json` muss korrigiert werden:
- `source` → `"internal"`
- `external_sync_pending` → `false`
- `external_hydrated` → `true`

Ohne diesen Fix bleibt das System dauerhaft idle.

### 2. KRITISCH — Obsolete Tasks archivieren
6 der 7 shelved Tasks sollten in `tasks-archive.json` verschoben werden. Sie blockieren zwar nichts (kein Registry Pressure), aber sie verfälschen Metriken und verwirren den Self-Improve-Loop.

### 3. WICHTIG — Cooldown-Mechanismus überprüfen
Der permanente Cooldown (`gating.dominant_reason: "cooldown_active"`) verhindert jede Task-Generierung. Entweder:
- Cooldown-TTL auf max 2h begrenzen, oder
- Manuell 2-3 Canary-Tasks in die Queue einspeisen

### 4. NIEDRIG — Alerts zurücksetzen
Die Alerts `retry_churn` und `loop_effort` sind bei 85% First-Pass SR de facto false positives aus historischen Daten. Können gecleert werden.

### 5. NIEDRIG — Provider-Routing evaluieren
Claude-Provider zeigt historisch schwache Stats (15% SR bei UI-Tasks), aber diese stammen aus der Timeout-Krise. Ein kontrollierter A/B-Test wäre nach Wiederaufnahme der Task-Generierung sinnvoll.

---

## Fazit

Das System hat seine **strukturelle Transformation erfolgreich abgeschlossen** — von 4% auf 85%+ Success Rate. Die Engine ist leistungsfähig und die gelernten Regeln greifen. Das einzige aktive Problem ist der **Self-Improve-Deadlock**, der seit dem 28.03. keine neuen Tasks generieren lässt. Die bisherigen shelved Tasks sind großteils obsolet und sollten archiviert werden. Sobald der Deadlock aufgelöst wird, ist das System bereit für produktive Arbeit.

**Status: Engine bereit, Pipeline blockiert.**
