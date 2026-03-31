# Fortschritt-Report — 2026-03-31 (v22, Scheduled)

## Zusammenfassung

Das System zeigt eine **nachhaltig hohe Execution-Qualität** (Recent-50 SR: 88–90%, First-Pass SR: 70–85%), steht aber weiterhin in einem **operativen Stillstand**: Die Queue ist seit dem 28.03. leer, der Self-Improve-Loop generiert keine neuen Tasks, und die Automation-Memory ist defekt. Die 7 shelved Tasks im aktiven Registry sind **zu 6/7 obsolet**. Um die Success Rate weiter zu heben, sind gezielte System-Modifikationen nötig.

---

## Kernkennzahlen (Stand 31.03.2026, 19:10 UTC)

| Metrik | Wert | Trend | Bewertung |
|--------|------|-------|-----------|
| All-time SR | 23% (702 Tasks) | — | Historisch belastet |
| Recent-50 SR | **90%** | ↔ stabil | Sehr gut |
| First-Pass SR | **70%** | ↔ stabil | Gut |
| Q4 (letzte 132) | **90%** | ↔ | Exzellent |
| Tasks 651–700 | **86%** | ↑ | Spitzenwert |
| Timeout-Rate | 30% kumulativ, <2% aktuell | ↓ gelöst | Kein Problem mehr |
| Registry | 91 KB, 11 Tasks | ↔ | Kein Pressure |
| Queue | **Leer seit 28.03.** | ↔ | Kritisch |
| Zombie-Tasks | 20 (historisch) | ↔ | Bereinigt |
| Aktive Alerts | 2 (retry_churn, loop_effort) | ↔ | Historisch, nicht akut |
| Prompt Rules | 5 aktiv | ↔ | Funktionieren |
| Learned Rules | 5 aktiv, 199 Knowledge-Einträge | ↔ | Umfangreich |

---

## Sind die bisherigen Tasks umsetzbar?

**Großteils nein.** Von 11 Tasks im aktiven Registry:

### 4 Completed (erledigt)
Alle 4 abgeschlossenen Tasks (planner.sh Kommentar, Step-Länge Test, learner.sh Dedup, Retry SR Improvement) sind korrekt abgeschlossen. Kein Handlungsbedarf.

### 7 Shelved — davon 1 potenziell umsetzbar
| Task | Status | Empfehlung |
|------|--------|------------|
| Unit-Test clamp_prompt_context | missing_source_file | **Obsolet** — Funktion existiert nicht (mehr) |
| Unit-Test classify_retry_failure | missing_source_file | **Obsolet** — Funktion existiert nicht (mehr) |
| learner.sh Dedup-Threshold Kommentar | shelved | **Umsetzbar**, trivial |
| External Signal: OpenAI Python v2.30.0 | shelved | **Obsolet** — kein actionable Signal |
| Queue-Buffer Konzept | shelved | **Überholt** durch aktuelle Architektur |
| Planning-Budget Inventarisierung | shelved | **Bereits gelöst** (Zero-Step Timeouts eliminiert) |
| Timeout-Reduction (47%) | shelved, 0 attempts | **Erledigt** — Rate liegt bei <2% |

**Empfehlung:** Die 6 obsoleten Tasks aus dem Registry entfernen (kompaktieren) und den einen trivialen Task (Dedup-Kommentar) entweder ausführen oder ebenfalls entfernen.

---

## Heben wir die Success Rate?

**Ja — die Verbesserung ist real, aber stagnierend.**

Die Lernkurve über 700 Tasks zeigt einen klaren Aufwärtstrend:

| Fenster | SR | Timeouts | Phase |
|---------|----|----------|-------|
| 1–100 | 4–34% | 24 | Frühphase |
| 101–300 | 4–16% | 105 | Timeout-Krise |
| 301–500 | 12–26% | 66 | Stabilisierung |
| 501–600 | 10–14% | 31 | Regelanwendung |
| 601–650 | **58%** | 1 | Durchbruch |
| 651–700 | **86%** | 1 | Plateau |

