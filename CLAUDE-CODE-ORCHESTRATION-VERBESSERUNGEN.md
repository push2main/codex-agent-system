# Verbesserungen aus Claude Code Orchestrierung

**Datum:** 2026-03-24  
**Analyse:** Claude Code Orchestrierungspatterns → Codex Agent System  

---

## 1. Hierarchische Subagent-Delegation (statt flacher Pipeline)

**Aktuell:** Dein System hat eine feste, sequenzielle Pipeline: Planner → Coder → Reviewer → Evaluator. Jeder Agent kennt nur seinen nächsten Schritt.

**Claude Code Pattern:** Hierarchische Delegation mit spezialisierten Subagenten. Der Orchestrator entscheidet dynamisch, welchen Agenten er braucht, und kann Subagenten parallel starten. Subagenten haben eingeschränkte Tool-Sets (z.B. "Explore" darf nur lesen, nicht schreiben).

**Konkrete Verbesserung für dein System:**

Führe ein `agent_capabilities`-System in `agents/orchestrator.sh` ein:

```bash
# Neues Konzept: Agent-Rollen mit Tool-Einschränkungen
# In orchestrator.sh, statt immer die volle Pipeline zu durchlaufen:

AGENT_CAPABILITIES_EXPLORE="read_file,grep,glob"        # Nur lesen
AGENT_CAPABILITIES_IMPLEMENT="read_file,write_file,bash" # Lesen + Schreiben
AGENT_CAPABILITIES_VERIFY="read_file,bash"               # Lesen + Testen

# Orchestrator entscheidet dynamisch:
# - Einfache Inspection-Tasks → nur Explore-Agent
# - Code-Änderungen → Planner + Coder + Reviewer
# - Reine Verifikation → nur Verify-Agent
```

**Datei:** `agents/orchestrator.sh` — Neue Funktion `resolve_execution_path()` hinzufügen, die basierend auf dem Task-Typ die Pipeline-Stufen dynamisch wählt statt immer alle 4 Stufen zu durchlaufen.

---

## 2. Parallele Task-Execution mit Worktree-Isolation

**Aktuell:** Dein `multi-queue.sh` hat bis zu 4 Worker, aber alle arbeiten auf demselben Dateisystem. Wenn zwei Tasks dieselbe Datei ändern, gibt es Konflikte.

**Claude Code Pattern:** Git-Worktrees für Isolation. Jeder parallele Subagent bekommt eine eigene Kopie des Repos auf einem eigenen Branch. Nach Abschluss wird gemergt.

**Konkrete Verbesserung:**

```bash
# In scripts/queue-worker.sh, vor orchestrator.sh-Aufruf:
execute_task_isolated() {
  local project_dir="$1" task="$2" task_id="$3"
  local worktree_dir branch_name
  
  branch_name="worktree-${task_id}"
  worktree_dir="/tmp/codex-worktrees/$task_id"
  
  git -C "$project_dir" worktree add "$worktree_dir" -b "$branch_name" 2>/dev/null
  
  # Task in isoliertem Worktree ausführen
  bash agents/orchestrator.sh "$worktree_dir" "$task" "$task_id"
  
  # Bei Erfolg: Branch mergen und Worktree aufräumen
  if [ $? -eq 0 ]; then
    git -C "$project_dir" merge "$branch_name" --no-edit
  fi
  git -C "$project_dir" worktree remove "$worktree_dir" 2>/dev/null || true
}
```

**Dateien:** `scripts/queue-worker.sh`, `scripts/multi-queue.sh`

---

## 3. Mehrstufiges Memory-System (statt flacher Dateien)

**Aktuell:** Dein Memory besteht aus `decisions.md` (flat append-only), `context.md`, `knowledge.json` und `tasks.json`. Die `read_memory_context()`-Funktion liest die letzten 10 Einträge aus decisions.md plus 40 Zeilen Project-Memory — immer gleich viel, egal welcher Task.

**Claude Code Pattern:** Dreistufiges Memory:

1. **CLAUDE.md** (immer geladen, ~200 Zeilen max) — Kernregeln und Architektur
2. **Auto-Memory** (Index + Topic-Files, on-demand) — Gelernte Erkenntnisse, nach Thema sortiert
3. **Rules mit Path-Scoping** — Regeln die nur für bestimmte Dateien/Pfade gelten

**Konkrete Verbesserung:**

### a) Themenbasiertes Memory statt chronologisches

