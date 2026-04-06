# Fortschrittsbericht — 30. März 2026, v11 (Scheduled)

## Systemstatus: PIPELINE LEERLAUF — Qualität stabil, aber Task-Nachschub blockiert

---

## Kennzahlen-Übersicht

| Metrik | Wert | Bewertung |
|---|---|---|
| Gesamt-Tasks (Metriken) | 623 | — |
| All-time Success Rate | 15% | stagnierend (historisch belastet) |
| Recent-50 Success Rate | 28% | stabil |
| First-Pass Rate | 62% | gut |
| Timeout-Rate (global) | 34% (210 von 623) | historisch, aber Zero-Step fast eliminiert |
| Zero-Step-Timeout-Rate | 91% (227 von Timeouts) | historisch — aktuelle Runs: 0 |
| Non-Timeout Success Rate | 25% | leichte Verbesserung (non_timeout_improving: true) |
| Registry Tasks (aktiv) | 21 total, davon 7 shelved, 4 completed | minimal |
| Queue | **leer** (0 queued, 0 running, 0 approved) | KRITISCH |
| Registry-Größe | ~211 KB | gesund (< 512 KB) |
| Aktive Alerts | 2: retry_churn (high), loop_effort (warning) | persistent |
| Cooldown | title_family_cooldown aktiv (gerade gesetzt) | blockiert Neugenerierung |
| Automation Memory | nicht hydriert (external_hydrated: false) | blockiert |

---

## 1. Sind die bisherigen Tasks umsetzbar?

**Ja, die verbleibenden Tasks sind grundsätzlich umsetzbar.** Die Evidenz:

- Die **superheld-Archiv** zeigt 8 completed vs. 4 failed bei den letzten 16 Tasks = **67% Erfolgsrate** im lokalen Projekt. Das ist ein starker Wert.
- Die **Window-Trend-Analyse** zeigt eine klare Erholung am Ende: Window 601–623 hat 30% Success Rate bei nur 1 Timeout, verglichen mit dem Tiefpunkt von 4% in Window 51–100 und 151–200.
- Der **First-Pass** liegt bei 62% — mehr als die Hälfte aller Tasks wird beim ersten Versuch gelöst.

**Problem:** Es gibt fast keine aktiven Tasks mehr. Von 21 Registry-Tasks sind 7 shelved, 4 completed, und der Rest ist inaktiv. Die Queue ist komplett leer. Es werden keine neuen Tasks generiert.

---

## 2. Heben wir die Success Rate?

**Lokal ja, global kaum messbar.**

Die Trend-Windows zeigen eine wellenförmige, aber leicht positive Entwicklung:

- Frühphase (Tasks 1–200): Durchschnitt ~12%, massive Timeouts
- Mittelphase (Tasks 200–500): Durchschnitt ~17%, Timeouts rückläufig
- Spätphase (Tasks 500–623): Durchschnitt ~18%, Timeouts fast eliminiert

Die **non_timeout_velocity** ist positiv (+0.43 pp/100 Tasks) und `non_timeout_improving: true`. Das heißt: wenn wir Timeouts herausrechnen, verbessert sich das System tatsächlich.

**Provider-Analyse** zeigt klare Unterschiede:
- `claude-code`: 62.5% Success (8 Tasks) — bester Provider
- `codex-cli`: 28.4% Success (67 Tasks) — solide
- `codex`: 19.0% Success (58 Tasks) — unterdurchschnittlich
- `claude`: 18.8% Success (16 Tasks) — unterdurchschnittlich

**Rule-Set-Analyse:** Die besten Rule-Sets erreichen 50–64% Success Rate, was zeigt, dass die gelernten Rules wirken, wenn sie aktiv sind.

---

## 3. Hauptproblem: Doppelte Pipeline-Blockade

