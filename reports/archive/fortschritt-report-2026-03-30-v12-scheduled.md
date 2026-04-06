# Fortschrittsbericht — 30. März 2026, v12 (Scheduled)

## Systemstatus: PIPELINE IM LEERLAUF — Ausführungsqualität gut, Task-Nachschub blockiert

---

## Kennzahlen auf einen Blick

| Metrik | Wert | Trend |
|---|---|---|
| Tasks gesamt (Archiv) | 1.103 | — |
| Aktive Registry | 11 Tasks (7 shelved, 4 completed) | minimal |
| All-time Success Rate | 15% | stagnierend |
| Recent-50 Success Rate | 28% | stabil |
| First-Pass Rate | 57–62% | gut |
| Timeout-Rate (historisch) | 34% | Zero-Step jetzt 0 |
| Queue | **komplett leer** | KRITISCH |
| Registry-Größe | 89 KB | gesund |
| Archiv-Größe | 4,3 MB | wachsend |
| Letzte erfolgreiche Tasks | 24. März (67% am Tag) | 6 Tage ohne Erfolg |

---

## 1. Sind die bisherigen Tasks umsetzbar?

**Grundsätzlich ja, aber es gibt fast keine aktiven Tasks mehr.**

Die Evidenz dafür:
- Am 24. März erreichte das System **67% Success Rate** (67/100) — der beste Einzeltag seit Projektstart.
- First-Pass Rate liegt stabil bei 57–62%, d.h. mehr als die Hälfte aller Tasks wird beim ersten Versuch gelöst.
- Die 4 completed Tasks in der aktiven Registry (Kommentar-Updates, Tests für planner/learner) zeigen, dass kleinteilige, klar definierte Tasks zuverlässig umsetzbar sind.

**Das Problem:** Seit dem 27. März liegt die Success Rate bei **0%** (0/27 completed vs. 27 failed/shelved). Die Pipeline generiert keine neuen Tasks, und die wenigen die durchlaufen, scheitern an wiederkehrenden Mustern (Inventory-Tasks im Schleifenmodus, Cooldown-Blockaden).

---

## 2. Heben wir die Success Rate?

**Nein, aktuell nicht.** Die Daten zeigen einen klaren Einbruch:

| Zeitraum | Success Rate | Anmerkung |
|---|---|---|
| 23. März | 20% (12/59) | Startphase |
| 24. März | **67%** (67/100) | Peak — System auf bestem Stand |
| 25. März | 28% (116/412) | Hohe Volumina, viele Timeouts |
| 26. März | 25% (1/4) | Stark reduziertes Volumen |
| 27. März | **0%** (0/11) | Komplettausfall |
| 28. März | **0%** (0/16) | Komplettausfall |
| 29.–30. März | **0 Tasks** | Pipeline steht komplett |

Der non-timeout-Trend war positiv (+0.43 pp/100 Tasks), aber seit 2 Tagen werden keine Tasks mehr ausgeführt. Die Self-Improve-Engine erkennt die Situation, generiert aber 0 Tasks weil Cooldown und Memory blockieren.

---

## 3. Hauptprobleme (priorisiert)

### Problem 1: Pipeline-Deadlock (KRITISCH)
Die System-Logs zeigen einen Endlos-Loop seit ~09:00 Uhr:
```
[self-improve] DEBUG: Cooldown active (Xs / 600s)
[strategy-loop] INFO: Zero-queue escape: 0 approved + 0 running
```
Der Cooldown läuft alle 10 Minuten ab, die Engine analysiert, findet 0 Verbesserungen (weil `title_family_cooldown` alles blockiert), setzt einen neuen Cooldown, und der Zyklus wiederholt sich. Die Queue bleibt bei 0.

### Problem 2: Shelving-Spirale (28. März)
Am 28. März wurde der Task "Inventory current decision path for improve first-pass success rate" **19 Mal hintereinander geshelved** (07:45–08:08). Das ist ein klares Zeichen für einen Bug in der Task-Generierung: der gleiche Task wird immer wieder erzeugt, sofort als problematisch erkannt, geshelved, und neu generiert.