```
codex-memory/
├── index.md                    # Max 200 Zeilen, immer geladen
├── topics/
│   ├── stability.md            # Erkenntnisse zu Stabilität
│   ├── queue-handling.md       # Erkenntnisse zu Queue
│   ├── dashboard-ui.md         # Erkenntnisse zu UI
│   └── timeout-patterns.md     # Erkenntnisse zu Timeouts
└── decisions.md                # Bleibt als Audit-Log
```

### b) Path-Scoped Rules

```json
// codex-memory/scoped-rules.json
[
  {
    "paths": ["agents/*.sh"],
    "rules": ["Jeder Agent muss JSON zurückgeben", "Max 6 Schritte pro Plan"]
  },
  {
    "paths": ["codex-dashboard/**"],
    "rules": ["Mobile-first", "Keine Breaking API Changes"]
  },
  {
    "paths": ["scripts/lib.sh"],
    "rules": ["Keine neuen globalen Variablen", "Jede neue Funktion braucht Error-Handling"]
  }
]
```

### c) Angepasste `read_memory_context()`

```bash
read_memory_context() {
  local project_name="${1:-}"
  local task_text="${2:-}"
  
  # Immer: Index laden (max 200 Zeilen)
  safe_read_file "$MEMORY_DIR/index.md"
  
  # Dynamisch: Relevante Topics basierend auf Task-Keywords laden
  local topics
  topics="$(resolve_relevant_topics "$task_text")"
  for topic_file in $topics; do
    if [ -f "$MEMORY_DIR/topics/$topic_file" ]; then
      printf '\n## Memory: %s\n' "$topic_file"
      head -n 30 "$MEMORY_DIR/topics/$topic_file"
    fi
  done
  
  # Path-Scoped Rules für betroffene Dateien
  load_scoped_rules_for_task "$task_text" "$project_name"
}
```

**Dateien:** `scripts/lib.sh` (Funktion `read_memory_context`), neue Dateistruktur in `codex-memory/topics/`

---

## 4. Hooks-System (Lifecycle-Events)

**Aktuell:** Dein System hat keinen Mechanismus für Lifecycle-Events. Jede Erweiterung erfordert direkte Änderungen an den Agent-Scripts.

**Claude Code Pattern:** Ein Hook-System mit definierten Events:
- `PreToolUse` — Vor jeder Tool-Nutzung (Validierung)
- `PostToolUse` — Nach jeder Tool-Nutzung (Logging, Formatting)
- `SessionStart` — Beim Start (Context-Injection)
- `Stop` — Beim Ende (Verifikation)

**Konkrete Verbesserung:**

```bash
# Neue Datei: scripts/hooks.sh

HOOKS_DIR="$ROOT_DIR/.codex/hooks"

fire_hook() {
  local event_name="$1"
  shift
  local hook_dir="$HOOKS_DIR/$event_name"
  
  [ -d "$hook_dir" ] || return 0
  
  local hook_input
  hook_input="$(jq -cn \
    --arg event "$event_name" \
    --arg timestamp "$(now_utc)" \
    --argjson data "${1:-'{}'}" \
    '{event:$event, timestamp:$timestamp, data:$data}')"
  
  for hook_script in "$hook_dir"/*.sh; do
    [ -f "$hook_script" ] || continue
    local result
    result="$(printf '%s' "$hook_input" | bash "$hook_script" 2>&1)" || {
      log_msg WARN hooks "Hook $hook_script failed for $event_name"
      continue
    }
    # Exit code 2 = Block die Aktion
    [ $? -eq 2 ] && return 2
  done
  return 0
}

# Verwendung in orchestrator.sh:
fire_hook "pre_task_execute" "$(jq -cn --arg task "$TASK" '{task:$task}')"
# ... Task ausführen ...
fire_hook "post_task_execute" "$(jq -cn --arg task "$TASK" --arg result "$RESULT" '{task:$task,result:$result}')"
```

**Hook-Events für dein System:**

| Event | Wann | Nutzen |
|-------|------|--------|
| `pre_task_execute` | Vor Orchestrator-Start | Validierung, Duplikat-Check |
| `post_task_execute` | Nach Orchestrator-Ende | Metriken, Notifications |
| `pre_coder_step` | Vor jedem Coder-Step | Sicherheitschecks |
| `post_coder_step` | Nach jedem Coder-Step | Auto-Format, Lint |
| `on_task_approval` | Bei manueller Freigabe | Audit-Trail |
| `on_strategy_run` | Bei Strategy-Durchlauf | Rate-Limiting |

