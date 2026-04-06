# Fortschrittsbericht — 31. März 2026, v5 (Scheduled)

## Systemstatus: COOLDOWN-DEADLOCK GERADE ABLAUFEND — Pipeline-Restart erwartet

---

## Kennzahlen auf einen Blick

| Metrik | Wert | Trend |
|---|---|---|
| Tasks gesamt | 667 | stabil |
| All-time Success Rate | **19%** | durch Altlasten verzerrt |
| Recent-50 Success Rate | **74%** | sehr gut |
| Letzte 14 Tasks (Window 651–667) | **76%** | Spitzenwert |
| First-Pass Success Rate | **67%** (aktuell) / **82%** (CLAUDE.md) | stark |
| Timeout-Rate (historisch) | 31% (210 Timeouts) | unverändert |
| Zero-Step-Timeouts letzte 64 Tasks | **0** | gelöst |
| Aktive Tasks im Registry | 17 | kompakt |
| Registry-Größe | 168 KB | unter Pressure-Limit (512 KB) |
| Queues | **LEER** | seit ~30h |
| Aktive Alerts | 2 (retry_churn, loop_effort) | unverändert |
| Learned Rules | 10 (5 in CLAUDE.md, 5 in rules.md) | +5 seit 30.03. |
| Knowledge Base | 199 Einträge | stabil |
| Retry-Klassifizierung | **100%** (140/140) | hervorragend |

---

## 1. Success Rate — Klarer Aufwärtstrend

Die Iteration-Trend-Windows zeigen eine eindeutige Verbesserung:

| Phase | Window | Success Rate | Timeouts |
|---|---|---|---|
| Früh (Chaos) | 51–200 | 4–6% | 5–38 |
| Mitte (Lernen) | 201–400 | 10–16% | 5–34 |
| Spät (Reife) | 401–550 | 10–26% | 20–29 |
| Aktuell | 601–667 | **58–76%** | 0–1 |

**Improvement-Velocity:** ca. +5–6pp pro 100 Tasks. Das System lernt messbar und nachhaltig.

**Besonders positiv:** Zero-Step-Timeouts (das historisch größte Problem mit 227 Fällen) sind in den letzten 64 Tasks komplett verschwunden. Die Planner-Optimierungen (60s-Cap, Step-Limit) wirken.

---

## 2. Sind die bisherigen Tasks umsetzbar?

### Completed Tasks (funktionieren):
- task-006 bis task-008 und task-011: Syntax-Check, Step-Cap, Learner-Fix, Retry-Improvement — alle erfolgreich umgesetzt

### Shelved Tasks — Bewertung:

| Task | Umsetzbar? | Empfehlung |
|---|---|---|
| task-002 Context-Clamp-Test | Ja, mit einfacherem Plan | Re-queue |
| task-003 Classify-Retry-Test | Ja | Re-queue |
| task-004 Learner-Rule-Count | Ja, trivial | Re-queue |
| task-001 External-Signal-Review | Veraltet (25.03.) | Verwerfen |
| task-005 System-Work-Buffer | Zu abstrakt | Verwerfen |
| task-009 Decision-Path-Inventory | Kein klarer Deliverable | Verwerfen |
| task-010 Timeout-Rate-Reduktion | Strategisch wichtig | Umformulieren, konkretes Deliverable |

**Fazit:** 3 direkt re-queue-bar, 3 verwerfen, 1 umformulieren.

### Self-Improve Tasks — Problematisch:
Die rule-effectiveness-Daten zeigen, dass Self-Improve-Tasks (rules_hash `9f968207`, `d5bbcbcd`) eine **0% Success Rate** haben. Diese Meta-Tasks scheitern systematisch, weil sie zu abstrakt formuliert sind oder der Cooldown-Mechanismus sie blockiert.

---

## 3. Provider-Performance

| Kategorie | Claude SR | Codex SR | Empfehlung |
|---|---|---|---|
| Auth | 0% (3) | 68% (25) | Codex korrekt geroutet |
| Testing | 36% (14) | 50% (6) | Beide akzeptabel |
| UI | 15% (74) | 13% (160) | Beide schwach — Tasks vereinfachen |
| Code Quality | 0% (5) | 11% (19) | Beide schwach — zu komplex |
| General | 19% (54) | n/a | Akzeptabel |
| Infra | 13% (31) | n/a | Schwach — Tasks vereinfachen |

