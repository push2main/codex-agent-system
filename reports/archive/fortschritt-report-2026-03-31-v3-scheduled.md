# Fortschrittsbericht — 31. März 2026, v3 (Scheduled, 00:07 UTC)

## Systemstatus: COOLDOWN-STALL — Queues leer, Pipeline blockiert

---

## Kennzahlen (Stand jetzt)

| Metrik | Wert | Trend |
|---|---|---|
| Tasks gesamt (inkl. Archiv) | 662 aktiv-historisch + 1103 Archiv | stabil |
| All-time Success Rate | 19% | +1pp vs. letzter Report |
| Recent-50 Success Rate | **70%** | **+8pp vs. v2** |
| First-Pass Success Rate | **77%** | **+10pp vs. v2** |
| Timeout-Rate | 32% (210 Timeouts) | stabil |
| Zero-Step-Timeouts | 227 (91% aller Timeouts) | unverändert |
| Zombie Tasks | 20 (166 verschwendete Slots) | unverändert |
| Retry-Churn | aktiv (11 Tasks, 21 Extra-Attempts) | **+4 Extra-Attempts** |
| Queues | **BEIDE LEER** | seit >30h |
| Cooldowns | 3 aktiv (jüngster: 2.3h alt) | erneuern sich selbst |
| Learned Rules | 10 | +5 seit 30.03. |
| Knowledge Base | 199 Einträge | stabil |

---

## 1. Steigt die Success Rate? — JA, deutlich

Die Trend-Daten zeigen eine klare Verbesserung:

| Window | Success Rate | Timeouts |
|---|---|---|
| 1–50 (Anfang) | 34% | 19 |
| 101–200 | 4–6% | 33–38 (Tiefpunkt) |
| 401–500 | 22–26% | 20–29 |
| 601–650 | **58%** | 1 |
| 651–662 | **67%** | 0 |

Die Improvement-Velocity liegt bei +5.4pp pro 100 Tasks (non-timeout: +8.7pp/100). Der Trend ist klar positiv — das System lernt messbar aus seinen Fehlern.

**Superheld-Projekt:** 9 von 13 Tasks completed (69.2% Success Rate). Nur 4 shelved, keine failures. Das ist das stärkste Einzelprojekt im System.

**Codex-agent-system:** 4 von 11 Tasks completed (36.4%), 7 shelved. Die Shelving-Welle nach dem Pipeline-Recovery am 28./29. März hat hier stärker gegriffen.

---

## 2. Sind die bisherigen Tasks umsetzbar? — JA, mit Einschränkungen

**Umsetzbare Tasks (completed):**
- Planner-Tests (Syntax-Check, Step-Cap-Verification) — erfolgreich
- Learner-Dokumentation (Dedup-Threshold-Comment) — erfolgreich
- Retry-Rate Improvement — erfolgreich
- Superheld: Dashboard-Contract, Incident-Schema, Credential-Routing, Baseline-Verification — alle erfolgreich

**Geshelved aber grundsätzlich umsetzbar (nach Cooldown-Fix):**
- `task-002` (Context-Clamp-Test) — gescheitert an review_rejection durch zu verbose Steps. Root cause ist behoben (Planner-Step-Cap).
- `task-003` (Classify-Retry-Test) — gleiches Problem, gleicher Fix.
- `task-010` (Timeout-Rate-Reduktion) — strategisch sinnvoll, braucht aber simplere Pläne.

**Nicht umsetzbar / zu komplex:**
- `task-005` (System-Work-Buffer) — zu abstrakt formuliert, Scope unklar.
- `task-009` (Decision-Path-Inventory) — investigative Aufgabe, kein klarer Deliverable.

---

## 3. Kritische Blocker

### BLOCKER 1: Cooldown-Deadlock (WICHTIGSTER BLOCKER)

Drei Cooldown-Files blockieren die gesamte Task-Generierung:

| Datei | Inhalt | Alter |
|---|---|---|
| `self-improve-cooldown` | `0` | 2.3h |
| `self-improve-codex-agent-system-cooldown` | `0` | 2.3h |
| `self-improve-superheld-cooldown` | Timestamp | ~0.1h |

Die `self-improve-run.json` zeigt `dominant_reason: cooldown_active`. Keine neuen Tasks werden generiert, beide Queues sind leer.

**Problem:** Die Cooldowns erneuern sich selbst — der Self-Improve-Loop schreibt neue Cooldowns, die er dann selbst respektiert. Das ist ein Deadlock by Design.

