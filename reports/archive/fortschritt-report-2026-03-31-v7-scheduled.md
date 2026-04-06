# Fortschrittsbericht — 2026-03-31 (v7, Scheduled)

## Systemstatus: PIPELINE STALL — Cooldown-Deadlock unverändert

**Generiert:** 2026-03-31, automatisierter Scheduled Run (Cowork)

---

## 1. Kennzahlen

| Metrik | Wert | Bewertung |
|---|---|---|
| Tasks gesamt (Archiv + aktiv) | ~1.114 (671 in metrics) | — |
| Erfolgsrate gesamt | 20% | stabil |
| Erfolgsrate letzte 50 | **78%** | ↑ stark verbessert |
| First-Pass-Rate | **75%** | ↑ gut |
| Timeout-Rate | 31% (historisch) | → |
| Zero-Step-Timeouts (recent) | **0** | ✅ eliminiert |
| Aktive Registry | 11 Tasks (4 completed, 7 shelved) | — |
| Registry-Größe | 90 KB aktiv / 4,3 MB Archiv | Archiv zu groß |
| Queue | **LEER seit ~48h+** | ⛔ kritisch |
| Self-Improve | **Cooldown-Deadlock** | ⛔ kritisch |
| Aktive Alerts | 2 (retry_churn, loop_effort) | ⚠️ |

---

## 2. Sind die bisherigen Tasks umsetzbar?

### Erfolgreich abgeschlossen (4 von 11)
- **task-006** (syntax-check-planner) — ✅ funktioniert
- **task-007** (verify-step-cap) — ✅ funktioniert
- **task-008** (fix-learner-comment) — ✅ funktioniert
- **task-011** (improve-retry-success-rate) — ✅ First-Pass-Erfolg

### Geshelved (7 Tasks) — Einschätzung

| Task | Umsetzbar? | Empfehlung |
|---|---|---|
| task-001 (external signal review) | Ja, niedriger Wert | Entfernen — kein Impact |
| task-002 (test context-clamp) | Ja, Step-Cap-Fix sollte helfen | Re-queue |
| task-003 (test classify-retry) | Ja, gleiche Logik | Re-queue |
| task-004 (fix learner rule count) | Wahrscheinlich obsolet durch task-008 | Prüfen → vermutlich löschen |
| task-005 (queue drain guard) | **Nein** — 26 Fehlversuche, Zombie | Permanent shelved |
| task-009 (inventory decision path) | **Nein** in jetziger Form | Komplett neu formulieren |
| task-010 (reduce timeout rate) | Zu abstrakt | In konkrete Einzelschritte aufspalten |

**Fazit:** 2 Tasks (002, 003) können direkt re-queued werden. 2 Tasks (005, 009) sind nicht umsetzbar. 3 Tasks sollten entfernt oder umgeschrieben werden.

---

## 3. Heben wir die Success Rate?

**Ja — die Micro-Fix-Strategie funktioniert nachweislich.**

Die Iteration-Trend-Daten zeigen eine klare Verbesserung:

| Window | Success Rate | Timeouts |
|---|---|---|
| Tasks 1–50 | 34% | 19 |
| Tasks 101–200 | 4–6% | 33–38 |
| Tasks 401–500 | 22–26% | 20–29 |
| Tasks 601–650 | **58%** | 1 |
| Tasks 651–671 | **76%** | 0 |

Der Trend ist klar positiv (+30pp über die gesamte Laufzeit, +5.9pp/100 Tasks). Die letzten ~70 Tasks haben eine reale Erfolgsrate von 58–76% mit null Timeouts. Die Verbesserungen an Step-Cap, Retry-Klassifizierung und Zombie-Guard wirken.

**Problem:** Die "78% recent" basiert auf einem sehr kleinen Sample. Die Pipeline ist seit 48+ Stunden still. Ohne neuen Task-Durchsatz kann die Rate nicht stabilisiert oder weiter verbessert werden.

---

## 4. Notwendige Modifikationen