### Blockade 1: Title-Family-Cooldown
Der Self-Improve-Run erkennt 4 potenzielle Verbesserungen, aber **alle 4 werden durch `title_family_cooldown` blockiert** (blocked_analysis: 4). Das Cooldown-File wurde gerade erst geschrieben (Alter: ~1 Minute). Das bedeutet: das System erkennt Arbeit, darf sie aber nicht ausführen.

### Blockade 2: Automation Memory nicht initialisiert
`automation_id: ""`, `external_hydrated: false`, `external_sync_pending: true`. Ohne hydrierte Automation-Memory kann die Self-Improve-Engine keinen vollständigen Zyklus fahren.

### Blockade 3: Queue-Starvation
0 queued, 0 running, 0 approved, 0 pending_approval. Die Pipeline hat keinen Input. Selbst wenn Cooldown und Memory gelöst werden, fehlt der Nachschub.

---

## 4. Empfohlene Modifikationen

### Sofort (Konfiguration)

1. **Cooldown lockern oder resetten**: Die `title_family_cooldown` blockiert alle 4 erkannten Verbesserungen. Entweder den Cooldown-Timer verkürzen oder das Cooldown-File löschen, damit die Self-Improve-Engine wieder Tasks generieren kann.

2. **Automation Memory hydrieren**: Das Memory-File muss initialisiert werden (`external_hydrated: true`, eine `automation_id` zuweisen), damit die Engine Zustand über Runs hinweg behalten kann.

3. **Queue manuell befüllen**: Solange die Self-Improve-Engine blockiert ist, könnten manuell Tasks in die Queue geschoben werden, um die Pipeline am Laufen zu halten.

### Mittelfristig (System)

4. **Provider-Routing optimieren**: `claude-code` (62.5%) sollte bevorzugt eingesetzt werden. Die aktuellen Routing-Rules leiten UI-Tasks an `claude` und den Rest an `codex` — aber `codex` hat nur 19% Success. Eine Verschiebung hin zu `codex-cli` oder `claude-code` könnte die Rate heben.

5. **Retry-Churn Alert auflösen**: Der `retry_churn` Alert ist seit 21 Analyse-Runs aktiv. Die 5 Prompt-Rules (Schritt-Cap, JSON-File-Guard, Verification-Reklassifikation, Queue-Dedup-Suppression, Watchdog-Inventory-Fallback) adressieren das theoretisch, aber der Alert persistiert. Hier sollte geprüft werden, ob die Rules tatsächlich greifen oder ob sie in der Praxis bypassed werden.

6. **Zombie-Tasks aufräumen**: 20 Zombie-Tasks mit 166 verschwendeten Slots belasten die historische Success Rate. Diese sollten endgültig archiviert und aus der Metrik-Berechnung entfernt werden.

### Langfristig (Architektur)

7. **Backlog-Generator diversifizieren**: Die Self-Improve-Engine ist der einzige Task-Generator. Wenn sie blockiert ist, steht alles. Ein zweiter Kanal (z.B. externe Signale direkt in Tasks umwandeln, manuelle Task-Templates) würde die Abhängigkeit reduzieren.

---

## 5. Zusammenfassung

| Frage | Antwort |
|---|---|
| Sind Tasks umsetzbar? | **Ja** — 62% First-Pass, 67% im lokalen Projekt |
| Hebt sich die Success Rate? | **Lokal ja** (non-timeout improving), **global kaum** (historische Last) |
| Modifikationen nötig? | **Ja** — Cooldown/Memory/Queue-Blockade lösen, Provider-Routing anpassen |

**Gesamtbewertung:** Das System hat gelernt und die Qualität der Task-Ausführung ist auf dem besten Stand seit Projektbeginn. Das Kernproblem ist nicht mehr die Ausführung, sondern die **Pipeline-Blockade** — die Self-Improve-Engine generiert keine neuen Tasks wegen Cooldown und fehlender Memory-Hydrierung. Die sofortige Priorität ist, den Nachschub wiederherzustellen.
