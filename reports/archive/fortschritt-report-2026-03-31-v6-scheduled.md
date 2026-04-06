# Fortschrittsbericht — 2026-03-31 (v6, Scheduled)

## Systemstatus: PIPELINE STALL — Cooldown-Deadlock hält an

**Generiert:** 2026-03-31, automatisierter Scheduled Run

---

## 1. Kennzahlen im Überblick

| Metrik | Wert | Trend |
|---|---|---|
| Tasks gesamt (Archiv + aktiv) | 1.114 | +6 seit letztem Report |
| Erfolgsrate gesamt | 18,3% (204/1.114) | stabil |
| Erfolgsrate letzte 50 | 74% (lt. metrics.json) | ↑ stark |
| First-Pass-Rate | 67–82% | ↑ |
| Timeout-Rate | 31% | → stabil |
| Zero-Step-Timeouts (letzte 64) | 0 | ↑ eliminiert |
| Aktive Tasks | 11 (4 completed, 7 shelved) | — |
| Queue | LEER seit ~30h | ⚠️ |
| Self-Improve | COOLDOWN blockiert | ⚠️ |

---

## 2. Tagesweise Erfolgsrate (Archiv)

| Datum | Tasks | Erfolge | Rate | Hauptproblem |
|---|---|---|---|---|
| 23.03. | 72 | 12 | 17% | Initiale Lernphase |
| 24.03. | 128 | 67 | **52%** | Bestwert, danach Einbruch |
| 25.03. | 503 | 116 | 23% | Massenproduktion, viele Timeouts |
| 26.03. | 334 | 1 | **0%** | 330 Tasks shelved — Mass-Shelving |
| 27.03. | 12 | 0 | 0% | 11 failed, Pipeline-Stau |
| 28.03. | 50 | 0 | 0% | 16 failed, 32 shelved |
| 29–31.03. | 15 | 4 | **27%** | Micro-Fixes, dann Stillstand |

**Interpretation:** Nach dem Peak am 24.03. (52%) kam es am 25.03. durch Strategy Saturation und Retry Churn zum Einbruch. Am 26.03. wurde das Mass-Shelving ausgelöst. Seitdem ist die Pipeline de facto stillgelegt. Die 4 Erfolge seit dem 28.03. (tasks 006–008, 011) sind ausschließlich gezielte Micro-Fixes.

---

## 3. Sind die bisherigen Tasks umsetzbar?

### Erledigte Tasks (funktionieren)
- **task-006** (syntax-check-planner): ✅ nach 2 Fehlversuchen
- **task-007** (verify-step-cap): ✅ nach 3 Versuchen
- **task-008** (fix-learner-comment): ✅ nach 2 Fehlversuchen
- **task-011** (improve-retry-success-rate): ✅ beim 1. Versuch

### Geshelved — Bewertung

| Task | Grund | Umsetzbar? | Empfehlung |
|---|---|---|---|
| task-001 (external signal review) | Deprioritisiert | Ja, aber niedriger Wert | Löschen |
| task-002 (test context-clamp) | review_rejection | Ja, mit Step-Cap-Fix | Re-queue mit vereinfachtem Plan |
| task-003 (test classify-retry) | review_rejection | Ja, mit Step-Cap-Fix | Re-queue mit vereinfachtem Plan |
| task-004 (fix learner rule count) | review_rejection | Ja, aber task-008 hat ähnliches gemacht | Prüfen ob obsolet |
| task-005 (queue drain guard) | 26 Fehlversuche, Zombie | **Nein** | Permanent shelved lassen |
| task-009 (inventory decision path) | 5 Fehlversuche, Zombie | **Nein** in jetziger Form | Reformulieren oder verwerfen |
| task-010 (reduce timeout rate) | pending_approval | Zu abstrakt | Reformulieren als konkrete Einzelschritte |

---

## 4. Heben wir die Success Rate?

**Ja, aber nur im Mikrobereich.** Die "74% Recent"-Zahl basiert auf einem sehr kleinen Sample (~10–15 Tasks). Die tatsächliche Pipeline ist seit 3+ Tagen stillgelegt.

**Was funktioniert:**
- Step-Cap auf 600 Zeichen verhindert Review-Rejections
- Zombie-Guard shelved hoffnungslose Tasks
- Retry-Klassifizierung bei 100% Abdeckung
- Zero-Step-Timeouts in letzten 64 Tasks eliminiert