**Haupterkenntnis:** UI- und Code-Quality-Tasks sind für beide Provider zu komplex. Das Routing ist weniger das Problem als die Task-Komplexität selbst.

---

## 4. Aktive Probleme

### A) Cooldown-Deadlock (KRITISCH — gerade ablaufend)

Die drei Cooldown-Dateien:
- `self-improve-cooldown`: Inhalt `0` (seit 30.03. 23:51 UTC)
- `self-improve-codex-agent-system-cooldown`: Inhalt `0` (seit 30.03. 23:51 UTC)
- `self-improve-superheld-cooldown`: Timestamp `1774922775` — **gerade abgelaufen** (31.03. 02:06 UTC)

Der superheld-Cooldown ist buchstäblich gerade expired. Die beiden `0`-Cooldowns sind ambig — je nach Parser-Logik könnten sie als "Epoch 0" (=abgelaufen) oder als dauerhaft blockierend interpretiert werden.

**Empfehlung:** Falls die Pipeline nach dem superheld-Cooldown-Ablauf nicht automatisch anspringt, die `0`-Dateien manuell löschen.

### B) Retry-Churn Alert (HIGH)

17 Analysis-Runs, aber retry_churn_detected bleibt `true`. 5 Tasks haben zusammen 15 Extra-Step-Attempts verbraucht (loop_effort). Das sind Retry-Schleifen ohne Fortschritt.

**Empfehlung:** Die verursachenden Tasks identifizieren und shelven/verwerfen, bevor die Pipeline neustartet.

### C) Self-Improve Meta-Tasks scheitern systematisch

0% Success Rate bei Self-Improve-Tasks (both rule sets). Die Retry-Failure-Analysis zeigt: Diese Tasks werden rejected, weil die Verifikation zu oberflächlich ist oder der Scope zu breit.

**Empfehlung:** Self-Improve-Tasks nur noch mit extrem konkretem, einzeiligem Deliverable generieren ("Ändere Zeile X in Datei Y von A zu B").

---

## 5. Empfohlene Modifikationen

### Sofort (Pipeline-Restart):
1. **Cooldown-Status prüfen** — superheld-Cooldown ist gerade abgelaufen, Pipeline sollte automatisch anlaufen
2. **Falls nicht:** Die `0`-Cooldown-Dateien manuell löschen
3. **Shelved Tasks bereinigen** — 3 verwerfen, 3 re-queuen, 1 umformulieren

### Kurzfristig (System-Config):
4. **UI-Task MAX_STEPS auf 3–4 reduzieren** — UI hat mit 6 Steps nur 13–15% SR
5. **Cooldown-Mechanik überarbeiten** — Max-TTL von 2h, kein Self-Renewal wenn Queue leer
6. **Self-Improve-Task-Qualität erhöhen** — Nur noch Tasks mit konkretem 1-File-1-Change Scope

### Mittelfristig (Architektur):
7. **Code-Quality und UI-Tasks grundsätzlich vereinfachen** — Scope auf einzelne Dateien/Komponenten beschränken
8. **Retry-Budget pro Task einführen** — Max 2 Retries, dann automatisch shelve

---

## 6. Gesamtbewertung

**Das System lernt und verbessert sich messbar.** Die Success Rate ist von einstelligen Prozentwerten auf 74–76% in den letzten 50–14 Tasks gestiegen. Die größten historischen Probleme (Zero-Step-Timeouts, unklassifizierte Retries) sind gelöst.

**Das Hauptproblem ist aktuell operationell, nicht architektonisch:** Die Cooldown-Deadlock-Situation blockiert seit ~30h den gesamten Task-Durchsatz. Die Pipeline ist gesund, aber steht still. Der superheld-Cooldown ist gerade abgelaufen — die Pipeline sollte zeitnah wieder anlaufen.

**Risiko:** Wenn die Pipeline neustartet, könnten die retry_churn- und loop_effort-Alerts zu erneutem Churn führen, falls die problematischen Tasks nicht vorher bereinigt werden.

**Status: VORSICHTIG OPTIMISTISCH** — Trend sehr positiv, aber manueller Eingriff für Cooldown und Task-Hygiene empfohlen.