**Verbesserungstreiber:**
1. Inventory-First Pattern (eliminiert missing_source_file vor Execution)
2. 5 Prompt Rules (verhindern bekannte Failure-Patterns)
3. Zero-Step Timeout Elimination (227 historische → 0 aktuelle)
4. Retry Classification Coverage bei 100%

**Problem:** Seit dem 28.03. kein neuer Task — die Rate kann nicht weiter steigen, weil nichts mehr läuft.

---

## Systemprobleme und notwendige Modifikationen

### 1. Automation-Memory Deadlock (KRITISCH)
```json
{
  "source": "none",
  "external_hydrated": false,
  "external_sync_pending": true
}
```
Die Automation-Memory ist leer und nicht synchronisiert. Das verhindert die Fortsetzung des Self-Improve-Loops. **Fix:** Entweder manuell eine gültige Memory-Datei erzeugen oder den Hydration-Pfad debuggen/resetten.

### 2. Leere Queue + Cooldown-Gate (KRITISCH)
Der Self-Improve-Run meldet `dominant_reason: cooldown_active`. In Kombination mit der leeren Queue entsteht ein Deadlock: Kein Task wird generiert → Queue bleibt leer → Cooldown bleibt aktiv → kein Task wird generiert.

**Fix-Optionen:**
- Cooldown-Timer manuell resetten
- Einen Seed-Task manuell in die Queue einspeisen
- Das Cooldown-Gate lockern, sodass es bei leerer Queue nicht greift

### 3. Historische Alerts (niedrige Priorität)
Die Alerts `retry_churn` und `loop_effort` sind historischer Natur (basieren auf kumulativen Metriken). Sie reflektieren nicht den aktuellen Zustand. **Fix:** Alert-Schwellwerte auf rollierendes Fenster umstellen oder historische Daten aus der Berechnung ausschließen.

### 4. Provider-Routing Ungleichgewicht
Der `claude`-Provider zeigt deutlich niedrigere Erfolgsraten als `codex` in fast allen Kategorien:
- claude/auth: 0% (3 Tasks) vs codex/auth: 72% (29 Tasks)
- claude/code_quality: 0% (5 Tasks) vs codex/code_quality: 11% (19 Tasks)
- claude/ui: 15% (74 Tasks) vs codex/ui: 25% (189 Tasks)

**Empfehlung:** Mehr Kategorien auf den `codex`-Provider routen, insbesondere `code_quality` und `auth`.

---

## Empfohlene Maßnahmen (priorisiert)

1. **Automation-Memory resetten** — Entweder eine leere aber gültige Memory-Datei anlegen oder den externen Sync-Pfad reparieren
2. **Cooldown-Gate anpassen** — Bei leerer Queue sollte der Cooldown nicht greifen, damit der Self-Improve-Loop neue Tasks generieren kann
3. **Registry kompaktieren** — Die 6 obsoleten shelved Tasks archivieren, um ein sauberes Bild zu haben
4. **Provider-Routing aktualisieren** — `claude`-Provider nur noch für UI-Tasks verwenden, alle anderen auf `codex` routen
5. **Alert-Berechnung auf Rolling Window umstellen** — Damit historische Altlasten nicht permanent als aktive Alerts erscheinen

---

## Fazit

Das Execution-Engine funktioniert sehr gut (86–90% SR bei aktuellen Tasks). Das Lernsystem hat effektiv 5 starke Rules aufgebaut, die bekannte Fehler verhindern. **Das Hauptproblem ist nicht die Qualität, sondern die Inaktivität:** Der Self-Improve-Loop ist durch einen dreifachen Deadlock (defekte Automation-Memory, leere Queue, permanenter Cooldown) blockiert. Ohne manuelle Intervention wird keine Fortschritt-Steigerung mehr stattfinden. Die bisherigen shelved Tasks sind großteils obsolet und sollten bereinigt werden.

**Gesamtstatus: Execution GRÜN, Pipeline ROT, Handlungsbedarf bei System-Konfiguration.**
