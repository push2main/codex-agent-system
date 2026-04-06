# Fortschrittsbericht Codex-Agent-System
**Datum:** 25. Maerz 2026, automatischer Scheduled-Task-Report

---

## 1. Gesamtstatus: Das System lernt, aber steckt in einer Timeout-Krise

Das System hat 522 Tasks ausgefuehrt. Die Gesamterfolgsrate liegt bei **15%** (79 Erfolge), die juengsten 50 Tasks bei **28%**. Das klingt niedrig, aber der entscheidende Wert ist die **non-timeout Success-Rate: 28% bei +6.8pp/100 Tasks Lerngeschwindigkeit** -- das System verbessert sich tatsaechlich bei den Tasks, die es ausfuehren kann.

Das Hauptproblem: **45% aller Ausfuehrungen sind Timeouts** (235 von 443 Fehlern). In den letzten 20 Tasks waren es sogar 17 von 20 (85%). Das ueberlagert den echten Lernfortschritt komplett.

## 2. Lernverlauf nach 50-Task-Fenstern

| Fenster | Erfolg% | Timeout% | Erfolge/Total |
|---------|---------|----------|---------------|
| 1-50 | 34.0% | 38.0% | 17/50 |
| 51-100 | 4.0% | 10.0% | 2/50 |
| 101-150 | 6.0% | 66.0% | 3/50 |
| 151-200 | 4.0% | 76.0% | 2/50 |
| 201-250 | 16.0% | 68.0% | 8/50 |
| 251-300 | 10.0% | 46.0% | 5/50 |
| 301-350 | 14.0% | 10.0% | 7/50 |
| 351-400 | 12.0% | 24.0% | 6/50 |
| 401-450 | 22.0% | 58.0% | 11/50 |
| 451-500 | 26.0% | 40.0% | 13/50 |
| 501-522 | 22.7% | 77.3% | 5/22 |

Muster: Wenn Timeouts niedrig sind (301-400, ~10-24%), steigt die Erfolgsrate auf 12-14%. Wenn Timeouts explodieren (101-200, 66-76%), kollabiert die Erfolgsrate auf 4-6%. Das System hat ein echtes Timeout-Problem, kein Lern-Problem.

## 3. Projekt-Analyse

### Superheld (184 Tasks, aktiver Focus)
- Gesamterfolge: 38/184 (21%)
- Bestes Fenster: Tasks 121-150 mit 12/30 (40%) Erfolg
- Letztes Fenster: 0/4 -- alles Timeouts
- Letzte 20: 3 Erfolge, 17 Timeouts
- Timeout-Dauer: Durchschnitt 665s (min 201s, max 900s)
- Alle Erfolge in der Kategorie "performance" (code_quality)

### Codex-Agent-System (326 Tasks)
- Gesamterfolge: 34/326 (10%)
- Schlimmstes Fenster: Tasks 151-200 mit 0/50 Erfolg und 44 Timeouts
- Zuletzt: Nur self-improve und inventory Tasks erfolgreich

## 4. Sind die aktuellen Tasks umsetzbar?

### Queue (4 Tasks):

**Approved (bereit):**
1. "Improve first-pass success rate" (superheld, stability) -- **Problematisch.** Meta-Task ohne klares Scope. Risiko: Timeout oder unspezifischer Plan.
2. "Break retry churn" (superheld, stability) -- **Problematisch.** Retry-Churn ist ein systemeigenes Problem. Ohne spezifische Datei/Aenderung wird das schwierig.

**Pending approval:**
3. "[self-improve:high] Improve retry failure classification coverage" (codex-agent-system) -- **Machbar.** Konkretes Ziel (24% Coverage erhoehen), spezifische Dateien betroffen.
4. "Reduce timeout rate" (codex-agent-system) -- **Problematisch.** Zu breit gefasst. Timeout-Reduktion erfordert entweder Task-Selektion (Strategy) oder Infrastruktur-Aenderungen.

**Fazit:** 1 von 4 Tasks ist konkret genug fuer eine realistische Umsetzung. Die anderen 3 sind Meta-Tasks, die historisch 0% Erfolgsrate haben.

## 5. Was funktioniert

