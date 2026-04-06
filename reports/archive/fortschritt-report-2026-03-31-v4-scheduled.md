# Fortschrittsbericht — 31. März 2026, v4 (Scheduled)

## Systemstatus: COOLDOWN-DEADLOCK — Pipeline vollständig blockiert

---

## Kennzahlen auf einen Blick

| Metrik | Wert | Bewertung |
|---|---|---|
| Tasks gesamt (aktiv + Archiv) | 11 aktiv + 1103 archiviert = 1114 | stabil |
| All-time Success Rate | **19%** | niedrig, aber durch alte Altlasten verzerrt |
| Recent-50 Success Rate | **70%** | sehr gut |
| First-Pass Success Rate | **80%** (12/15) | stark |
| Timeout-Rate (historisch) | 32% (210 Timeouts) | unverändert |
| Zero-Step-Timeouts | 227 (91% aller Timeouts) | historisch, keine neuen |
| Zombie Tasks | 20 (166 verschwendete Slots) | archiviert, nicht mehr aktiv |
| Registry-Größe | 90 KB aktiv / 292 KB gesamt | unter Pressure-Limit (512 KB) |
| Queues | **BEIDE LEER** | seit ~30h+ |
| Aktive Alerts | 2 (retry_churn, loop_effort) | braucht Aufmerksamkeit |
| Learned Rules | 10 | +5 seit 30.03. |
| Knowledge Base | 199 Einträge | stabil |

---

## 1. Steigt die Success Rate? — JA, klar

Der Trend ist eindeutig positiv. Die Iteration-Windows zeigen eine Entwicklung von 4-6% im Mittelteil auf 58-71% in den letzten 64 Tasks:

| Window | Success Rate | Timeouts |
|---|---|---|
| 1–50 | 34% | 19 |
| 101–200 | 4–6% | 33–38 (Tiefpunkt) |
| 401–500 | 22–26% | 20–29 |
| 601–650 | **58%** | 1 |
| 651–664 | **71%** | 0 |

**Improvement-Velocity:** +5.6pp pro 100 Tasks gesamt, +9.2pp/100 bei non-timeout Tasks. Das System lernt messbar.

**Provider-Performance (codex):** Auth-Tasks sind der Spitzenreiter mit 68% Success Rate (25 Tasks). Testing liegt bei 50%. UI und Infra bleiben schwach (13-14%).

---

## 2. Sind die bisherigen Tasks umsetzbar?

### Aktives Registry (11 Tasks):

**Completed (4 Tasks) — erfolgreich umgesetzt:**
- `task-006` Syntax-Check Planner — Kommentar-Dokumentation
- `task-007` Step-Cap-Verification — Test hinzugefügt
- `task-008` Learner-Comment Fix — Dedup-Threshold dokumentiert
- `task-011` Retry-Success-Rate Improvement — wirkt

**Shelved (7 Tasks) — Status-Bewertung:**

| Task | Umsetzbar? | Empfehlung |
|---|---|---|
| `task-002` Context-Clamp-Test | Ja, nach Plan-Simplification | Re-queue mit einfacherem Plan |
| `task-003` Classify-Retry-Test | Ja | Re-queue mit kompakteren Steps |
| `task-004` Learner-Rule-Count | Ja, trivial | Re-queue |
| `task-001` External-Signal-Review | Ja, aber veraltet | Verwerfen (Signal von 25.03.) |
| `task-005` System-Work-Buffer | Nein, zu abstrakt | Verwerfen oder stark umformulieren |
| `task-009` Decision-Path-Inventory | Nein, kein klarer Deliverable | Verwerfen |
| `task-010` Timeout-Rate-Reduktion | Ja, strategisch wichtig | Umformulieren mit konkretem Deliverable |

**Fazit:** 3 von 7 geshelved Tasks sind direkt re-queue-bar, 2 sollten verworfen, 2 brauchen Umformulierung.