**Dateien:** Neue Datei `scripts/hooks.sh`, Integration in `agents/orchestrator.sh` und `agents/coder.sh`

---

## 5. Context-Window-Management & Auto-Compaction

**Aktuell:** Deine `read_memory_context()` hat feste Grenzen (10 Zeilen Decisions, 40 Zeilen Memory), aber es gibt kein dynamisches Budget. Die `tasks.json` ist bereits 1.6MB und verursacht Registry-Pressure.

**Claude Code Pattern:** 
- Context-Budget wird dynamisch berechnet
- Auto-Compaction bei ~95% Auslastung
- Ältere Outputs werden zuerst komprimiert
- Kern-Instructions werden nach Compaction frisch injiziert

**Konkrete Verbesserung:**

### a) Dynamisches Context-Budget für Prompts

```bash
# In scripts/lib.sh
MAX_PROMPT_CONTEXT_CHARS=15000  # ~4000 Tokens

build_dynamic_context() {
  local task="$1" project="$2"
  local budget=$MAX_PROMPT_CONTEXT_CHARS
  local context=""
  
  # Priorität 1: Kern-Rules (immer, ~500 chars)
  local rules
  rules="$(safe_tail 20 "$RULES_FILE")"
  context+="$rules"
  budget=$((budget - ${#rules}))
  
  # Priorität 2: Project Memory Index (~1000 chars)
  local memory
  memory="$(head -n 50 "$(project_memory_file "$project")" 2>/dev/null || true)"
  if [ ${#memory} -le $budget ]; then
    context+="$memory"
    budget=$((budget - ${#memory}))
  fi
  
  # Priorität 3: Similar Tasks (nur wenn Budget übrig)
  if [ $budget -gt 2000 ]; then
    local similar
    similar="$(build_similar_task_context "$task" "$project" "" | head -c $budget)"
    context+="$similar"
    budget=$((budget - ${#similar}))
  fi
  
  # Priorität 4: Source Context (Rest-Budget)
  if [ $budget -gt 1000 ]; then
    local sources
    sources="$(build_prompt_source_context "$task" "" "$project" | head -c $budget)"
    context+="$sources"
  fi
  
  printf '%s' "$context"
}
```

### b) Task-Registry Compaction

```bash
# Neues Script: scripts/compact-registry.sh
compact_task_registry() {
  local registry="$TASK_REGISTRY_FILE"
  local max_bytes=512000
  local current_bytes
  current_bytes="$(wc -c < "$registry")"
  
  if [ "$current_bytes" -gt "$max_bytes" ]; then
    log_msg INFO compact "Registry pressure: ${current_bytes}B > ${max_bytes}B, compacting..."
    
    python3 - "$registry" <<'PY'
import json, sys
from pathlib import Path

registry = json.loads(Path(sys.argv[1]).read_text())
tasks = registry.get("tasks", [])

# Behalte: laufende, approved, letzte 50 abgeschlossene
active = [t for t in tasks if t.get("status") in ("running", "approved", "pending_approval")]
completed = sorted(
    [t for t in tasks if t.get("status") in ("success", "failed")],
    key=lambda t: t.get("updated_at", ""),
    reverse=True
)[:50]

# Archiviere den Rest in separate Datei
archived = [t for t in tasks if t not in active and t not in completed]
if archived:
    archive_path = Path(sys.argv[1]).parent / "tasks-archive.json"
    existing = json.loads(archive_path.read_text()) if archive_path.exists() else []
    existing.extend(archived)
    archive_path.write_text(json.dumps(existing, indent=2))

registry["tasks"] = active + completed
Path(sys.argv[1]).write_text(json.dumps(registry, indent=2))
print(f"Compacted: {len(tasks)} → {len(active) + len(completed)} tasks, archived {len(archived)}")
PY
  fi
}
```

**Dateien:** `scripts/lib.sh`, neues `scripts/compact-registry.sh`

---

## 6. Dynamische Provider-Routing (statt statischem Provider)

**Aktuell:** Dein System hat `provider-routing.json` und `provider-stats.json`, aber der Routing scheint statisch zu sein.