**Was nicht funktioniert:**
- Self-Improve-Tasks haben 0% Erfolgsrate (zu abstrakt)
- Cooldown-Logik hat Pipeline in Deadlock versetzt
- Queue ist leer, kein neuer Task-Input
- Archiv wächst (4,3 MB) ohne Compaction

---

## 5. Notwendige Modifikationen

### A. KRITISCH — Pipeline-Deadlock lösen

**Problem:** `self-improve-run.json` zeigt `cooldown_active` als dominanten Gating-Reason. Queue ist seit 30+ Stunden leer. Kein Task wird generiert oder ausgeführt.

**Empfehlung:**
1. Cooldown-Timer auf max 2h TTL begrenzen (aktuell offenbar unbegrenzt bei leerer Queue)
2. Fallback-Mechanismus: wenn Queue > 4h leer und kein Cooldown-Grund vorliegt, auto-reset
3. Manueller Reset der Cooldown-Dateien als Sofortmaßnahme

### B. HOCH — Self-Improve Tasks reformulieren

**Problem:** Alle Self-Improve-Regel-Sets (reduce timeout, improve retry, cap planning budget) bei 0% Erfolgsrate. Tasks sind zu abstrakt formuliert.

**Empfehlung:**
1. Self-Improve-Tasks auf "1 Datei, 1 Änderung"-Scope beschränken
2. Maximale Titellänge auf 120 Zeichen begrenzen
3. Explizite Datei + Zeilennummer in Task-Beschreibung fordern
4. Abstrakte Optimierungsziele (z.B. "reduce timeout rate") in konkrete Code-Änderungen übersetzen

### C. MITTEL — Task-Archiv aufräumen

**Problem:** `tasks-archive.json` bei 4,3 MB. Registry-Pressure laut CLAUDE.md bei >512KB problematisch für Dashboard-Reads.

**Empfehlung:**
1. Cold-Archive für Tasks älter als 7 Tage
2. Per-Project-Compaction (v.a. "superheld"-Projekt dominiert)
3. Aktive Registry (90 KB) ist noch im grünen Bereich

### D. MITTEL — Provider-Routing optimieren

**Problem:** Code-Quality-Tasks bei beiden Providern unter 11% Erfolgsrate. UI-Tasks bei 15%.

**Empfehlung:**
1. Code-Quality-Tasks pausieren oder auf triviale Scope beschränken
2. UI-Tasks MAX_STEPS auf 3–4 reduzieren (statt 6)
3. Auth-Tasks (68% bei Codex) weiter bevorzugen — hier liegt der beste ROI

### E. NIEDRIG — Geshelved Tasks triagen

Drei der 7 geshelvten Tasks (002, 003, 004) könnten mit dem Step-Cap-Fix jetzt funktionieren. Empfehlung: 002 und 003 re-queuen als Validierungstest, 004 als obsolet markieren.

---

## 6. Gesamtbewertung

| Aspekt | Status | Note |
|---|---|---|
| Erfolgsrate-Trend | ↑ steigend (4% → 74% recent) | Gut, aber kleines Sample |
| Pipeline-Gesundheit | ⛔ Deadlock | Kritisch |
| Learned Rules | 10 Regeln, effektiv | OK |
| Task-Qualität | Micro-Fixes funktionieren, Abstrakte scheitern | Verbesserungsbedarf |
| Archiv-Hygiene | 4,3 MB, wächst | Wartung nötig |
| Self-Improvement-Loop | Blockiert (Cooldown + 0% SR) | Kritisch |

**Fazit:** Das System hat bewiesen, dass es konkrete Micro-Fix-Tasks erfolgreich ausführen kann (tasks 006–011). Die Kernprobleme sind jetzt nicht mehr technische Fehler, sondern **operationale Blockaden**: der Cooldown-Deadlock verhindert neue Task-Generierung, und die Self-Improve-Logik generiert zu abstrakte Tasks.

**Priorität 1** muss die Auflösung des Pipeline-Deadlocks sein — ohne laufende Pipeline kann keine Success Rate gemessen oder verbessert werden. **Priorität 2** ist die Reformulierung der Self-Improve-Task-Generierung hin zu konkreten, file-spezifischen Änderungen.
