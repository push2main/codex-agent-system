# Fortschrittsbericht — 31. März 2026, v2 (Scheduled)

## Systemstatus: PIPELINE STALL — Cooldowns aktiv seit ~30h, Queues leer

---

## Kennzahlen

| Metrik | Wert | Trend vs. v16 (30.03.) |
|---|---|---|
| Tasks gesamt (historisch) | 658 (+1103 Archive) | +17 seit v16 |
| All-time Success Rate | 18% | +1pp |
| Recent-50 Success Rate | 62% | **+10pp** |
| First-Pass Success Rate | 67% | **+5pp** |
| Timeout-Rate | 32% (210 von 658) | -1pp |
| Zero-Step-Timeouts | 227 | unverändert (kein neuer Timeout) |
| Zombie Tasks | 20 | unverändert |
| Retry-Churn Alert | aktiv (11 Tasks, 17 Extra-Attempts) | +3 Tasks |
| Queues | **BEIDE LEER** | unverändert seit v16 |
| Cooldowns | 4 aktiv (seit ~30h) | **erneuert** am 30.03. 23:51 |
| Learned Rules | 10 | +5 seit v16 |
| Knowledge Base | 199 Einträge | stabil |

---

## 1. Trend-Analyse: Success Rate — KLAR POSITIV

Die Recent-50 Rate ist von 52% (v16) auf **62%** gestiegen. Die traced-task Analyse zeigt:

| Provider | Tasks | Success Rate |
|---|---|---|
| claude-code | 8 | **62.5%** |
| codex | 92 | 40.2% |
| codex-cli | 67 | 28.4% |

**Beste Kategorien (codex):** auth (66.7%), testing (50.0%), general (25.4%)
**Schwächste:** ui (10.9%), code_quality (10.5%), learning (11.8%)

### Archiv-Window-Trend (50er-Blöcke, Auszug):

| Window | Success Rate |
|---|---|
| 701–750 | **54%** ← Bestwert |
| 951–1000 | 30% |
| 1001–1050 | **40%** |
| 1051–1100 | 0% (massive Shelving-Welle) |

Die letzten produktiven Windows (701–750, 1001–1050) zeigen gute Rates. Die 0%-Fenster (501–550, 751–850, 1051–1100) sind durchweg Shelving-Wellen, keine echten Failures. Wenn man nur Windows mit tatsächlicher Execution betrachtet, liegt die Rate bei **~35–54%**.

**Fazit:** Der Aufwärtstrend hält an. Die Success Rate bei aktiv ausgeführten Tasks hat sich stabilisiert bei 40–62%.

---

## 2. Sind die bisherigen Tasks umsetzbar?

### Registry: codex-memory (11 Tasks)

- **4 completed** — alle erfolgreich (Planner-Tests, Learner-Docs, Retry-Rate)
- **7 shelved** — gesperrt durch Zombie-Guard oder manuelle Intervention

### Registry: superheld (10 Tasks)

- **5 completed** — Dashboard-Contract, Incident-Schema, Credential-Routing
- **4 shelved** — darunter 3x Dashboard-Blueprint-Varianten, 1x OpenAI-Check
- **1 running** — `Add baseline verification for dashboard payload contract fields`

**Bewertung der laufenden Tasks:**

Der einzige running Task (`task-052`) ist ein Stability-Task für Baseline-Verification im Superheld-Projekt. Impact 6, Effort 2, Confidence 85%. Dieser ist grundsätzlich umsetzbar — er arbeitet mit existierenden Scripts (`verify-baseline.sh`) und einem klaren Schema.

**Bewertung der geshelved Tasks:**

Die Shelving-Wellen im Archiv (501–550, 751–850, 1051–1100 — zusammen 283 Tasks) deuten darauf hin, dass der Zombie-Guard und die Cooldown-Mechanismen zu aggressiv greifen. Viele Tasks werden präventiv geshelved, bevor sie überhaupt ausgeführt werden.

---

## 3. Kritische Blocker

### BLOCKER 1: Cooldown-Deadlock (wiederkehrend)

Vier Cooldown-Files sind aktiv:

