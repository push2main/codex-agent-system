# Self-Learning Report — Iteration 7 (2026-03-25)

## Kernfrage: Lernt das System effizient dazu?

**Ja, aber mit Einschraenkungen.** Die Lernmaschinerie funktioniert nachweislich — die Nicht-Timeout-Erfolgsrate stieg von <10% auf 28% mit einer Velocity von +6.8pp/100 Tasks. Allerdings wird dieses Signal durch 45% Timeout-Ausfaelle verwassert, die den Gesamtwert auf 15% druecken (+1.73pp/100 Tasks Velocity).

## Metriken-Zusammenfassung

| Metrik | Wert | Trend |
|--------|------|-------|
| Gesamt-Tasks | 522 | — |
| Gesamt-Erfolgsrate | 15.1% (79/522) | STEIGEND (+1.73pp/100) |
| Nicht-Timeout-Erfolgsrate | 28% (287 Tasks) | STEIGEND (+6.8pp/100) |
| Timeout-Rate | 45% gesamt, 77% letztes Fenster | KRISE |
| First-Pass-Erfolgsrate | 55% (22 Tasks) | STABIL |
| Diagnostik-Abdeckung | 100% | STABIL |
| Regeln | 20 (konsolidiert) | STABIL |
| Registry-Druck | 102KB lokal | OK |

## Identifizierte Probleme (Iteration 7)

### Problem 21: Capability Envelope zu eng
Die bisherige Filterung basierte nur auf Plattform-Keywords und Scope-Amplifiern. Analyse der letzten 18 Tasks (2 Erfolge, 16 Fehlschlage) zeigte: Tasks wie "EU Digital Services Act", "Matter/Zigbee Integration", "haptic feedback" passierten den Filter, obwohl sie historisch 0% Erfolgsrate hatten.

**Fix:** Drei neue Keyword-Kategorien (INFRA_KEYWORDS, INTEGRATION_KEYWORDS, COMPLEXITY_INDICATORS) plus kombinierte Blockierregeln.

### Problem 22: Keine datengetriebene Timeout-Vorhersage
Der Capability Envelope war eine manuell kuratierte Keyword-Liste, die sich nicht automatisch anpassen konnte.

**Fix:** predict_timeout_probability() — berechnet pro Wort das Timeout/Success-Verhaeltnis aus der gesamten Task-Historie. Tasks mit >=70% vorhergesagter Timeout-Wahrscheinlichkeit werden blockiert. Erster selbst-adaptierender Filter im System.

### Problem 23: System seit 13+ Stunden blockiert
Pipeline-Deadlock: Timeout-Krise blockierte neue Tasks, aber veraltete genehmigte Tasks blockierten neue Vorschlaege.

**Fix:** (a) 2 veraltete genehmigte Tasks direkt als shelved markiert. (b) Auto-Shelve-Mechanismus: Genehmigte Tasks >12h waehrend Timeout-Krise werden automatisch zurueckgestellt.

### Problem 24: rules.md wieder bei 22 Regeln
**Fix:** Konsolidiert auf exakt 20 Regeln.

## Lern-Effizienz-Bewertung

### Was funktioniert:
- **Code-erzwungene Regeln** haben messbaren Impact (vs. beratende Regeln mit ~0% Impact)
- **Zombie-Blocklist** verhindert 151 verschwendete Worker-Slots
- **Diagnostik-Abdeckung 100%** ermoeglicht praezise Fehleranalyse
- **Nicht-Timeout-Velocity +6.8pp** zeigt echtes Lernen

### Was nicht funktioniert:
- **Timeout-Oszillation** — System pendelt zwischen niedrigen und hohen Timeout-Raten
- **Statische Keyword-Filter** koennen nicht mit sich aendernden Task-Mustern mithalten
- **Stale-Task-Deadlock** — Pipeline blockiert wenn genehmigte Tasks haengen bleiben

### Paradigmen-Wechsel in Iteration 7:
Von **reaktiv** (nach Fehler korrigieren) zu **praediktiv** (vor Erstellung verhindern). Die predict_timeout_probability() ist der erste Filter, der automatisch aus der Task-Historie lernt.

## Erwartete Auswirkung

| Metrik | Vorher | Erwartet nach Fix |
|--------|--------|-------------------|
| Timeout-Rate (letztes Fenster) | 77% | <40% |
| Gesamt-Erfolgsrate | 15% | >20% |
| Pipeline-Stalls | 13h+ | 0h (Auto-Shelve) |
| Kapazitaets-Verschwendung | 3-5x durch Timeouts | 1-2x mit Praediktor |

## Naechste Prioritaeten

1. Validieren, dass expandierte Capability Envelope die juengsten Timeout-Muster abfaengt
2. Messen, ob Timeout-Praediktor korrekt hochriskante Tasks blockiert
3. Bestaetigen, dass Auto-Shelve zukuenftige Pipeline-Blockaden verhindert
4. Wenn Timeout-Rate unter 40% faellt: Fokus auf Verbesserung der Coder/Reviewer-Qualitaet