---

## 3. Notwendige Modifikationen

### KRITISCH: Cooldown-Deadlock auflösen

**Problem:** Drei Cooldown-Dateien blockieren die gesamte Pipeline:
- `self-improve-cooldown` → Inhalt: `0` (seit 30.03. 23:51)
- `self-improve-codex-agent-system-cooldown` → Inhalt: `0` (seit 30.03. 23:51)
- `self-improve-superheld-cooldown` → Timestamp `1774919051` (erneuert sich)

Der `self-improve-run.json` zeigt `dominant_reason: cooldown_active`. Keine neuen Tasks werden generiert. Die Queues sind leer, weil der Self-Improve-Loop sich selbst blockiert.

**Empfehlung:** Die Cooldown-Dateien manuell löschen oder auf einen vergangenen Timestamp setzen, damit die Pipeline wieder anlaufen kann.

### WARNUNG: Retry-Churn und Loop-Effort

Zwei aktive Alerts:
- **retry_churn** (high): Das System wiederholt gescheiterte Ansätze ohne Fortschritt
- **loop_effort** (warning): 13 Tasks haben zusammen 28 Extra-Step-Attempts verbraucht

**Empfehlung:** Vor dem Neustart der Pipeline die 7 geshelved Tasks reviewen und nicht-umsetzbare endgültig verwerfen, damit sie nicht erneut Retry-Churn erzeugen.

### OPTIMIERUNG: Provider-Routing verfeinern

| Kategorie | Claude Success | Codex Success | Empfehlung |
|---|---|---|---|
| Auth | 0% (3 Tasks) | **68%** (25) | Codex korrekt |
| UI | 15% (74) | 13% (160) | Beide schwach — Tasks vereinfachen |
| Code Quality | 0% (5) | 11% (19) | Beide schwach — Tasks zu komplex |
| Testing | 36% (14) | 50% (6) | Claude besser — Routing umkehren? |

**Empfehlung:** Testing-Tasks an Claude routen (36% vs 50%, aber mehr Volumen). UI-Tasks grundsätzlich mit simpleren Plänen (max 3 Steps statt 6).

### SYSTEM-KONFIGURATION

| Parameter | Aktuell | Empfehlung |
|---|---|---|
| MAX_STEPS | 6 | Für UI-Tasks auf 3-4 reduzieren |
| Cooldown-Mechanik | Self-renewing | Circuit-Breaker mit max 2h Cooldown |
| Zombie-Guard | 5+ Failures → Shelve | Funktioniert, beibehalten |
| Registry Pressure | 292 KB (unter 512 KB) | OK, kein Handlungsbedarf |

---

## 4. Zusammenfassung

**Was gut läuft:**
- Success Rate steigt klar (19% gesamt → 71% letzte 14 Tasks)
- First-Pass-Rate bei 80% — die Planner-Verbesserungen wirken
- Zero-Step-Timeouts in den letzten 64 Tasks: 0
- Learned Rules wachsen organisch (10 Regeln, +5 in 24h)
- Registry-Pressure unter Kontrolle

**Was blockiert:**
- Cooldown-Deadlock stoppt die gesamte Pipeline seit 30+ Stunden
- Kein neuer Task-Durchsatz möglich ohne manuellen Eingriff
- 2 aktive Alerts (retry_churn, loop_effort) zeigen Ineffizienz bei Retries

**Nächste Schritte (priorisiert):**
1. **Cooldown-Dateien manuell löschen** — sofortiger Pipeline-Restart
2. **Shelved Tasks bereinigen** — 2 verwerfen, 3 re-queuen, 2 umformulieren
3. **UI-Task-Pläne vereinfachen** — max 3-4 Steps für UI-Kategorie
4. **Testing-Routing prüfen** — Claude für Testing-Tasks testen
5. **Cooldown-Mechanik überarbeiten** — max-TTL von 2h einführen, kein Self-Renewal