### BLOCKER 2: Retry-Churn (HIGH Alert)

11 Tasks mit 21 Extra-Step-Attempts zeigen, dass der Loop-Effort-Detector anschlägt. Tasks werden wiederholt ohne Fortschritt — das verbraucht Ressourcen und treibt Cooldowns hoch.

### BLOCKER 3: Archiv-Analyse zeigt Shelving-Übergewicht

Archiv-Verteilung (1103 Tasks):
- 196 completed (17.8%)
- 406 failed (36.8%)
- 375 shelved (34.0%)
- 121 rejected (11.0%)
- 5 sonstige

34% Shelving-Rate ist hoch. Viele Tasks werden geshelved bevor sie überhaupt ausgeführt werden (Zombie-Guard, Cooldown-Trigger).

---

## 4. Provider-Performance

| Provider | Kategorie | Tasks | Success Rate |
|---|---|---|---|
| codex | auth | 24 | **66.7%** |
| codex | testing | 6 | **50.0%** |
| codex | general | 142 | 25.4% |
| claude | testing | 14 | 35.7% |
| claude | general | 54 | 18.5% |
| codex | ui | 160 | **13.1%** ← Problem |
| claude | ui | 74 | **14.9%** ← Problem |
| codex | code_quality | 19 | 10.5% |
| codex | learning | 34 | 11.8% |

UI-Tasks sind mit ~13–15% bei beiden Providern die größte Schwachstelle (234 Tasks gesamt, nur ~33 erfolgreich).

---

## 5. Empfehlungen

### SOFORT — Manueller Eingriff

**A) Cooldown-Files löschen:**
```bash
rm codex-logs/self-improve-cooldown
rm codex-logs/self-improve-codex-agent-system-cooldown
rm codex-logs/self-improve-superheld-cooldown
rm codex-logs/strategy-timeout-cooldown.state
```

### SYSTEM-MODIFIKATION — Konfiguration

**B) Cooldown-TTL einführen:**
Die Cooldowns brauchen ein automatisches Ablaufdatum (z.B. 6h). Ohne TTL entsteht immer wieder derselbe Deadlock. Das ist das strukturell wichtigste Problem im System.

**C) Shelved Tasks task-002 und task-003 re-approven:**
Die Root Cause (verbose Steps >600 chars) wurde im Planner behoben. Diese beiden Test-Tasks sollten nach Cooldown-Fix erneut ausgeführt werden können.

**D) UI-Task-Strategie überdenken:**
234 UI-Tasks mit ~14% Success Rate sind der größte Ressourcen-Verbraucher. Optionen:
- UI-Tasks auf claude-code umrouten (bessere Browser/DOM-Fähigkeiten)
- Oder: UI-Task-Komplexität reduzieren — kleinere, atomare Steps

**E) code_quality und learning Tasks drosseln:**
Bei 10–12% Success Rate sind diese Kategorien ineffizient. Fokus auf auth (66.7%) und testing (50%).

### TASK-MODIFIKATION

**F) Task-005 und task-009 umformulieren oder entfernen:**
Beide sind zu abstrakt. Entweder in konkrete, testbare Deliverables aufbrechen oder permanent shelven.

---

## 6. Zusammenfassung

| Frage | Antwort |
|---|---|
| Steigt die Success Rate? | **Ja** — 70% recent, 77% first-pass, +27pp Gesamttrend |
| Sind Tasks umsetzbar? | **Ja** — 69% im Superheld-Projekt, 36% im Hauptprojekt |
| Braucht es Modifikationen? | **Ja** — Cooldown-Deadlock blockiert Pipeline komplett |
| Größter Blocker? | Cooldown-Dateien erneuern sich selbst → Pipeline-Stall |
| Größte Chance? | UI-Task-Routing-Optimierung könnte ~234 Tasks-Kategorie von 14% auf 40%+ heben |
| Systemgesundheit? | Lernmechanismus funktioniert (10 Rules, 199 Knowledge). Aber Pipeline ist seit Stunden inaktiv. |

**Gesamtbewertung: Das System zeigt nachweislichen Lernfortschritt — die Success Rate hat sich von 4% (Tiefpunkt) auf 67–77% (aktuell) verbessert. Die Tasks sind grundsätzlich umsetzbar. Der einzige kritische Blocker ist der sich selbst erneuernde Cooldown-Deadlock, der manuellen Eingriff oder einen Code-Fix (TTL) erfordert.**
