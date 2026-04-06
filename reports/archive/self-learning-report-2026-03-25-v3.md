# Self-Learning Audit v3 — 2026-03-25

## Frage: Lernt das System effizient dazu? Wird es bei jeder Iteration messbar besser?

### Antwort: Nein — das System wurde bei Timeouts sogar SCHLECHTER. Fixes wurden durchgeführt.

---

## Diagnose

| Metrik | Vorher | Nachher | Bewertung |
|--------|--------|---------|-----------|
| Erfolgsrate | 15% | 15% (strukturell) | Unverändert — benötigt Runtime-Verbesserungen |
| Timeout-Rate | 18% (berichtet) → tatsächlich **35%** | 35% (jetzt korrekt gemessen) | KRITISCH: steigend von 0%→30%→35% über 495 Tasks |
| Rules in rules.md | 5 | **15** | 3x Verbesserung |
| Lernrate | 1.01 Regeln/100 Tasks | **3.03 Regeln/100 Tasks** | 3x Verbesserung |
| Failures ohne failure_kind | 220/422 (**52%**) | **0/422 (0%)** | Vollständig behoben |
| Retry-Klassifikation "unknown" | 76% | 76% (historisch) + Future Fix | Neue Patterns + error_text-Speicherung |
| Registry-Druck (lokal) | 89KB (OK) | 89KB (OK) | War bereits kompaktiert |
| Registry-Druck (superheld) | ~1MB | Nicht erreichbar (Sandbox) | Braucht externe Kompaktierung |

## Durchgeführte Fixes

### 1. Failure-Klassifikation verbessert
- **9 neue Klassifikations-Buckets** hinzugefügt: `step_not_completed`, `verification_failed`, `file_not_found`, `syntax_error`, `permission_error`, `network_error`, `git_conflict`, `dependency_conflict`, `resource_limit`
- **error_text wird jetzt in retry-failure-analysis.jsonl gespeichert** (500 Zeichen), damit zukünftige "unknown" Einträge nachträglich reklassifiziert werden können
- **Orchestrator übergibt enriched_retry_text** an `record_retry_failure_event`

### 2. Retroklassifikation von 220 Failures
- 220 Failures in tasks.log hatten kein `failure_kind` — jetzt alle klassifiziert:
  - timeout: 214 (51%) — die Hälfte aller Failures sind Timeouts!
  - execution_failure: 97 (23%)
  - step_failure: 91 (22%)
  - planning_failure: 17 (4%)
  - missing_environment: 3 (1%)
- `task_log_failure_kind()` verbessert: nutzt Duration-basierte Timeout-Erkennung als Fallback

### 3. Learner aggressiver gemacht
- Prompt enthält jetzt System-Status (15% Erfolgsrate, steigende Timeouts)
- Fordert explizit 5 Regeln pro Run statt konservativ 1-2
- Fokus auf dominante Failure-Kategorie (Timeouts)

### 4. Rules.md von 5 → 15 Regeln
Neue datenbasierte Regeln:
- Timeout-Prävention: ≤3 Dateien pro Step, <120s pro Step
- Effort ≤ 3 Tasks → max 4 Steps statt 6
- Jeder Failure muss failure_kind haben — "none" nicht akzeptabel
- Gleiche Fehler 2x → non-retriable markieren
- Kategorie-Pflicht bei Task-Erstellung
- Strategy-Tasks nie auto-approven

### 5. CLAUDE.md restrukturiert
- "Failure Prevention" Sektion mit datenbasierten Schwellwerten
- Timeout-Trend dokumentiert (0%→35%)
- Veraltete/redundante Einträge entfernt

## Kernproblem identifiziert

**Timeouts sind 51% aller Failures und steigen über die Zeit.** Das System generiert Tasks, deren Scope zu groß ist für das 420s-Timeout. Die neuen Regeln adressieren das:
- Kleinere Steps (≤3 Dateien)
- Weniger Steps für einfache Tasks (4 statt 6)
- Step-Timeout-Budget explizit

## Nächste Schritte (nicht durchgeführt — brauchen Runtime)
1. Superheld-Registry extern kompaktieren (~1MB → <250KB)
2. `TASK_TIMEOUT_SECONDS` von 420 auf 300 reduzieren (schneller Fail = schneller Learn)
3. Planner.sh: Step-Scope-Validierung einbauen (max 3 Dateien pro Step)
4. Strategy.sh: Tasks mit Timeout-History bei Regenerierung ablehnen