| Datei | Alter | Inhalt |
|---|---|---|
| `self-improve-cooldown` | ~30h (30.03. 23:51) | `0` |
| `self-improve-codex-agent-system-cooldown` | ~30h | `0` |
| `self-improve-superheld-cooldown` | ~29h (31.03. 01:00) | Timestamp |
| `strategy-timeout-cooldown` | ~29h (31.03. 01:03) | Timestamp |

**Auswirkung:** `self-improve-run.json` zeigt `dominant_reason: cooldown_active`. Keine neuen Tasks werden generiert. Beide Queues sind komplett leer.

**Dieses Problem wurde bereits im v16-Report (30.03.) identifiziert.** Die Cooldowns wurden offenbar am 30.03. 23:51 erneuert (statt gelöscht), was den Stall verlängert hat.

### BLOCKER 2: Leere Queues = Keine Execution

Ohne Task-Generierung (blockiert durch Cooldowns) gibt es nichts zu verarbeiten. Die Pipeline ist seit mindestens 30h inaktiv.

### BLOCKER 3: Shelving-Aggressivität

283 von 1103 archivierten Tasks (25.6%) haben Status `shelved`. In einigen Windows werden 50/50 Tasks geshelved. Dies deutet auf zu aggressive Zombie-Guards oder Cooldown-Trigger hin, die productive Capacity vernichten.

---

## 4. Empfehlungen

### SOFORT — Manueller Eingriff erforderlich:

**A) Cooldown-Files löschen** — Dies ist der wichtigste Schritt:
```bash
rm codex-logs/self-improve-cooldown
rm codex-logs/self-improve-codex-agent-system-cooldown
rm codex-logs/self-improve-superheld-cooldown
rm codex-logs/strategy-timeout-cooldown
rm codex-logs/strategy-timeout-cooldown.state
```

**B) Queue-Seeding:** Nach Cooldown-Löschung prüfen, ob die Task-Generation automatisch anspringt. Falls nicht, manuell 2–3 Tasks in die Queues einspeisen.

### SYSTEM-MODIFIKATION — Mittelfristig:

**C) Cooldown-Logik überarbeiten:**
- Die Cooldowns erneuern sich selbst (30.03. 23:51 zeigt Neuschreibung). Der Self-Improve-Loop schreibt Cooldowns, die er dann selbst nicht löschen kann → **Deadlock by Design**.
- Empfehlung: Cooldown-TTL einführen (z.B. max 6h), nach dem Cooldowns automatisch ablaufen.

**D) Shelving-Threshold lockern:**
- 25.6% Shelving-Rate ist zu hoch. Der Zombie-Guard sollte nur Tasks shelven, die tatsächlich 5+ Mal mit identischem Fehler gescheitert sind, nicht Tasks, die noch nie ausgeführt wurden.

**E) UI-Tasks an claude-code umrouten:**
- `codex/ui` hat nur 10.9% Success Rate bei 156 Tasks — die schlechteste Kategorie.
- `claude-code` hat 62.5% über alle Kategorien. Provider-Routing für UI-Tasks auf `claude-code` umstellen.

**F) Code-Quality und Learning Tasks pausieren:**
- Bei 10.5% und 11.8% Success Rate verbrauchen diese Kategorien Ressourcen ohne Return. Fokus auf auth (66.7%), testing (50%) und general (25.4%).

---

## 5. Zusammenfassung

| Frage | Antwort |
|---|---|
| Steigt die Success Rate? | **Ja** — 62% recent (von 52% vor 2 Tagen) |
| Sind Tasks umsetzbar? | **Ja** — bei Execution liegt die Rate bei 40–62% |
| Braucht es Modifikationen? | **Ja** — Cooldown-Deadlock muss sofort gelöst werden |
| Größtes Risiko? | Pipeline-Stall durch sich selbst erneuernde Cooldowns |
| Größte Chance? | Provider-Routing-Optimierung (claude-code für UI) könnte die schwächste Kategorie von 10.9% auf ~50%+ heben |

**Gesamtbewertung: Das System lernt nachweislich und die Task-Qualität verbessert sich. Der Hauptblocker ist kein inhaltliches Problem, sondern ein mechanischer Deadlock in der Cooldown-Logik, der manuellen Eingriff erfordert.**