**Claude Code Pattern:** Claude Code wählt dynamisch das Model basierend auf Task-Komplexität:
- Einfache Suche → Haiku (schnell, günstig)
- Planung/Architektur → Opus (gründlich)
- Standard-Coding → Sonnet (Balance)

**Konkrete Verbesserung:**

```bash
# In scripts/lib.sh
resolve_task_provider_dynamic() {
  local task="$1" project="$2"
  
  # Task-Klassifizierung
  local complexity
  complexity="$(classify_task_complexity "$task")"
  
  case "$complexity" in
    "explore")
      # Reine Inspection, Grep, Read → günstigstes Model
      printf 'haiku'
      ;;
    "plan")
      # Architektur-Entscheidungen, Multi-Step → bestes Model
      printf 'opus'
      ;;
    "implement")
      # Standard Coding → ausgewogenes Model
      printf 'sonnet'
      ;;
    "verify")
      # Tests ausführen, Validierung → schnelles Model
      printf 'haiku'
      ;;
    *)
      printf 'sonnet'
      ;;
  esac
}

classify_task_complexity() {
  local task="$1"
  local task_lower
  task_lower="$(printf '%s' "$task" | tr '[:upper:]' '[:lower:]')"
  
  # Keyword-basierte Klassifizierung
  if printf '%s' "$task_lower" | grep -qE '(inspect|check|verify|test|validate|list|count)'; then
    printf 'verify'
  elif printf '%s' "$task_lower" | grep -qE '(architecture|redesign|refactor major|strategy|plan)'; then
    printf 'plan'
  elif printf '%s' "$task_lower" | grep -qE '(search|find|grep|explore|read|analyze)'; then
    printf 'explore'
  else
    printf 'implement'
  fi
}
```

**Wichtig:** Auch pro Step innerhalb eines Tasks verschiedene Provider nutzen — der Planner-Step braucht ein anderes Model als der Verify-Step.

**Dateien:** `scripts/lib.sh`, `agents/orchestrator.sh`

---

## 7. PostCompact-Hook für Context-Recovery

**Aktuell:** Wenn dein System den Context verliert (z.B. weil die Prompt-Größe das Limit überschreitet), gibt es keinen Recovery-Mechanismus.

**Claude Code Pattern:** `PostCompact`-Hook injiziert nach Compaction die kritischsten Informationen neu in den Context.

**Konkrete Verbesserung:**

```bash
# In orchestrator.sh: Nach jedem Step den "Kern-Context" refreshen
refresh_core_context_if_needed() {
  local step_index="$1"
  local total_steps="$2"
  
  # Nach der Hälfte der Steps: Context refreshen
  if [ "$step_index" -ge $((total_steps / 2)) ]; then
    # Kern-Rules und aktuelle Task-Info neu einlesen
    MEMORY_CONTEXT="$(read_memory_context "$PROJECT_NAME" "$TASK")"
    log_msg DEBUG orchestrator "Context refreshed at step $step_index/$total_steps"
  fi
}
```

**Datei:** `agents/orchestrator.sh`

---

## 8. Stop-Verifikation (Post-Execution Guard) — nur Flagging, kein Auto-Revert

**Aktuell:** Dein Evaluator gibt einen Score (0-10), aber niedrige Scores haben keine Konsequenzen.

**Claude Code Pattern:** `Stop`-Hook verifiziert nach Abschluss, ob die Arbeit wirklich fertig ist.

**Konkrete Verbesserung:** KEIN automatisches Branch-Delete (das verstößt gegen AGENTS.md "NEVER break the system"). Stattdessen Flagging für manuelle Review:

```bash
# In orchestrator.sh, nach dem Evaluator:
post_execution_guard() {
  local score="$1" result="$2" task_id="$3"

  # Score unter 4: Task als "needs_review" markieren
  if [ "$score" -lt 4 ] && [ "$result" = "SUCCESS" ]; then
    log_msg WARN orchestrator "Low score ($score) despite SUCCESS — flagging $task_id for review"
    update_task_registry_field "$task_id" "needs_manual_review" "true"
    update_task_registry_field "$task_id" "review_reason" "Low evaluator score: $score"
  fi

  # Score 4-6: Warnung im Decision-Log
  if [ "$score" -ge 4 ] && [ "$score" -lt 7 ]; then
    log_msg WARN orchestrator "Marginal score ($score) — adding review note"
  fi
}
```

**Datei:** `agents/orchestrator.sh`

---

## 9. Verbessertes Learner-System (Auto-Memory)