- **Diagnostics:** 100% Coverage -- jeder Fehler hat auswertbaren Kontext
- **Zombie-Guard:** 17 Zombie-Tasks (151 verschwendete Slots) alle gesperrt
- **Registry-Kompaktierung:** Lokale Registry 97KB (runter von >1MB)
- **Scope-Gate:** Multi-Platform-Erkennung verhindert aussichtslose Tasks
- **Timeout-Krise-Pause:** Strategy pausiert bei >50% Timeout-Rate (korrekt aktiv)
- **Non-Timeout-Lernen:** +6.8pp/100 Tasks -- echte Verbesserung bei machbaren Tasks
- **20 Regeln:** Konsolidiert, code-enforced, keine Advisory-only-Regeln

## 6. Was nicht funktioniert

1. **Timeout-Dominanz:** 85% der letzten 20 Tasks sind Timeouts. Hauptursache: Superheld-Tasks sind zu komplex fuer das Timeout-Budget (avg 665s bei einem Budget von vermutlich 300-900s).

2. **Meta-Tasks:** Tasks wie "Improve success rate" oder "Break retry churn" haben keinen konkreten Scope. Sie generieren Plaene, die dann timeout-en oder scheitern, weil sie zu viele Dateien anfassen.

3. **Superheld Registry-Pressure:** 1.08MB externe Registry, nicht vom VM aus komprimierbar. Belastet das Dashboard.

4. **Provider-Erfolgsraten schlecht:** Claude-Provider hat 0% bei auth, code_quality, learning. Codex-Provider nicht besser bei diesen Kategorien.

## 7. Empfohlene Modifikationen

### Sofort (System-Konfiguration):

**A. Timeout-Budget fuer Superheld reduzieren auf 300s**
Aktuell laufen Tasks 665s im Durchschnitt, bevor sie als Timeout scheitern. Das verschwendet Compute. Ein schnellerer Fail (300s) wuerde dieselben Tasks ablehnen, aber 50% schneller.

**B. Meta-Tasks aus der Queue entfernen**
Die 2 approved Tasks ("Improve first-pass success rate", "Break retry churn") sollten geshelved werden. Sie sind nicht konkret genug. Stattdessen: spezifische, datei-bezogene Tasks erstellen.

**C. Superheld-Registry komprimieren**
Muss vom Host ausgefuehrt werden (nicht VM): `scripts/compact-registry.sh` auf die externe superheld Registry anwenden.

### Kurzfristig (Task-Generierung):

**D. Task-Scope-Regel verschaerfen**
Neue Regel: Tasks muessen mindestens eine konkrete Datei im Titel oder der Beschreibung nennen. Tasks ohne Dateibezug haben historisch <5% Erfolgsrate.

**E. Superheld: Nur Einzeldatei-Tasks generieren**
Der Erfolgstyp bei Superheld ist "performance/code_quality" mit spezifischen Dateiaenderungen. Strategy sollte nur Tasks erzeugen, die max. 2 Dateien betreffen.

**F. Pending Task #3 genehmigen**
"Improve retry failure classification coverage" ist der einzige konkret machbare Task. Genehmigen und ausfuehren.

### Mittelfristig (Architektur):

**G. Planner-Context-Budget begrenzen**
94% der Timeouts sind Zero-Step (Planner verbraucht das ganze Budget). Der Planner bekommt vermutlich zu viel Context. Test: Planner-Input auf 4000 Tokens begrenzen.

**H. Zwei-Phasen-Execution einfuehren**
Phase 1: Planner erzeugt Plan (60s, schon implementiert). Phase 2: Wenn Plan >3 Steps hat, Strategy entscheidet ob ausfuehren oder splitten. Das verhindert ambitionierte Plaene, die dann timeout-en.

## 8. Zusammenfassung

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Gesamterfolg | 15% | Niedrig, aber verstaendlich |
| Non-Timeout-Erfolg | 28% | Solide, steigend |
| Lerngeschwindigkeit | +6.8pp/100 | Gut -- System lernt |
| Timeout-Rate (letzte 20) | 85% | KRITISCH |
| Diagnostic Coverage | 100% | Exzellent |
| Queue-Qualitaet | 1/4 machbar | Schlecht -- Meta-Tasks |

**Das System lernt. Aber die Timeout-Krise verschlingt 85% der Kapazitaet.** Die wichtigste Massnahme ist nicht mehr Lernen, sondern bessere Task-Selektion: kleinere, konkretere Tasks mit explizitem Dateibezug. Die Infrastruktur (Guards, Regeln, Diagnostics) ist reif und funktioniert. Die Strategy muss jetzt lernen, nur Tasks zu generieren, die im Capability-Envelope liegen.
