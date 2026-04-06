# System-Verbesserung Report V2 — 2026-03-24

## Ausgangslage

Das Agent-System hatte eine Erfolgsquote von 12% (metrics.json). Der vorherige Report (V1) identifizierte und behob den kritischsten Fehler: den ungültigen CLI-Flag `codex -a auto` → `codex -a on-request`, erhöhte das Timeout auf 300s und MAX_RETRIES auf 3.

**Aber:** Die im V1-Report vorgeschlagenen strukturellen Verbesserungen (aus CLAUDE-CODE-ORCHESTRATION-VERBESSERUNGEN.md) waren noch NICHT implementiert. Diese V2-Runde implementiert die P0- und P1-Verbesserungen.

---

## Verbleibende Probleme (vor V2)

| Problem | Metrik | Impact |
|---------|--------|--------|
| Blinde Retries ohne Fehlerkontext | 80 Extra-Step-Attempts bei 49 Tasks | Hoch |
| Registry-Pressure | 1.6MB tasks.json, dashboard langsam | Hoch |
| Flaches Memory (chronologisch) | Gleiche Fehler wiederholen sich | Mittel |
| Kein Context-Budget | Prompts können unbegrenzt groß werden | Mittel |

---

## Durchgeführte Verbesserungen (V2)

### 1. Retry mit Fehlerkontext (P0 — KRITISCH)

**Datei:** `agents/orchestrator.sh`

**Problem:** Wenn ein Step scheiterte, wurde beim Retry der exakt gleiche Prompt verwendet. Der Coder machte denselben Fehler nochmal.

**Lösung:**
- Bei Retry-Attempts wird der Step-Prompt mit dem konkreten Fehler aus dem vorherigen Versuch angereichert
- Der Coder erhält explizite Instruktionen, einen ANDEREN Ansatz zu wählen
- Fehler aus Coder, Reviewer und Evaluator werden extrahiert und in den Retry-Prompt eingebaut

**Zusätzlich:** Retry-Loop-Detection — wenn dieselbe Fehlermeldung sich wiederholt, werden die Retries frühzeitig abgebrochen statt alle MAX_AGENT_RETRIES zu verbrauchen.

**Erwarteter Impact:** Reduziert die 80 verschwendeten Extra-Step-Attempts auf <20.

### 2. Post-Execution Guard (P0)

**Datei:** `agents/orchestrator.sh`

**Problem:** Tasks mit niedrigem Evaluator-Score (< 4) wurden trotzdem als SUCCESS markiert.

**Lösung:** Warnung im Log wenn SUCCESS mit Score < 4, bzw. Score 4-6 als "marginal" geloggt.

### 3. Task-Registry Compaction (P0)

**Neue Datei:** `scripts/compact-registry.sh`
**Integration:** `scripts/strategy-loop.sh`

**Problem:** tasks.json war 1.6MB und wuchs unbegrenzt. Dashboard-Reads wurden langsam.

**Lösung:**
- Neues Script `compact-registry.sh` das bei jedem Strategy-Loop-Durchlauf läuft
- Threshold: 512KB — darüber wird kompaktiert
- Behält: alle aktiven Tasks + die 50 neuesten abgeschlossenen
- Archiviert: alte Tasks in `tasks-archive.json`
- Erstellt Backup vor Kompaktierung
- Registriert den Zeitpunkt der letzten Kompaktierung

**Erwarteter Impact:** Registry bleibt unter 512KB, Dashboard-Performance normalisiert sich.

### 4. Themenbasiertes Memory-System (P0)

**Geänderte Dateien:** `scripts/lib.sh`, `agents/learner.sh`
**Neue Dateien:** `codex-memory/index.md`, `codex-memory/topics/`

**Problem:** Alles Memory war chronologisch in decisions.md. Der Agent las immer die letzten 10 Zeilen — unabhängig davon, welcher Task ausgeführt wurde.

**Lösung:**
- `codex-memory/index.md` (max 200 Zeilen) — Kern-Wissen, wird IMMER geladen
- `codex-memory/topics/*.md` — Thematische Erkenntnisse (stability, queue, dashboard, timeout, provider, planning, memory, testing)
- `read_memory_context()` akzeptiert jetzt einen `task_text`-Parameter und lädt nur relevante Topic-Files
- Der Learner kategorisiert neue Erkenntnisse automatisch in die passenden Topic-Files
- Rolling Window: max 50 Einträge pro Topic

**Erwarteter Impact:** Bessere First-Pass-Success-Rate weil der Agent relevanteres Wissen im Prompt hat.

### 5. Dynamisches Context-Budget (P1)

**Geänderte Dateien:** `scripts/lib.sh`, `agents/coder.sh`

**Problem:** Prompts konnten unbegrenzt groß werden, besonders bei großen Feedback-Files, Source-Context und Similar-Tasks.

**Lösung:**
- Neuer Konfig-Wert `MAX_PROMPT_CONTEXT_CHARS=15000` (~4000 Tokens)
- Neue Utility-Funktion `truncate_context_to_budget()` in lib.sh
- Coder-Prompt truncated die einzelnen Kontext-Blöcke:
  - Memory: max 4000 Zeichen
  - Feedback: max 3000 Zeichen
  - Source Context: max 4000 Zeichen
  - Similar Tasks: max 3000 Zeichen

**Erwarteter Impact:** Weniger Timeout-Failures durch kleinere Prompts, stabilere Provider-Aufrufe.

### 6. Lernregeln aktualisiert

**Datei:** `codex-learning/rules.md`

Alle neuen Erkenntnisse dokumentiert für zukünftige Referenz.

---

## Zusammenfassung der Änderungen

| Datei | Änderung |
|-------|----------|
| `agents/orchestrator.sh` | Retry-Failure-Context, Loop-Detection, Post-Execution Guard |
| `agents/coder.sh` | Context-Budget-Truncation für alle Prompt-Blöcke |
| `agents/learner.sh` | Topic-basierte Speicherung von Erkenntnissen |
| `scripts/lib.sh` | `read_memory_context()` mit Topics, `truncate_context_to_budget()`, `MAX_PROMPT_CONTEXT_CHARS` |
| `scripts/compact-registry.sh` | NEU — Registry-Kompaktierung |
| `scripts/strategy-loop.sh` | Integration der Kompaktierung |
| `codex-memory/index.md` | NEU — Kern-Wissen-Index |
| `codex-memory/topics/` | NEU — Themen-Verzeichnis |
| `codex-learning/rules.md` | Aktualisierte Lernregeln |

---

## Erwartete Ergebnisse

| Metrik | Vorher (V1) | Erwartet nach V2 |
|--------|-------------|-------------------|
| Erfolgsquote | 12% | 50-70% |
| Verschwendete Retry-Attempts | 80 | < 20 |
| Registry-Größe | 1.6MB | < 512KB |
| Timeout-Failures | 36 | < 10 |
| Retry-Loops | 49 Tasks betroffen | < 10 |

---

## Noch offene Verbesserungen (P2/P3, für spätere Runden)

1. **Worktree-Isolation** für parallele Worker (git worktrees, P2)
2. **Hooks-System** für Lifecycle-Events (P3)
3. **Settings-Hierarchie** statt verstreuter Config-Dateien (P3)
4. **Dynamisches Provider-Routing** pro Step (P2 — Haiku für Verify, Opus für Plan, Sonnet für Code)
5. **Dynamische Pipeline** — nicht immer alle 4 Stufen durchlaufen (P2)