**Aktuell:** Dein Learner (`agents/learner.sh`) erzeugt Regeln basierend auf den letzten Tasks. Die Safety (`agents/safety.sh`) validiert sie. Aber die Regeln landen als flaches Markdown und werden nie thematisch sortiert.

**Claude Code Pattern:** Auto-Memory speichert Erkenntnisse in thematischen Topic-Files. Nur ein 200-Zeilen-Index wird immer geladen — Details on-demand.

**Konkrete Verbesserung:**

```bash
# Erweiterter Learner: Speichert in thematische Topic-Files
# agents/learner.sh — Ergänzung:

categorize_and_store_learning() {
  local learning_text="$1"
  local category="$2"  # stability, ui, performance, code_quality
  
  local topic_file="$MEMORY_DIR/topics/${category}.md"
  local index_file="$MEMORY_DIR/index.md"
  
  # Topic-File aktualisieren
  mkdir -p "$MEMORY_DIR/topics"
  printf '- %s: %s\n' "$(now_utc)" "$learning_text" >> "$topic_file"
  
  # Index-File: Nur Zusammenfassung, max 200 Zeilen
  local index_lines
  index_lines="$(wc -l < "$index_file" 2>/dev/null || printf '0')"
  if [ "$index_lines" -lt 200 ]; then
    printf '- [%s] %s\n' "$category" "$learning_text" >> "$index_file"
  else
    # Älteste Zeile entfernen, neue hinzufügen (Rolling Window)
    tail -n 199 "$index_file" > "${index_file}.tmp"
    printf '- [%s] %s\n' "$category" "$learning_text" >> "${index_file}.tmp"
    mv "${index_file}.tmp" "$index_file"
  fi
}
```

**Dateien:** `agents/learner.sh`, neue Struktur `codex-memory/topics/`

---

## 10. Settings-Hierarchie (statt einzelner Config-Datei)

**Aktuell:** Settings liegen verstreut in `dashboard-settings.json`, `priority.json`, `agentctl-runtime.env` und Umgebungsvariablen.

**Claude Code Pattern:** Klare Hierarchie mit Precedence:
1. Managed (System-Level, nicht überschreibbar)
2. Session/CLI-Flags
3. Project-Local (gitignored)
4. Project-Shared (committed)
5. User-Global

**Konkrete Verbesserung:**

```bash
# Neue Funktion in scripts/lib.sh:
resolve_setting() {
  local key="$1"
  local default_value="${2:-}"
  
  # Precedence: CLI > Project-Local > Project > Global > Default
  
  # 1. CLI/Environment
  local env_key
  env_key="CODEX_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  [ -n "${!env_key:-}" ] && { printf '%s' "${!env_key}"; return 0; }
  
  # 2. Project-Local (nicht committed)
  local local_val
  local_val="$(jq -r --arg k "$key" '.[$k] // empty' "$ROOT_DIR/projects/$PROJECT_NAME/settings.local.json" 2>/dev/null || true)"
  [ -n "$local_val" ] && { printf '%s' "$local_val"; return 0; }
  
  # 3. Project-Shared
  local project_val
  project_val="$(jq -r --arg k "$key" '.[$k] // empty' "$ROOT_DIR/projects/$PROJECT_NAME/project.json" 2>/dev/null || true)"
  [ -n "$project_val" ] && { printf '%s' "$project_val"; return 0; }
  
  # 4. Global
  local global_val
  global_val="$(jq -r --arg k "$key" '.[$k] // empty' "$ROOT_DIR/codex-memory/dashboard-settings.json" 2>/dev/null || true)"
  [ -n "$global_val" ] && { printf '%s' "$global_val"; return 0; }
  
  # 5. Default
  printf '%s' "$default_value"
}
```

**Dateien:** `scripts/lib.sh`, pro Projekt neue `settings.local.json`

---

## 11. Retry-Failure-Chain durchbrechen (KRITISCH — Root Cause)

**Aktuell:** Deine Metriken zeigen 60% First-Pass-Success, aber nur 12% Gesamterfolgsrate. Das bedeutet: 80% der Retry-Versuche scheitern. 49 Tasks haben Loop-Effort mit 80 Extra-Step-Attempts. Das System verbrennt Kapazität in Retry-Schleifen.

