# Fortschrittsbericht — 2026-03-31 (v12, Scheduled)

**Generiert:** 2026-03-31, automatisierter Scheduled Run (Cowork)

---

## 1. Gesamtstatus: System auf Plateau — Pipeline blockiert

Das codex-agent-system hat sich von einer All-time Success Rate von 4–6% (Lerntal) auf stabile **76–80% in den letzten 50 Tasks** hochgearbeitet. Die Lernkurve (+5.9pp pro 100 Tasks) ist beeindruckend. Allerdings steht die Pipeline seit >48h still wegen eines Cooldown-Deadlocks in der Self-Improve-Logik — es werden keine neuen Tasks generiert oder ausgeführt.

---

## 2. Kennzahlen-Übersicht

| Metrik | Wert | Bewertung |
|---|---|---|
| Tasks gesamt (all-time) | 684 | — |
| All-time Success Rate | 21% | historisch belastet |
| **Letzte 50 Tasks SR** | **82%** | ✅ stabil-hoch |
| **Letzte 29 Tasks SR** | **76%** | ✅ Plateau |
| First-Pass-Rate | 62% | ⚠️ gesunken (war 77%) |
| Timeout-Rate (historisch) | 31% | unverändert, keine neuen |
| Zero-Step-Timeouts | 227 (kumulativ, keine neuen) | ✅ eliminiert |
| Retry-Klassifizierung | 100% | ✅ |
| Registry-Größe | 252 KB (lokal) | ✅ unter 512 KB |
| Queue-Status | **LEER** (0 Bytes, beide Projekte) | ⛔ Pipeline-Stall |
| Self-Improve | **Cooldown-Deadlock** | ⛔ blockiert |
| Aktive Alerts | 2 (retry_churn: high, loop_effort: warning) | ⚠️ |
| Incidents | 0 aktiv | ✅ |

---

## 3. Projekt-Fortschritt

### codex-agent-system (lokal)
- 4 completed, 7 shelved, 0 running
- Keine pending/approved Tasks in der Queue
- 2 der 7 shelved Tasks sind re-queue-fähig (Test context-clamp, Test classify-retry)

### superheld
- **10 completed, 1 failed, 1 shelved, 1 running**
- Sehr gute Erfolgsrate: 10/12 = 83%
- Der laufende Task ("Inventory decision path") läuft noch
- 1 Failed Task: "Verify dashboard incident id field" — möglicher Retry-Kandidat

---

## 4. Provider-Performance

| Provider | Beste Kategorien | Schwachstellen |
|---|---|---|
| **codex** | auth (69%), testing (57%), general (25%) | code_quality (11%), learning (12%) |
| **claude** | general (19%) | auth (0%), code_quality (0%), infra (13%) |

**Fazit:** Der `codex`-Provider ist deutlich stärker bei auth- und testing-Tasks. Der `claude`-Provider hat Schwächen in fast allen Kategorien. Das bestehende Routing (claude für UI, codex für alles andere) ist korrekt.

---

## 5. Sind die bisherigen Tasks umsetzbar?

**Ja, grundsätzlich schon.** Die 76–80% SR zeigt, dass das Gros der Tasks machbar ist. Aber:

### Umsetzbare Tasks
- Dashboard-Verifikations-Tasks (superheld): 10/12 erfolgreich — bewährtes Muster
- Test-Tasks (codex-agent-system): 2 shelved Tasks (context-clamp, classify-retry) sollten mit den aktuellen Guards funktionieren

### Problematische Task-Typen
- **Abstrakte Self-Improve-Tasks** (z.B. "Improve first-pass success rate"): 0% SR bei rules_hash `9f968207`
- **Zu breit formulierte Tasks** (z.B. "Reduce timeout rate"): Brauchen Aufspaltung in konkrete Einzelschritte
- **Tasks mit ungeprüften Repo-Pfaden**: Hauptgrund für Fehlschläge laut Learned Rules

---

## 6. Heben wir die Success Rate?

**Ja, der Trend ist positiv und stabil**, aber das Wachstum hat sich verlangsamt:

