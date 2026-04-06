# Fortschritt-Report — 2026-03-31 (v17, Scheduled)

## Zusammenfassung

Das System befindet sich in einem **stabilen, aber inaktiven Zustand**. Die Execution Engine zeigt starke Performance (82% Recent-SR, 77% First-Pass), aber der gesamte Self-Improve-Zyklus für codex-agent-system steht seit 5+ Tagen still. Ursache ist ein Deadlock aus drei zusammenwirkenden Faktoren: leere Automation-Memory, leere Queues und aktiver Cooldown. Ohne Eingriff wird das System keine neuen Tasks generieren.

---

## Kennzahlen

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| All-time Success Rate | 22% (694 Tasks) | Historisch belastet |
| Recent-50 SR | **82%** | Exzellent |
| Q4 SR (letzte 278) | 16.2% | Viele Shelved/Failed aus Vor-Optimierung |
| First-Pass SR | 77% (10/13) | Gut |
| Timeout-Rate | 30% (kumulativ) | Zero-Step-Timeouts eliminiert |
| Registry-Größe | 226 KB (21 Tasks) | Kein Pressure |
| Queue-Status | **Leer** (beide Queues) | Kritisch |
| Archiv | 1103 Tasks | 196 completed, 406 failed, 375 shelved |

## Letzte 50 Tasks — Alarmsignal

Die letzten 50 archivierten Tasks zeigen **0% Success Rate**. Sie bestehen fast ausschließlich aus:
- ~30 shelved "Inventory current decision path for..." (Learning-Kategorie)
- ~10 failed Tasks (timeout, missing_source_file, retry-churn)
- 2 rejected "Review external signal" Tasks

Das System hat sich in einen Zyklus aus inventory-Tasks und Shelving manövriert, ohne echte Arbeit zu produzieren.

## Sind die bisherigen Tasks umsetzbar?

### Aktive Registry (11 Tasks: 4 completed, 7 shelved)

| Task | Status | Umsetzbar? | Empfehlung |
|------|--------|------------|------------|
| Unit-Test clamp_prompt_context | shelved | Nein — missing_source_file | Archivieren oder mit Inventory-First neu aufsetzen |
| Unit-Test classify_retry_failure | shelved | Nein — missing_source_file | Archivieren oder mit Inventory-First neu aufsetzen |
| learner.sh dedup threshold comment | shelved | Ja, trivial | Manuell lösen oder neu queuen |
| External Signal Review OpenAI v2.30.0 | shelved | Nein — kein Actionable | Archivieren |
| Queue-Buffer-Task | shelved | Nein — konzeptionell überholt | Archivieren |
| Planning-Budget-Inventory | shelved | Nein — Zero-Step-Timeouts bereits gelöst | Archivieren |
| Timeout-Reduction | shelved | Nein — Timeout-Problem bereits adressiert | Archivieren |

**Fazit:** 5 von 7 shelved Tasks sind obsolet und sollten archiviert werden. 2 Unit-Test-Tasks können mit Inventory-First-Pattern neu aufgesetzt werden. Die 4 completed Tasks brauchen keine Aktion.

## Heben wir die Success Rate?

**Ja, massiv — aber nur im Recent-Window:**

- All-time: 13.5% → 22% (+8.5pp über Gesamtlaufzeit)
- Recent-50: **82%** (getragen durch Superheld-Projekt)
- First-Pass: 77%
- Zero-Step-Timeouts: von 227 auf 0 reduziert

Die Verbesserung ist real und strukturell: das Inventory-First-Pattern, die Learned Rules (10 aktive), und die Zombie-Task-Guards wirken. Aber die Last-50 im Archiv (0% SR) zeigen, dass **keine neuen produktiven Tasks mehr generiert werden** — die Engine läuft gut, hat aber nichts zu tun.

## Wo sind Modifikationen nötig?

### 1. KRITISCH: Dreifach-Deadlock auflösen

Drei Blocker wirken zusammen:

1. **Automation-Memory leer**: `source: "none"`, `external_sync_pending: true` → kein Task-Generator aktiv
2. **Queues leer**: `codex-agent-system.txt` enthält keine Tasks, kein Nachschub
3. **Cooldown aktiv**: `gating.dominant_reason: "cooldown_active"` → Self-Improve blockiert

**Fix (alle drei nötig):**
- `self-improve-automation-memory.json`: `external_sync_pending → false`, `source → "internal"`
- Manuell 2-3 Canary-Tasks in `codex-queue/codex-agent-system.txt` einspeisen
- Cooldown-TTL prüfen und ggf. auf max 2h cappen

### 2. WICHTIG: Provider-Routing überdenken

Alle 8 Kategorien routen zu `codex`. Der Claude-Provider wird komplett ignoriert, obwohl die Performance bei UI-Tasks vergleichbar ist (codex 22% vs. claude 15% auf historischen Daten — kleiner Unterschied bei hoher Varianz).

**Empfehlung:** Claude-Provider für `ui`-Kategorie als 50/50-Split testen.

### 3. EMPFOHLEN: Zombie-Tasks final bereinigen

Drei Zombie-Patterns mit 5+ Failures:
- "Tighten mobile dashboard..." (11x failed)
- "Detect retry churn..." (6x failed)
- "Reduce timeout rate" (5x failed)

Diese sollten permanent geshelved bleiben und nicht re-approved werden.

### 4. EMPFOHLEN: Retry-Churn adressieren

`retry_churn_detected: true` und `loop_effort_detected: true` (9 Tasks, 19 extra Step-Attempts). Der Loop-Effort ist zwar reduziert gegenüber früheren Werten, aber noch vorhanden.

### 5. EMPFOHLEN: Failure-Reason-Klassifikation verbessern

104 von 104 failed Tasks in den letzten 200 haben `failure_reason: "unknown"`. Das macht Root-Cause-Analyse unmöglich. Die Klassifikation bei Task-Failure sollte spezifischere Gründe erfassen (timeout, missing_file, syntax_error, etc.).

## Bewertung

| Bereich | Status | Dringlichkeit |
|---------|--------|---------------|
| Execution Engine | ✅ Stabil (82% SR) | Keine Aktion nötig |
| Task-Qualität (Inventory-First) | ✅ Bewährt | Beibehalten |
| Self-Improve Loop | ❌ Deadlock | **Sofort** beheben |
| Queue-Management | ❌ Ausgetrocknet | **Sofort** füllen |
| Learned Rules | ✅ 10 aktiv, wirksam | Weiter akkumulieren |
| Zero-Step-Timeouts | ✅ Eliminiert | Gelöst |
| Provider-Routing | ⚠️ Einseitig | Mittelfristig optimieren |
| Failure-Klassifikation | ⚠️ 100% "unknown" | Mittelfristig beheben |
| Registry-Hygiene | ⚠️ 5 obsolete Tasks | Kurzfristig aufräumen |

## Nächste Schritte (Priorität)

1. **Self-Improve-Memory reparieren** — `external_sync_pending: false`, `source: "internal"` setzen
2. **Cooldown prüfen/aufheben** — damit der Task-Generator wieder anspringt
3. **2-3 Canary-Tasks manuell einspeisen** — z.B. Unit-Tests mit Inventory-First-Pattern
4. **5 obsolete shelved Tasks archivieren** — Registry sauber halten
5. **Failure-Reason-Klassifikation implementieren** — "unknown" durch spezifische Gründe ersetzen
6. **Provider-Routing: Claude für UI testen** — 50/50-Split
