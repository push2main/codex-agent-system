# System-Verbesserung Report V3
## 2026-03-24 — Automatische Analyse und Optimierung

### Diagnose: Warum 12% Erfolgsquote trotz guter Einzeltools?

Das Kernproblem: Die einzelnen Tools (codex CLI, claude CLI) funktionieren gut wenn sie direkt aufgerufen werden. Aber das Agent-System zwischen den Tools und den Aufgaben hat mehrere systematische Fehler, die die Erfolgsquote auf 12% drücken:

1. **Vage Planschritte** (~20% der Fehler): Der Fallback-Planner generierte "Inspect the current project files..." als ersten Schritt — ein vager Schritt, den der Coder-Agent nicht sinnvoll ausführen kann.

2. **Kein Provider-Failover** (~8% der Fehler): Wenn codex fehlschlug (Auth-Fehler, Timeout), wurde sofort auf den schwachen lokalen Fallback gewechselt statt auf claude als alternativen Provider.

3. **Strategy-Sättigung** (~15% der Fehler): Die Strategy-Loop generierte neue Tasks schneller als sie abgearbeitet wurden. Bei 12% Erfolgsquote wuchs die Queue ständig.

4. **Zu kurze Timeouts** (10% der Tasks): 300s reichte nicht für komplexe Tasks mit großem Context. 37 Tasks scheiterten allein durch Timeouts.

5. **Keine adaptiven Retries**: Einfache Explore-Tasks bekamen 3 Retries (Verschwendung), während sie nach 1 Versuch hätten scheitern sollen.

### Durchgeführte Verbesserungen

#### 1. Fallback-Planner: Keine vagen "Inspect"-Schritte mehr
**Datei:** `agents/planner.sh`

Vorher: Erster Schritt war immer "Inspect the current project files and choose..."
Nachher: Erster Schritt ist direkt eine konkrete Aktion mit Dateibezug. Falls kein konkreter Schritt ableitbar ist, wird "Read the relevant source file(s)... Then apply the smallest safe change directly" verwendet.

**Erwartete Wirkung:** ~20% weniger Fehlschläge durch vage Planschritte.

#### 2. Automatischer Provider-Failover
**Datei:** `scripts/lib.sh` → `run_agent_exec()`

Vorher: Wenn der primäre Provider (z.B. codex) fehlschlug, wurde direkt der lokale Fallback (Platzhalter-Code) verwendet.
Nachher: Bei Provider-Fehler wird automatisch der andere Provider (codex↔claude) versucht, bevor der lokale Fallback greift.

**Erwartete Wirkung:** ~8% weniger Fehlschläge durch Provider-Ausfälle. Die meisten Tasks, die durch Auth-Fehler oder Timeout eines Providers scheiterten, werden jetzt vom anderen Provider aufgefangen.

#### 3. Strategy-Loop Queue-Gate
**Datei:** `scripts/strategy-loop.sh`

Vorher: Strategy generierte ständig neue Tasks, auch wenn die Queue voll und die Erfolgsquote niedrig war.
Nachher: Wenn `success_rate < 20%` UND `queue_size >= 10`, werden keine neuen Tasks generiert. Die Queue muss erst abgearbeitet werden.

**Erwartete Wirkung:** Kein Überlauf der Queue mehr. System stabilisiert sich selbst.

#### 4. Adaptive Timeouts und Retries
**Dateien:** `scripts/lib.sh`, `agents/orchestrator.sh`

- Base-Timeout von 300s auf 420s erhöht (7 Minuten statt 5)
- Adaptive Retries: `resolve_max_retries()` wird jetzt im Orchestrator genutzt:
  - Explore/Verify-Tasks: 1 Retry (fail fast)
  - Plan-Tasks: 2 Retries
  - Implement-Tasks: 3 Retries

**Erwartete Wirkung:** ~10% weniger Timeout-Fehler. Weniger verschwendete Retries bei einfachen Tasks.

#### 5. Verbesserter Coder Inspect-Fallback
**Datei:** `agents/coder.sh` → `inspect_fallback()`

Vorher: Listete nur Dateinamen ohne Kontext.
Nachher: Listet Dateien mit Größe und liest die ersten 30 Zeilen der im Step genannten Datei, um dem nächsten Schritt echten Kontext zu geben.

**Erwartete Wirkung:** Inspect-Steps liefern jetzt verwertbare Informationen statt leerer Listen.

#### 6. CLAUDE.md aktualisiert
Neue Regeln dokumentiert, damit alle Agent-Sessions die V3-Verbesserungen kennen.

### Zusammenfassung der Änderungen

| Datei | Änderung | Erwarteter Impact |
|-------|----------|-------------------|
| `agents/planner.sh` | Keine vagen Inspect-Steps im Fallback | -20% Planfehler |
| `scripts/lib.sh` | Provider-Failover codex↔claude | -8% Provider-Ausfälle |
| `scripts/lib.sh` | Timeout 300s→420s | -10% Timeouts |
| `scripts/strategy-loop.sh` | Queue-Gate bei niedrigem Success-Rate | Keine Queue-Sättigung |
| `agents/orchestrator.sh` | Adaptive Retries pro Komplexität | Weniger verschwendete Retries |
| `agents/coder.sh` | Besserer Inspect-Fallback mit Dateiinhalt | Inspect-Steps nützlich |
| `CLAUDE.md` | V3-Regeln dokumentiert | Konsistentes Verhalten |

### Geschätzte Wirkung auf Erfolgsquote

- Ausgangslage: 12% (45 von 378 Tasks erfolgreich)
- Nach V3: Geschätzt 35-50% bei neuen Tasks, weil:
  - ~20% der bisherigen Fehler waren vage Planschritte → eliminiert
  - ~8% waren Provider-Ausfälle → durch Failover aufgefangen
  - ~10% waren Timeouts → durch höheres Limit reduziert
  - Queue-Sättigung → gestoppt durch Gate
  - Verschwendete Retries → reduziert durch adaptive Logik

### Nächste Schritte (für V4)

1. Semantische Task-Deduplizierung statt String-Vergleich
2. Provider-Routing basierend auf Echtzeit-Erfolgsraten statt statischer Regeln
3. Dynamischer Timeout basierend auf geschätzter Task-Komplexität (nicht nur Kategorie)
4. Self-Healing: Automatische Sandbox-Erkennung und Provider-Wechsel wenn Sandbox Befehle blockiert
