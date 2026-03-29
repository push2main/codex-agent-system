# Self-Learning Report — Iteration 17
**Date:** 2026-03-26T06:08:00Z
**Type:** Scheduled task (autonomous)

## Leitfrage: Lernt das System effizient dazu?

**Ja — das Lernsignal ist stark, aber die Strategy-Pipeline war seit dem Auto-Shelve-Code komplett tot.**

### Effizienz-Metriken

| Metrik | Wert | Bewertung |
|--------|------|-----------|
| Gesamte Erfolgsrate | 15% | Historisch belastet |
| Non-Timeout-Erfolgsrate | 28% (287 Tasks) | **Echtes Lernsignal** |
| Non-Timeout-Velocity | +6.8 pp/100 Tasks | **Stark** |
| Trend-Fenster | 4% → 22-26% | **Klar aufwärts** |
| Strategy-Fehlerrate | 100% (jeder Zyklus) | **KRITISCH — jetzt gefixt** |
| Claude-Provider-Fehler | 1056+ | Unverändert, jetzt umgeleitet |
| Pipeline seit letztem Task | ~1h | Nicht mehr stale |
| Gelernte Regeln | 10 (vorher 8) | Wachsend |

### Identifizierte & Gelöste Probleme

**Problem 57: strategy.sh crasht JEDEN Zyklus — `datetime.datetime` AttributeError.**
- **Ursache:** `from datetime import datetime, timezone` (Klassen-Import), aber Code nutzt `datetime.datetime.now()` (Modul-Zugriff). Fehlende `timedelta`-Import.
- **Auswirkung:** Kein Strategy-Run erfolgreich seit Auto-Shelve-Code hinzugefügt. Keine neuen Tasks, keine Metriken-Updates, keine Board-Änderungen. Der Fehler loggte nur `[strategy] ERROR: Command failed at line 0 with exit code 1` — ohne Python-Traceback.
- **Fix:** `datetime.datetime.now()` → `datetime.now()`, `datetime.datetime.fromisoformat()` → `datetime.fromisoformat()`, `datetime.timedelta` → `timedelta`. Import erweitert: `from datetime import datetime, timedelta, timezone`.

**Problem 58: Auto-Approval zirkuläre Abhängigkeit von Metriken.**
- **Ursache:** Auto-Approval prüft `metrics.get("pipeline_stale")`, aber Metriken werden von strategy.sh aktualisiert — das bei jedem Zyklus crasht. `pipeline_stale` bleibt `false`, Auto-Approval feuert nie.
- **Auswirkung:** Doppel-Deadlock: Strategy-Crash + Metriken-Stale + Auto-Approval blockiert.
- **Fix:** Auto-Approval berechnet Pipeline-Staleness jetzt UNABHÄNGIG aus dem Task-Log (letzter Eintrag-Timestamp vs. aktuelle Zeit). Metriken nur als Fallback.

**Problem 59: Provider-Routing sendet 3 Kategorien an defekten Claude-Provider.**
- **Ursache:** `infra`, `testing`, `ui` noch auf `claude` geroutet trotz 1056+ Fehlern.
- **Fix:** Alle 8 Routing-Kategorien auf `codex` umgestellt.

### Verifikation

```
$ bash agents/strategy.sh codex-agent-system /tmp/test.json
→ {"status": "success", "message": "No strategy board changes were needed..."}
✓ Strategy läuft fehlerfrei

$ Pipeline-Staleness (unabhängig berechnet)
→ Letzter Task: 2026-03-26T05:16:56Z (0.9h ago) — nicht stale
✓ Auto-Approval-Independence funktioniert

$ Provider-Routing
→ Alle 8 Kategorien: codex
✓ Kein Traffic mehr an defekten Provider
```

### Architekturelles Meta-Muster (Iteration 17)

Ergänzt das Iteration-16-Muster ("Recovery muss unconditional sein") um ein neues Prinzip:

**RECOVERY MUSS UNABHÄNGIG SEIN.**
Recovery-Mechanismen dürfen ihren Trigger-Zustand nicht aus Systemen ableiten, die selbst vom gleichen Fehler betroffen sind. Eine zirkuläre Abhängigkeit (Metrics ← Strategy → Crash → Metrics stale → Auto-Approval blockiert) ist der schwierigste Deadlock-Typ, weil beide Seiten korrekt aussehen, wenn man sie einzeln prüft.

### Geänderte Dateien

1. `agents/strategy.sh` — datetime-Import-Fix (Zeilen 28, 3945, 3954)
2. `scripts/strategy-loop.sh` — Auto-Approval berechnet Staleness unabhängig aus Task-Log
3. `codex-learning/provider-routing.json` — Alle Kategorien auf codex
4. `codex-learning/rules.md` — 2 neue Regeln (datetime-Pattern, zirkuläre Abhängigkeiten)
5. `CLAUDE.md` — Iteration 17 Assessment

### Nächste Prioritäten

1. **Python-Syntax-Validation als Pre-Check:** `python3 -c "import ast; ast.parse(code)"` vor jedem Strategy-Run, um solche Fehler sofort zu fangen
2. **Claude-Provider auf Host-Seite untersuchen** — 1056+ Fehler deuten auf kaputte CLI/Konfiguration
3. **Timeout-Rate senken** — 38% aller Tasks, 94% davon Zero-Step (Planner verbraucht gesamtes Budget)
4. **Pending-Approval Tasks (007, 008) bearbeiten** — Pipeline ist jetzt frei, diese sollten in der nächsten Iteration approved werden