### KRITISCH: Pipeline-Deadlock lösen

**Ist-Zustand:** `self-improve-run.json` zeigt `cooldown_active` als Blockadegrund. Queue leer, kein Task wird generiert oder ausgeführt. Das System ist de facto pausiert.

**Empfohlene Maßnahmen:**
1. Cooldown-Reset — manueller Reset der Cooldown-Sperre als Sofortmaßnahme
2. Cooldown-TTL begrenzen — Max 2h Cooldown, dann automatischer Reset bei leerer Queue
3. Fallback-Trigger — wenn Queue >4h leer ohne aktiven Grund, Pipeline auto-restart

### HOCH: Self-Improve-Task-Qualität verbessern

**Ist-Zustand:** Self-Improve generierte Tasks sind zu abstrakt ("reduce timeout rate", "improve retry success"). Solche Meta-Tasks haben historisch 0% Erfolgsrate.

**Empfohlene Maßnahmen:**
1. Scope-Regel: Jeder Self-Improve-Task darf maximal 1 Datei und 1 konkrete Änderung betreffen
2. Pflichtfelder: Explizite Datei + Zielzeile in der Taskbeschreibung
3. Titel max 120 Zeichen, keine abstrakten Optimierungsziele

### HOCH: Provider-Routing schärfen

**Ist-Zustand:** Starke Schwankungen nach Kategorie:

| Kategorie | Codex SR | Claude SR | Empfehlung |
|---|---|---|---|
| Auth | **68%** | 0% | Nur Codex |
| Testing | 57% | **36%** | Codex bevorzugt |
| General | 25% | 19% | Codex bevorzugt |
| UI | 15% | 15% | Beide schlecht — Scope reduzieren |
| Code Quality | 11% | 0% | Pausieren oder triviale Tasks only |
| Infra | 15% | 13% | Scope reduzieren |

Auth-Tasks bei Codex (68%) sind der klare Sweet Spot. Code-Quality und UI-Tasks sollten pausiert oder auf triviale Scopes beschränkt werden.

### MITTEL: Archiv-Compaction

**Ist-Zustand:** `tasks-archive.json` ist 4,3 MB. Die aktive Registry (90 KB) ist noch OK, aber das Archiv wächst ohne Begrenzung.

**Empfohlene Maßnahmen:**
1. Cold-Archive für Tasks >7 Tage
2. Per-Project-Compaction (superheld-Projekt dominiert)

### NIEDRIG: Alert-Bereinigung

Zwei aktive Alerts (retry_churn, loop_effort) basieren auf historischen Daten. Da die Pipeline still steht, sind diese informativ aber nicht akut.

---

## 5. Gesamtbewertung

| Aspekt | Status | Handlungsbedarf |
|---|---|---|
| Success-Rate-Trend | ✅ Steigend (4%→76%) | Kein — Strategie funktioniert |
| Pipeline-Betrieb | ⛔ Stillstand | **Sofort** — Cooldown-Reset |
| Task-Qualität | ⚠️ Gemischt | Hoch — konkretere Tasks |
| Learned Rules | ✅ 10 Regeln, 100% Klassifizierung | OK |
| Archiv-Hygiene | ⚠️ 4,3 MB | Mittel — Compaction |
| Zero-Step-Timeouts | ✅ Eliminiert | Kein |

### Fazit

Das System hat eine beeindruckende Lernkurve gezeigt: von 4% auf 76% Success Rate in den letzten Tasks. Die technischen Verbesserungen (Step-Cap, Zombie-Guard, Retry-Klassifizierung) wirken. **Das Kernproblem ist jetzt operationell, nicht technisch:** Die Pipeline steht still wegen eines Cooldown-Deadlocks.

**Priorität 1:** Cooldown-Deadlock auflösen und Pipeline wieder starten.
**Priorität 2:** Self-Improve-Tasks auf "1 Datei, 1 Änderung"-Scope umstellen.
**Priorität 3:** Tasks 002 + 003 re-queuen als Validierung der Step-Cap-Verbesserungen.