**Claude Code Pattern:** Claude Code vermeidet Retry-Loops durch:
- Fehler-Analyse VOR dem Retry (nicht blind nochmal versuchen)
- Subagent-Delegation mit anderem Ansatz beim Retry
- Context-Enrichment: Beim Retry wird die Fehlermeldung explizit in den neuen Prompt eingebaut

**Konkrete Verbesserung:**

```bash
# In agents/orchestrator.sh: Retry mit Fehler-Kontext statt blind
retry_with_failure_context() {
  local step_index="$1"
  local step_text="$2"
  local previous_error="$3"
  local attempt="$4"

  # Failure-Analyse: Was genau ist schiefgelaufen?
  local failure_analysis
  failure_analysis="$(analyze_step_failure "$previous_error")"

  # Enriched Prompt für den Retry
  local enriched_step
  enriched_step="$(cat <<RETRY_EOF
RETRY ATTEMPT $attempt for step $step_index.

ORIGINAL STEP: $step_text

PREVIOUS FAILURE: $previous_error

FAILURE ANALYSIS: $failure_analysis

CRITICAL: Du musst einen ANDEREN Ansatz wählen als beim letzten Versuch.
Wenn der letzte Versuch an einer fehlenden Dependency scheiterte, installiere sie zuerst.
Wenn der letzte Versuch an einem Syntax-Fehler scheiterte, prüfe die Datei vor der Änderung.
Wenn der letzte Versuch an einem Test scheiterte, lies zuerst den Test um das erwartete Verhalten zu verstehen.
RETRY_EOF
)"

  printf '%s' "$enriched_step"
}

# Zusätzlich: Retry-Budget pro Task-Kategorie
# Tasks die 2x mit gleichem Fehler scheitern → Strategy-Saturation markieren
detect_retry_loop() {
  local task_id="$1" current_error="$2"
  local previous_errors
  previous_errors="$(get_task_error_history "$task_id")"

  if printf '%s' "$previous_errors" | grep -qF "$current_error"; then
    log_msg WARN orchestrator "Retry loop detected for $task_id — same error repeating"
    update_task_registry_field "$task_id" "retry_loop_detected" "true"
    return 1  # Signal: Nicht nochmal versuchen
  fi
  return 0
}
```

**Dateien:** `agents/orchestrator.sh`, `agents/coder.sh`

---

## Zusammenfassung: Prioritäts-Ranking

| # | Verbesserung | Impact | Aufwand | Priorität |
|---|-------------|--------|---------|-----------|
| 11 | Retry-Failure-Chain durchbrechen | **Sehr Hoch** | Mittel | **P0** |
| 1 | Themenbasiertes Memory (Topic-Files) | Hoch | Mittel | **P0** |
| 2 | Task-Registry Compaction | Hoch | Niedrig | **P0** |
| 3 | Dynamisches Context-Budget | Hoch | Mittel | **P1** |
| 6 | Dynamische Pipeline (nicht immer 4 Stufen) | Mittel | Niedrig | **P1** |
| 7 | Provider-Routing pro Step | Mittel | Niedrig | **P1** |
| 5 | Worktree-Isolation für Worker | Mittel | Mittel | **P2** |
| 8 | Post-Execution Guard (nur Flagging) | Mittel | Niedrig | **P2** |
| 4 | Hooks-System | Niedrig | Mittel | **P3** |
| 9 | Settings-Hierarchie | Niedrig | Mittel | **P3** |
| 10 | Context-Recovery nach Compaction | Niedrig | Niedrig | **P3** |

**Begründung P0:**
- **#11 Retry-Chain** ist der Root Cause für die 12% Gesamterfolgsrate. 60% First-Pass-Success aber 80% Retry-Failure bedeutet: Das System kann Tasks lösen, verbrennt aber Kapazität in blinden Retries. Fehler-Kontext beim Retry und Loop-Detection adressieren das direkt.
- **#1 Topic-Memory** verbessert die Prompt-Qualität für alle Agents und kann die First-Pass-Rate von 60% weiter steigern.
- **#2 Registry Compaction** löst den akuten Registry-Pressure (1.6MB > 512KB Threshold) und damit verbundene Performance-Probleme.

**Hinweis zu Determinismus:** Vorschläge 4, 5 und 10 müssen sorgfältig implementiert werden um die AGENTS.md-Regel "be deterministic" einzuhalten. Hooks brauchen eine definierte Ausführungsreihenfolge, Worktrees einen sauberen Cleanup, und Settings eine deterministische Auflösungsreihenfolge.
