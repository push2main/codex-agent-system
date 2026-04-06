# Fortschritt-Report — 2026-03-31 (v16, Scheduled)

## Zusammenfassung

Das System zeigt eine **zweigeteilte Lage**: Die Ausführungs-Engine funktioniert zuverlässig (82% SR auf den letzten 50 Tasks, 85% First-Pass), aber das **Codex-Agent-System selbst steht seit 5+ Tagen still**, weil der Self-Improve-Zyklus durch einen Deadlock blockiert ist. Nur das Superheld-Projekt produziert aktiv Tasks und löst sie erfolgreich.

---

## Kennzahlen

| Metrik | Wert | Trend |
|--------|------|-------|
| All-time Success Rate | 21% (690 Tasks) | +4pp vs. gestern |
| Recent-50 SR | **82%** | +30pp vs. gestern |
| First-Pass SR | 85% (17/20) | Stabil/Exzellent |
| Timeout-Rate (kumulativ) | 31% (211/690) | Zero-Step-Timeouts eliminiert |
| Aktive Registry | 4 done, 7 shelved | Kein Throughput |
| Queue-Status | **Beide leer** | Seit ~5 Tagen |
| Archiv | 1103 Tasks (196 done, 406 failed, 375 shelved, 121 rejected) | — |

## Heutige Runs (31.03.2026)

Alle 4 Runs auf dem **Superheld-Projekt** — alle erfolgreich:

1. Inventory credential recovery routing → **100/100**
2. Inventory dashboard incident payload → **66/100**
3. Verify trigger-aware credential recovery → **100/100**
4. Verify dashboard incident payload coverage → **100/100**

Das Superheld-Pattern (Inventory-first → Verify → Implement) funktioniert nachweislich.

## Sind die bisherigen Tasks umsetzbar?

### Aktive Tasks (4 completed, 7 shelved)

Die **7 geshelved-ten Tasks** sind in ihrer jetzigen Form **nicht umsetzbar**:

- **3 Unit-Test-Tasks** (task-002, -003, -004): Scheiterten jeweils nach 2 Versuchen an `missing_source_file` — die referenzierten Dateipfade existieren nicht. **Modifikation nötig:** Zuerst Inventory-Step, dann Pfad-abhängige Implementierung.
- **1 External-Signal-Review** (OpenAI Python v2.30.0): Keine Ausführung mangels klarem Actionable-Output. **Empfehlung:** Schließen oder als Info-only archivieren.
- **1 Queue-Buffer-Task**: Nie ausgeführt, konzeptionell überholt durch aktuelle Queue-Logik. **Empfehlung:** Archivieren.
- **1 Planning-Budget-Inventory**: Nie ausgeführt, aber relevant — Zero-Step-Timeouts wurden durch andere Maßnahmen gelöst. **Empfehlung:** Archivieren.
- **1 Timeout-Reduction-Task**: 0 Attempts, Timeout-Rate bereits reduziert. **Empfehlung:** Archivieren als gelöst.

**Fazit:** 5 von 7 shelved Tasks können archiviert werden. 2 Unit-Test-Tasks (task-002, -003) könnten mit Inventory-First-Pattern neu aufgesetzt werden.

## Heben wir die Success Rate?

**Ja — deutlich und nachhaltig:**

- Von 21% all-time auf **82% recent-50** (+61pp)
- Von 50% First-Half auf 82% Second-Half (+32pp)
- Zero-Step-Timeouts (227 Tasks, 91% aller Timeouts) sind **komplett eliminiert**
- Verbesserungsgeschwindigkeit: +6.2pp pro 100 Tasks

Die **82% SR ist real und stabil** — sie wird durch das Superheld-Projekt getragen, das konsistent 80-100% Scores liefert.

## Wo sind Modifikationen nötig?

### KRITISCH: Self-Improve Deadlock aufheben

**Problem:** `self-improve-automation-memory.json` steht auf:
```json
{
  "automation_id": "",
  "source": "none",
  "external_sync_pending": true
}
```
→ Das System generiert keine neuen Tasks für codex-agent-system.

**Fix:** `external_sync_pending → false`, `source → "internal"` setzen.

### KRITISCH: Queue-Starvation seit 5+ Tagen

Beide Queues (`codex-agent-system.txt`, `superheld.txt`) sind leer. Superheld generiert Tasks über den Orchestrator direkt, aber codex-agent-system hat keine Task-Quelle.

**Fix:** Task-Generator für codex-agent-system reaktivieren oder manuell 2-3 Canary-Tasks einspeisen.

### WICHTIG: Provider-Routing optimieren

Alle Kategorien routen zu `codex`. Claude-Provider wird nicht genutzt, obwohl er bei UI-Tasks ähnlich performt. Empfehlung: Claude für UI-Tasks reaktivieren (Routing-Split 50/50).

### EMPFOHLEN: Shelved Tasks aufräumen

- 375 shelved Tasks im Archiv + 7 in der aktiven Registry
- 5 aktive shelved Tasks archivieren (siehe oben)
- Registry-Druck niedrig halten

## Bewertung

| Bereich | Status | Aktion |
|---------|--------|--------|
| Execution Engine | ✅ Stabil (82% SR) | Keine Änderung |
| Task-Qualität | ✅ Verbessert | Inventory-First beibehalten |
| Self-Improve Loop | ❌ Deadlock | automation-memory reparieren |
| Queue-Management | ❌ Ausgetrocknet | Task-Generator reaktivieren |
| Provider-Routing | ⚠️ Suboptimal | Claude für UI aktivieren |
| Learned Rules | ✅ 10 aktiv, effektiv | Weiter akkumulieren |
| Zero-Step-Timeouts | ✅ Eliminiert | Problem gelöst |

## Nächste Schritte (Priorität)

1. **Self-Improve-Memory reparieren** — `external_sync_pending: false` setzen
2. **2 Canary-Tasks manuell einspeisen** — Unit-Test-Tasks mit Inventory-First-Pattern
3. **5 obsolete shelved Tasks archivieren**
4. **Provider-Routing: Claude für UI-Kategorie testen**
5. **Cooldown-TTL auf max 2h cappen** — verhindert erneute Deadlocks
