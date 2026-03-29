# Self-Learning Diagnose & Fix — 2026-03-25

## Kernfrage: Lernt das System effizient dazu?

**Antwort: Nein.** Das System generiert Regeln, aber setzt sie nicht durch. Die Lernschleife ist ein offener Kreislauf — Erkenntnisse werden als Text gespeichert, aber nicht in Code umgesetzt.

## Diagnose: 5 kritische Probleme

### 1. Zombie Guard hat einen Shell-Bug (BEHOBEN)
Die `grep -c ... | grep -c ...` Pipeline in `queue-worker.sh` konnte nie funktionieren — nur der Python-Fallback lief. Wurde durch reinen Python-Call mit `sys.argv` ersetzt (sicher gegen Shell-Injection).

### 2. Timeout-Retries werden nicht verhindert (BEHOBEN)
Die Regel "Timeout ist non-retryable" stand nur als Text in `rules.md`. Ergebnis: **56 Tasks** haben 2+ mal getimt out, **119 Worker-Slots** verschwendet. Neuer "Non-Retryable Failure Guard" in `queue-worker.sh` blockiert Retries für `timeout`, `missing_environment`, `missing_platform`.

### 3. Zombie-Blocklist war nur ein Cooldown (BEHOBEN)
Die Title-Family-Cooldowns in `self-improve.sh` laufen nach 24h ab. Zombie-Tasks kamen zurück. Neue **permanente Blocklist** basierend auf `tasks.log` — Tasks mit 5+ Failures werden nie wieder generiert.

### 4. Planner hat kein Timeout (BEHOBEN)
94% aller Timeouts waren Zero-Step-Timeouts (Planner verbraucht gesamtes Budget). Neuer **90s Hard-Cap** für die Planning-Phase in `orchestrator.sh` — wenn der Planner nicht fertig wird, fail-fast statt gesamten Worker-Slot zu verschwenden.

### 5. Regeln sind nur beratend, nicht durchgesetzt (SYSTEMISCHES PROBLEM)
Die 15 gelernten Regeln existieren nur als Prompt-Text für den Planner. Sie haben **keinen messbaren Impact**: Timeouts stiegen in den letzten 100 Tasks um +26 trotz expliziter Anti-Timeout-Regeln. **Lösung:** Alle kritischen Regeln jetzt als Code-Guards implementiert.

## Geänderte Dateien

| Datei | Änderung |
|---|---|
| `scripts/queue-worker.sh` | Zombie-Guard Bug-Fix + Non-Retryable Failure Guard |
| `scripts/self-improve.sh` | Permanente Zombie-Blocklist + Non-Retryable Blocklist |
| `agents/orchestrator.sh` | 90s Planning-Phase Timeout |
| `codex-learning/rules.md` | 4 neue enforcement-fokussierte Regeln |
| `CLAUDE.md` | Aktualisierte Core Rules + System Health |

## Projizierter Impact

| Metrik | Vorher | Nachher (projiziert) |
|---|---|---|
| Verschwendete Slots | 186 (35.6%) | ~0 |
| Effektive Success Rate | 15.1% | 23.5% |
| Timeout-Retries | 119 | 0 |
| Zombie-Regenerierungen | 66 | 0 |

## Systemische Erkenntnis

Das Learning-System hat eine **Feedback-Gap**: Es lernt Regeln, aber die Regeln wirken nur als "Empfehlung" an den Planner-LLM. LLMs ignorieren solche Empfehlungen inkonsistent. **Effektives maschinelles Lernen in diesem System erfordert Code-Enforcement, nicht Prompt-Engineering.**
