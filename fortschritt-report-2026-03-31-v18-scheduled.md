# Fortschritt-Report — 2026-03-31 (v18, Scheduled)

## Zusammenfassung

Das System zeigt eine **gespaltene Bilanz**: Die Execution Engine arbeitet exzellent (82% Recent-SR, 90% im Superheld-Projekt), aber der Self-Improve-Loop für codex-agent-system steht seit ~5 Tagen im Deadlock. Es werden keine neuen Tasks generiert. Die bisherigen Tasks im aktiven Registry sind großteils obsolet (5 von 7 shelved Tasks). Ohne Eingriff bleibt das System im Leerlauf.

---

## Kennzahlen (Stand 31.03.2026)

| Metrik | Wert | Trend |
|--------|------|-------|
| All-time Success Rate | 22% (694 Tasks) | Historisch belastet |
| Recent-50 SR | **82%** | Stabil gut |
| First-Pass SR | 77% (10/13) | Gut |
| Superheld-Projekt SR | **90%** (9/10) | Exzellent |
| Timeout-Rate (kumulativ) | 30% | Zero-Step-Timeouts eliminiert |
| Registry | 226 KB, 21 Tasks | Kein Pressure |
| Archiv | 1103 Tasks | 196 ok, 406 fail, 375 shelved |
| Queue-Status | **Leer** | Kritisch |
| Aktive Alerts | 2 (retry_churn, loop_effort) | Bekannt |

### Trend über 50er-Fenster

Die Verbesserung ist klar sichtbar: von 4-6% Mitte der Laufzeit auf 58% (Fenster 601-650) und 84% (Fenster 651-694). Verbesserungsrate: +6.3pp pro 100 Tasks. Das Inventory-First-Pattern und die Learned Rules wirken.

## Sind die Tasks umsetzbar?

### Aktive Registry (11 Tasks: 4 completed, 7 shelved)

**Completed (keine Aktion nötig):**
- planner.sh MAX_STEP_CHARS Dokumentation ✅
- Planner-Step-Länge Test ✅
- learner.sh Dedup-Threshold Dokumentation ✅
- Retry-Success-Rate-Verbesserung ✅

**Shelved — Bewertung:**

| Task | Umsetzbar? | Empfehlung |
|------|------------|------------|
| Unit-Test clamp_prompt_context | Nein (missing_source_file) | Archivieren |
| Unit-Test classify_retry_failure | Nein (missing_source_file) | Archivieren |
| learner.sh Dedup-Kommentar | Ja, trivial | Manuell oder neu queuen |
| External Signal OpenAI v2.30.0 | Nein (kein Actionable) | Archivieren |
| Queue-Buffer-Task | Nein (konzeptionell überholt) | Archivieren |
| Planning-Budget-Inventory | Nein (Problem bereits gelöst) | Archivieren |
| Timeout-Reduction | Nein (bereits adressiert) | Archivieren |

**Fazit: 5 von 7 shelved Tasks sind obsolet.** Nur 1 ist trivial umsetzbar. Die Registry braucht Bereinigung.

### Superheld-Projekt: 90% SR — funktioniert

9 von 10 Tasks completed. Der Superheld-Workload ist der produktivste Teil des Systems und beweist, dass die Engine gut funktioniert.

## Heben wir die Success Rate?

**Ja — die strukturelle Verbesserung ist real:**

- Improvement-Velocity: +6.3pp pro 100 Tasks
- Non-Timeout-SR: 34% (von historisch viel schlechter)
- Zero-Step-Timeouts: von 227 auf 0 reduziert
- Retry-Klassifikation: 100% Coverage (von 24% "unknown")
- Learned Rules: 10 aktive, effektive Regeln

**Aber: Die letzten 50 archivierten Tasks zeigen 0% SR** — 30 shelved, 17 failed, 0 completed. Das liegt nicht an schlechter Engine-Performance, sondern daran, dass der Self-Improve-Loop keine produktiven Tasks mehr generiert.

## Wo sind Modifikationen notwendig?

### 1. KRITISCH: Self-Improve-Deadlock auflösen

Drei Faktoren blockieren sich gegenseitig:

- **Automation-Memory leer** (`source: "none"`, `external_sync_pending: true`)
- **Queues leer** (codex-agent-system.txt = 0 bytes)
- **Cooldown aktiv** (`gating.dominant_reason: "cooldown_active"`)

**Notwendige Fixes:**
1. `self-improve-automation-memory.json`: `source` → `"internal"`, `external_sync_pending` → `false`
2. Cooldown-Timer prüfen — ggf. auf max 2h TTL begrenzen
3. 2-3 Canary-Tasks manuell einspeisen (z.B. Unit-Tests mit Inventory-First-Pattern)

### 2. WICHTIG: Registry bereinigen

5 obsolete shelved Tasks archivieren. 3 Zombie-Patterns (11x, 6x, 5x failed) permanent auf der Blocklist halten.

### 3. EMPFOHLEN: Provider-Routing diversifizieren

Alle 8 Kategorien routen zu `codex`. Claude-Provider wird ignoriert, obwohl bei UI-Tasks die Differenz gering ist (22% vs 15%). Ein 50/50-Split für `ui`-Kategorie wäre ein sinnvoller Test.

### 4. EMPFOHLEN: Failure-Klassifikation verbessern

Die letzten 100+ Failures haben `failure_reason: "unknown"`. Spezifischere Gründe (timeout, missing_file, syntax_error) würden die Root-Cause-Analyse erheblich verbessern.

## Gesamtbewertung

| Bereich | Status | Dringlichkeit |
|---------|--------|---------------|
| Execution Engine | ✅ Stabil (82% SR, 90% Superheld) | Keine Aktion |
| Learned Rules | ✅ 10 aktiv, wirksam | Weiter akkumulieren |
| Zero-Step-Timeouts | ✅ Eliminiert | Gelöst |
| Task-Qualität (Inventory-First) | ✅ Bewährt | Beibehalten |
| Self-Improve Loop | ❌ Deadlock seit ~5 Tagen | **Sofort** |
| Queue-Management | ❌ Ausgetrocknet | **Sofort** |
| Registry-Hygiene | ⚠️ 5 obsolete Tasks | Kurzfristig |
| Provider-Routing | ⚠️ Einseitig | Mittelfristig |
| Failure-Klassifikation | ⚠️ 100% "unknown" | Mittelfristig |

## Empfohlene Prioritäten

1. **Deadlock auflösen** — Automation-Memory + Cooldown + Queue füllen
2. **Registry aufräumen** — 5 obsolete Tasks archivieren
3. **3 frische Canary-Tasks einspeisen** — mit Inventory-First-Pattern
4. **Failure-Reason-Klassifikation** — "unknown" ersetzen
5. **Provider-Routing** — Claude für UI testen