| Phase | SR | Beschreibung |
|---|---|---|
| Tasks 51–200 | 4–6% | Lerntal |
| Tasks 401–500 | 22–26% | Guards greifen |
| Tasks 601–650 | 58% | Durchbruch |
| Tasks 651–679 | 76% | Plateau |

Die Maßnahmen (Step-Cap, Zombie-Guard, Retry-Klassifizierung, Zero-Step-Timeout-Elimination) wirken nachweislich. Aber: **Die Pipeline steht still**, also wird der Fortschritt nicht weiter gemessen.

---

## 7. Notwendige Modifikationen

### KRITISCH — Sofort (Pipeline-Blockade)

1. **Cooldown-Deadlock auflösen**
   - `self-improve-run.json`: Alle drei Gating-Felder (`dominant_reason`, `analysis_reason`, `submission_reason`) von `cooldown_active` auf `none` setzen
   - `automation-memory.json`: `external_sync_pending` auf `false`, `source` auf einen gültigen Wert setzen

2. **Queue manuell befüllen**
   - Tasks 002 (Test context-clamp) und 003 (Test classify-retry) re-queuen
   - Diese dienen als Validierung, dass die Pipeline wieder läuft

### WICHTIG — Kurzfristig (nächste 24h)

3. **Tote Tasks bereinigen**
   - Tasks 001, 004, 005 aus der codex-agent-system Registry entfernen (shelved, kein Re-Queue-Potenzial)
   - "Verify dashboard incident id" (superheld, failed) evaluieren ob Retry lohnt

4. **First-Pass-Rate stabilisieren**
   - Aktuell 62%, Ziel >65%
   - Beobachten ob sich die Rate nach Pipeline-Restart normalisiert

### EMPFOHLEN — Mittelfristig (System-Konfiguration)

5. **Cooldown-TTL begrenzen**
   - Max 2h bei leerer Queue (aktuell: kein Limit → Deadlock)
   - Implementierung: Auto-Reset-Trigger wenn Queue >4h leer ist

6. **Task-Scope-Regeln verschärfen**
   - 1 Task = 1 Datei + 1 konkrete Änderung
   - Keine abstrakten "Improve X" Tasks ohne konkreten Implementierungsplan

7. **Self-Improve Tasks vorvalidieren**
   - Vor Submission prüfen: Existieren die referenzierten Dateien? Ist der Scope eng genug?
   - Das würde die 0% SR bei abstrakten Self-Improve-Tasks adressieren

---

## 8. System-Ampel

| Aspekt | Status | Aktion nötig? |
|---|---|---|
| Success-Rate | ✅ GRÜN (76–80%) | Nein — beobachten |
| Lernkurve | ✅ GRÜN (+5.9pp/100) | Nein |
| Zero-Step-Timeouts | ✅ GRÜN (eliminiert) | Nein |
| Retry-Klassifizierung | ✅ GRÜN (100%) | Nein |
| Registry-Pressure | ✅ GRÜN (252 KB) | Nein |
| Incidents | ✅ GRÜN (0 aktiv) | Nein |
| **Pipeline-Betrieb** | **⛔ ROT** | **JA — Cooldown-Reset** |
| **Self-Improve** | **⛔ ROT** | **JA — Deadlock lösen** |
| First-Pass-Rate | ⚠️ GELB (62%) | Beobachten |
| Alerts | ⚠️ GELB (2 aktiv) | Folgesymptome des Stalls |

---

## 9. Fazit

Das System hat einen bemerkenswerten Reifegrad erreicht: von 4% auf 80% SR in der jüngsten Phase. Die Guards, Rules und Klassifizierungen funktionieren. **Das akute Problem ist der Cooldown-Deadlock**, der die Pipeline seit >48h blockiert. Ohne manuellen Reset werden keine neuen Tasks ausgeführt und der Fortschritt stagniert.

**Priorität 1:** Cooldown-Deadlock auflösen und Queue neu befüllen.
**Priorität 2:** Systemische Absicherung gegen erneuten Deadlock (TTL-Cap, Auto-Reset).
**Priorität 3:** Task-Qualität weiter verbessern für >80% SR.