### Problem 3: Zombie-Tasks belasten Metriken
85 Task-Titel mit 3+ Fehlschlägen, davon einer mit 11 Wiederholungen. Diese 85 Zombie-Muster verbrauchen Ausführungsbudget und drücken die historische Rate.

### Problem 4: Provider-Routing suboptimal
- `claude-code`: 62.5% Success (8 Tasks) — wird kaum genutzt
- `codex-cli`: 28.4% (67 Tasks) — solide
- `codex`: 19.0% (58 Tasks) — Standard-Provider, unterdurchschnittlich
- `claude`: 18.8% (16 Tasks)

Der Default-Provider `codex` performt am schlechtesten, wird aber am meisten eingesetzt.

### Problem 5: Kategorie-Lücken
Kategorien mit **0% Success und >4 Tasks**: security (0/24), ux (0/52), backend (0/12), architecture (0/12). Diese Kategorien sollten entweder ausgesetzt oder die Tasks grundlegend anders formuliert werden.

---

## 4. Empfohlene Modifikationen

### Sofort (Konfiguration)

1. **Cooldown-File löschen und Timer verkürzen**: Die Datei `codex-logs/self-improve-superheld-cooldown` blockiert seit dem 30.3. den gesamten Nachschub. Den Timer von 600s auf 120s setzen würde die Reaktionszeit bei leerem Queue drastisch verbessern.

2. **Automation Memory initialisieren**: `external_hydrated: false` verhindert, dass die Engine Zustand über Runs behält. Einmalige Initialisierung nötig.

3. **Zombie-Guard aktivieren/verschärfen**: Tasks die 3+ Mal mit gleichem Titel fehlgeschlagen sind, sollten permanent aus der Generierung ausgeschlossen werden (CLAUDE.md nennt 5+, aber 3+ wäre effektiver).

### Mittelfristig (System)

4. **Provider-Routing auf `claude-code` und `codex-cli` umstellen**: Codex als Default ersetzen — allein durch diese Änderung könnte die Rate von ~19% auf ~28–45% steigen.

5. **Shelving-Loop fixen**: Die 19-fache Wiederholung am 28. März zeigt, dass `title_family_cooldown` die Symptome blockiert, aber nicht die Ursache (fehlerhafte Task-Generierung). Der Generator braucht einen Deduplizierungs-Check gegen die letzten N geshelved Tasks.

6. **Kategorien mit 0% Success pausieren**: security, ux, backend, architecture — Tasks in diesen Kategorien sollten nicht generiert werden, bis die zugrundeliegenden Probleme (fehlende Codebase-Zugriffe, zu komplexe Anforderungen) gelöst sind.

### Langfristig (Architektur)

7. **Zweiten Task-Generierungskanal einführen**: Die komplette Abhängigkeit von der Self-Improve-Engine ist ein Single-Point-of-Failure. Ein manueller oder template-basierter Kanal würde Resilienz schaffen.

8. **Archiv-Kompaktierung**: Mit 4,3 MB und 1.103 Einträgen wächst das Archiv. Eine periodische Kompaktierung (z.B. Zombie-Tasks entfernen, nur Metriken behalten) würde die Analyseleistung verbessern.

---

## 5. Zusammenfassung

| Frage | Antwort |
|---|---|
| Tasks umsetzbar? | **Ja** bei guter Formulierung (62% First-Pass) — aber es gibt fast keine aktiven Tasks |
| Success Rate steigend? | **Nein** — seit 27.3. bei 0%, Pipeline steht seit 29.3. komplett |
| Modifikationen nötig? | **Ja, dringend** — Pipeline-Deadlock lösen (Cooldown + Memory), Provider-Routing anpassen |

**Gesamtbewertung:** Das System hat am 24. März gezeigt, dass es 67% schaffen kann. Die Ausführungsqualität ist vorhanden. Das aktuelle Problem ist kein Qualitätsproblem, sondern ein **Infrastruktur-Deadlock**: die Self-Improve-Engine dreht im Leerlauf, die Queue ist seit 2 Tagen leer, und schützende Mechanismen (Cooldown, Zombie-Guard) blockieren paradoxerweise jeden Neustart. Ohne manuellen Eingriff in Cooldown und Memory wird sich dieser Zustand nicht selbst lösen.
